#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "$0")" && pwd)
LINUX_ROOT="$PROJECT_ROOT/linux"
ENV_FILE="$PROJECT_ROOT/lab.env.file"
if [[ -f "$ENV_FILE" ]]; then
  # Shared non-secret lab settings.
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi
LINUX_ENV_FILE="$LINUX_ROOT/lab.env.file"
if [[ -f "$LINUX_ENV_FILE" ]]; then
  # Linux-specific non-secret lab settings.
  # shellcheck disable=SC1090
  source "$LINUX_ENV_FILE"
fi
AWS_PROFILE=${AWS_PROFILE:-default}
AWS_REGION=${AWS_REGION:-us-west-2}
AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-$AWS_REGION}
AWS_PAGER=""
STATE_FILE="$LINUX_ROOT/.ami-state.env"
ACTION=${1:-}
SKIP_OFFBOARD=${2:-}

export AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION AWS_PAGER

fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<EOF
Usage:
  $0 plan
  $0 apply
  $0 status
  $0 destroy [--skip-offboard]
EOF
  exit 1
}

[[ "$ACTION" =~ ^(plan|apply|status|destroy)$ ]] || usage
[[ -z "$SKIP_OFFBOARD" || "$SKIP_OFFBOARD" == "--skip-offboard" ]] || usage

command -v terraform >/dev/null 2>&1 || fail "Terraform is not installed"
command -v aws >/dev/null 2>&1 || fail "AWS CLI is not installed"

profile_aws() {
  env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
    aws --profile "$AWS_PROFILE" "$@"
}
ensure_aws_auth() {
  if ! profile_aws sts get-caller-identity --no-cli-pager >/dev/null 2>&1; then
    printf 'AWS session is unavailable; starting browser login for profile %s\n' "$AWS_PROFILE"
    aws login --profile "$AWS_PROFILE"
  fi
  profile_aws sts get-caller-identity --no-cli-pager >/dev/null 2>&1 || fail "AWS authentication failed"
  printf '\nAWS authentication:\n'
  profile_aws configure list --no-cli-pager
  profile_aws sts get-caller-identity --query '{Account:Account,Arn:Arn}' --output table --no-cli-pager
  if [[ -t 0 ]]; then
    read -r -p "Authentication verified. Press Enter to continue or Control-C to stop... "
  else
    printf 'Authentication verified. Non-interactive input detected; continuing in 3 seconds...\n'
    sleep 3
  fi
}

ensure_aws_auth

eval "$(aws configure export-credentials --profile "$AWS_PROFILE" --format env)"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

cd "$LINUX_ROOT"

