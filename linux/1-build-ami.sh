#!/usr/bin/env bash

set -euo pipefail

LINUX_ROOT=$(cd "$(dirname "$0")" && pwd)
PROJECT_ROOT=$(cd "$LINUX_ROOT/.." && pwd)
ENV_FILE="$PROJECT_ROOT/lab.env.file"
if [[ -f "$ENV_FILE" ]]; then
  # Shared non-secret lab settings.
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi
AWS_PROFILE=${AWS_PROFILE:-default}
AWS_REGION=${AWS_REGION:-us-west-2}
AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-$AWS_REGION}
AWS_PAGER=""
ROLE_NAME="mde-packer-ssm"
PROFILE_NAME="mde-packer-ssm"
SSM_POLICY_ARN="arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
STATE_FILE="$LINUX_ROOT/.ami-state.env"

export AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION AWS_PAGER

log() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"; }
profile_aws() {
  env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN -u AWS_CREDENTIAL_EXPIRATION \
    aws --profile "$AWS_PROFILE" "$@"
}
fresh_aws_login() {
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_CREDENTIAL_EXPIRATION
  aws logout --profile "$AWS_PROFILE" --no-cli-pager >/dev/null 2>&1 || true
  aws login --profile "$AWS_PROFILE"
}
ensure_aws_auth() {
  if ! profile_aws sts get-caller-identity --no-cli-pager >/dev/null 2>&1; then
    log "AWS session is unavailable; starting browser login for profile $AWS_PROFILE"
    fresh_aws_login
  fi
  profile_aws sts get-caller-identity --no-cli-pager >/dev/null 2>&1 || fail "AWS authentication failed"
  log "AWS authentication"
  profile_aws configure list --no-cli-pager
  profile_aws sts get-caller-identity --query '{Account:Account,Arn:Arn}' --output table --no-cli-pager
  if [[ -t 0 ]]; then
    read -r -p "Authentication verified. Press Enter to continue or Control-C to stop... "
  else
    printf 'Authentication verified. Non-interactive input detected; continuing in 3 seconds...\n'
    sleep 3
  fi
}

export_packer_credentials() {
  local credentials
  if ! credentials=$(profile_aws configure export-credentials --format env); then
    log "Cached AWS credentials could not be exported; starting a fresh browser login"
    fresh_aws_login
    credentials=$(profile_aws configure export-credentials --format env) ||
      fail "Could not export refreshed AWS credentials"
  fi
  eval "$credentials"
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_CREDENTIAL_EXPIRATION

  if aws sts get-caller-identity --no-cli-pager >/dev/null 2>&1; then
    return
  fi

  log "Exported AWS credentials are expired; starting a fresh browser login"
  fresh_aws_login
  credentials=$(profile_aws configure export-credentials --format env) ||
    fail "Could not export refreshed AWS credentials"
  eval "$credentials"
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_CREDENTIAL_EXPIRATION
  aws sts get-caller-identity --no-cli-pager >/dev/null 2>&1 ||
    fail "Refreshed AWS credentials are still expired"
}

require_command aws
ensure_aws_auth
[[ $# -eq 0 ]] || fail "Usage: $0"

for tool in packer session-manager-plugin python3; do require_command "$tool"; done
[[ -s "$LINUX_ROOT/mde-al2023.pkr.hcl" ]] || fail "Missing linux/mde-al2023.pkr.hcl"
[[ -s "$LINUX_ROOT/assets/mdatp_managed.json.tmpl" ]] || fail "Missing Linux managed JSON template"
[[ -s "$LINUX_ROOT/scripts/validate_mde_unonboarded.py" ]] || fail "Missing Linux MDE validator"

log "Ensuring the Packer IAM role and instance profile exist"
TRUST_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

if ! aws iam get-role --role-name "$ROLE_NAME" --no-cli-pager >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$TRUST_POLICY" --no-cli-pager >/dev/null
fi
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$SSM_POLICY_ARN" --no-cli-pager

if ! aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" --no-cli-pager >/dev/null 2>&1; then
  aws iam create-instance-profile --instance-profile-name "$PROFILE_NAME" --no-cli-pager >/dev/null
fi

CURRENT_ROLE=$(aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" --query 'InstanceProfile.Roles[0].RoleName' --output text --no-cli-pager)
if [[ "$CURRENT_ROLE" == "None" ]]; then
  aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE_NAME" --role-name "$ROLE_NAME" --no-cli-pager
elif [[ "$CURRENT_ROLE" != "$ROLE_NAME" ]]; then
  fail "Instance profile $PROFILE_NAME contains unexpected role $CURRENT_ROLE"
fi

EXISTING_AMIS=$(aws ec2 describe-images \
  --region "$AWS_REGION" \
  --owners self \
  --filters 'Name=tag:Name,Values=mde-al2023-golden' \
  --query 'sort_by(Images,&CreationDate)[].ImageId' \
  --output text \
  --no-cli-pager)

if [[ -n "$EXISTING_AMIS" ]]; then
  AMI_COUNT=$(printf '%s\n' "$EXISTING_AMIS" | wc -w | tr -d ' ')
  [[ "$AMI_COUNT" == "1" ]] || fail "Multiple MDE golden AMIs exist: $EXISTING_AMIS. Deregister extras first."
  AMI_ID=$EXISTING_AMIS
  SNAPSHOT_IDS=$(aws ec2 describe-images --region "$AWS_REGION" --image-ids "$AMI_ID" --query 'Images[0].BlockDeviceMappings[].Ebs.SnapshotId' --output text --no-cli-pager)
  printf "AMI_ID='%s'\nSNAPSHOT_IDS='%s'\nAWS_REGION='%s'\n" "$AMI_ID" "$SNAPSHOT_IDS" "$AWS_REGION" >"$STATE_FILE"
  log "Existing AMI adopted; no new billable build was started"
  printf 'AMI: %s\nSnapshot(s): %s\n' "$AMI_ID" "$SNAPSHOT_IDS"
  exit 0
fi

log "Exporting temporary aws login credentials for Packer"
export_packer_credentials

cd "$LINUX_ROOT"
log "Validating Packer"
packer init mde-al2023.pkr.hcl
packer fmt -check mde-al2023.pkr.hcl
packer validate mde-al2023.pkr.hcl

log "Building the AMI"
set -o pipefail
packer build -color=false mde-al2023.pkr.hcl | tee packer-build.log

AMI_ID=$(aws ec2 describe-images \
  --region "$AWS_REGION" \
  --owners self \
  --filters 'Name=tag:Name,Values=mde-al2023-golden' \
  --query 'reverse(sort_by(Images,&CreationDate))[0].ImageId' \
  --output text \
  --no-cli-pager)
[[ "$AMI_ID" == ami-* ]] || fail "Build completed but no tagged AMI was found"

SNAPSHOT_IDS=$(aws ec2 describe-images --region "$AWS_REGION" --image-ids "$AMI_ID" --query 'Images[0].BlockDeviceMappings[].Ebs.SnapshotId' --output text --no-cli-pager)
printf "AMI_ID='%s'\nSNAPSHOT_IDS='%s'\nAWS_REGION='%s'\n" "$AMI_ID" "$SNAPSHOT_IDS" "$AWS_REGION" >"$STATE_FILE"

log "AMI build complete"
aws ec2 describe-images --region "$AWS_REGION" --image-ids "$AMI_ID" --query 'Images[0].{ImageId:ImageId,Name:Name,State:State,Snapshot:BlockDeviceMappings[0].Ebs.SnapshotId}' --output table --no-cli-pager
printf '\nRecorded in %s\n' "$STATE_FILE"