configure_ssh() {
  SSH_ENABLED=${SSH_ENABLED:-false}
  if [[ "$SSH_ENABLED" != true ]]; then
    export TF_VAR_enable_ssh=false
    return
  fi

  command -v ssh-keygen >/dev/null 2>&1 || fail "ssh-keygen is not installed"
  command -v curl >/dev/null 2>&1 || fail "curl is not installed"
  command -v python3 >/dev/null 2>&1 || fail "python3 is not installed"

  SSH_KEY_PATH=${SSH_KEY_PATH:-.ssh/mde-linux-lab}
  if [[ "$SSH_KEY_PATH" != /* ]]; then
    SSH_KEY_PATH="$LINUX_ROOT/$SSH_KEY_PATH"
  fi

  mkdir -p "$(dirname "$SSH_KEY_PATH")"
  chmod 0700 "$(dirname "$SSH_KEY_PATH")"
  if [[ ! -s "$SSH_KEY_PATH" ]]; then
    printf 'Generating SSH key: %s\n' "$SSH_KEY_PATH"
    ssh-keygen -q -t ed25519 -N "" -C "mde-linux-lab" -f "$SSH_KEY_PATH"
  fi
  [[ -s "$SSH_KEY_PATH.pub" ]] || fail "SSH public key is missing: $SSH_KEY_PATH.pub"
  chmod 0600 "$SSH_KEY_PATH"
  chmod 0644 "$SSH_KEY_PATH.pub"

  SSH_ALLOWED_CIDR=${SSH_ALLOWED_CIDR:-}
  if [[ -z "$SSH_ALLOWED_CIDR" ]]; then
    PUBLIC_IPV4=$(curl -4fsS https://checkip.amazonaws.com | tr -d '[:space:]') ||
      fail "Could not detect the current public IPv4 address. Set SSH_ALLOWED_CIDR in lab.env.file."
    SSH_ALLOWED_CIDR="$PUBLIC_IPV4/32"
  fi

  SSH_ALLOWED_CIDR="$SSH_ALLOWED_CIDR" python3 - <<'PY'
import ipaddress
import os

network = ipaddress.ip_network(os.environ["SSH_ALLOWED_CIDR"], strict=False)
if network.version != 4:
    raise SystemExit("SSH_ALLOWED_CIDR must be IPv4")
PY

  export TF_VAR_enable_ssh=true
  export TF_VAR_ssh_allowed_cidr="$SSH_ALLOWED_CIDR"
  export TF_VAR_ssh_public_key
  TF_VAR_ssh_public_key=$(tr -d '\r\n' <"$SSH_KEY_PATH.pub")

  printf 'SSH source CIDR: %s\n' "$SSH_ALLOWED_CIDR"
  printf 'SSH private key: %s\n' "$SSH_KEY_PATH"
}

find_ami() {
  if [[ -f "$STATE_FILE" ]]; then
    # Contains generated AWS resource IDs only.
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  fi

  if [[ -z "${AMI_ID:-}" ]]; then
    local amis
    amis=$(aws ec2 describe-images --region "$AWS_REGION" --owners self --filters 'Name=tag:Name,Values=mde-al2023-golden' --query 'Images[].ImageId' --output text --no-cli-pager)
    local count
    count=$(printf '%s\n' "$amis" | wc -w | tr -d ' ')
    [[ "$count" == "1" ]] || fail "Expected exactly one MDE golden AMI, found $count. Run ./1-build-ami.sh or remove duplicates."
    AMI_ID=$amis
  fi
}

terraform_has_instance() {
  [[ -f terraform.tfstate ]] && terraform state list 2>/dev/null | grep -qx 'aws_instance.lab'
}

offboard_instance() {
  local offboard_script="$LINUX_ROOT/MicrosoftDefenderATPOffboardingLinuxServer.py"
  local instance_id bucket key uri parameters command_id

  instance_id=$(terraform output -raw instance_id)
  bucket=$(terraform output -raw onboarding_bucket)
  key='tenant/MicrosoftDefenderATPOnboardingLinuxServer.py'
  uri="s3://$bucket/$key"

  if [[ ! -s "$offboard_script" ]]; then
    [[ "$SKIP_OFFBOARD" == "--skip-offboard" ]] ||
      fail "Offboarding script is missing. Add MicrosoftDefenderATPOffboardingLinuxServer.py or rerun with destroy --skip-offboard."
    printf 'WARNING: Skipping MDE offboarding by explicit request.\n'
    return
  fi

  printf 'Staging the tenant offboarding script temporarily...\n'
  aws s3 cp "$offboard_script" "$uri" --sse AES256 --only-show-errors

  parameters=$(python3 - <<PY
import json
print(json.dumps({"commands": [
    "set -euo pipefail",
    "aws s3 cp '$uri' /tmp/offboard.py --only-show-errors",
    "chmod 0700 /tmp/offboard.py",
    "python3 /tmp/offboard.py",
    "rm -f /tmp/offboard.py"
]}))
PY
)

  command_id=$(aws ssm send-command \
    --region "$AWS_REGION" \
    --instance-ids "$instance_id" \
    --document-name AWS-RunShellScript \
    --parameters "$parameters" \
    --query 'Command.CommandId' \
    --output text \
    --no-cli-pager)

  aws ssm wait command-executed --region "$AWS_REGION" --command-id "$command_id" --instance-id "$instance_id"
  aws ssm get-command-invocation \
    --region "$AWS_REGION" \
    --command-id "$command_id" \
    --instance-id "$instance_id" \
    --query '{Status:Status,Output:StandardOutputContent,Error:StandardErrorContent}' \
    --output json \
    --no-cli-pager
}

case "$ACTION" in
  plan|apply)
    [[ -s terraform.tfvars ]] || fail "terraform.tfvars is missing"
    [[ -s MicrosoftDefenderATPOnboardingLinuxServer.py ]] || fail "Tenant onboarding script is missing"
    find_ami
    configure_ssh
    terraform init -input=false
    terraform fmt -check
    terraform validate
    terraform plan -input=false -var="ami_id=$AMI_ID" -out=tfplan
    if [[ "$ACTION" == apply ]]; then
      terraform apply -input=false tfplan
      if [[ "${TF_VAR_enable_ssh:-false}" == true ]]; then
        SSH_ASSOCIATION_ID=$(terraform output -raw ssh_association_id)
        aws ssm start-associations-once \
          --region "$AWS_REGION" \
          --association-ids "$SSH_ASSOCIATION_ID" \
          --no-cli-pager >/dev/null
        PUBLIC_IP=$(terraform output -raw public_ip)
        printf '\nSSH access is being applied through State Manager.\n'
        printf 'Check association status:\n'
        printf '  aws ssm describe-association --region %q --association-id %q --query AssociationDescription.Overview --output table\n' "$AWS_REGION" "$SSH_ASSOCIATION_ID"
        printf 'Connect after the association reports Success:\n'
        printf '  ssh -o StrictHostKeyChecking=accept-new -i %q ec2-user@%s\n' "$SSH_KEY_PATH" "$PUBLIC_IP"
      fi
      printf '\nBilling is now active for the EC2 instance, EBS volume, and public IPv4.\n'
      printf 'Destroy with: ./2-terraform-lab.sh destroy\n'
    else
      printf '\nPlan only; no AWS lab resources were created.\n'
    fi
    ;;
  status)
    if [[ ! -f terraform.tfstate ]]; then
      printf 'No Terraform state exists; the lab is not deployed.\n'
      exit 0
    fi
    terraform output || true
    terraform state list || true
    ;;
  destroy)
    if [[ ! -f terraform.tfstate ]] || [[ -z "$(terraform state list 2>/dev/null)" ]]; then
      printf 'No Terraform-managed lab resources exist.\n'
      rm -f tfplan
      exit 0
    fi
    find_ami
    if terraform_has_instance; then
      offboard_instance
    fi
    terraform destroy -auto-approve -input=false -var="ami_id=$AMI_ID"
    rm -f tfplan
    printf '\nTerraform-owned lab resources are removed.\n'
    printf 'The Packer AMI and snapshot remain until you run: ./3-deregister-ami.sh --confirm\n'
    ;;
esac
