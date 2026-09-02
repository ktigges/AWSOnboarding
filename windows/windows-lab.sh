#!/usr/bin/env bash

set -euo pipefail

WINDOWS_ROOT=$(cd "$(dirname "$0")" && pwd)
PROJECT_ROOT=$(cd "$WINDOWS_ROOT/.." && pwd)
ENV_FILE="$PROJECT_ROOT/lab.env.file"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

AWS_PROFILE=${AWS_PROFILE:-default}
AWS_REGION=${AWS_REGION:-us-west-2}
AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-$AWS_REGION}
AWS_PAGER=""
WINDOWS_KEY_PATH=${WINDOWS_KEY_PATH:-$WINDOWS_ROOT/.keys/mde-windows-lab.pem}
ACTION=${1:-}
SKIP_OFFBOARD=${2:-}

export AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION AWS_PAGER

fail() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

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
    printf 'AWS session is unavailable; starting browser login for profile %s\n' "$AWS_PROFILE"
    fresh_aws_login
  fi

  profile_aws sts get-caller-identity --no-cli-pager >/dev/null 2>&1 ||
    fail "AWS authentication failed"

  printf 'AWS account: '
  profile_aws sts get-caller-identity --query Account --output text --no-cli-pager
}

export_terraform_credentials() {
  local credentials
  if ! credentials=$(profile_aws configure export-credentials --format env); then
    printf 'Cached AWS credentials could not be exported; starting a fresh browser login.\n'
    fresh_aws_login
    credentials=$(profile_aws configure export-credentials --format env) ||
      fail "Could not export refreshed AWS credentials"
  fi
  eval "$credentials"
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_CREDENTIAL_EXPIRATION

  if aws sts get-caller-identity --no-cli-pager >/dev/null 2>&1; then
    return
  fi

  printf 'Exported AWS credentials are expired; starting a fresh browser login.\n'
  fresh_aws_login
  credentials=$(profile_aws configure export-credentials --format env) ||
    fail "Could not export refreshed AWS credentials"
  eval "$credentials"
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_CREDENTIAL_EXPIRATION
  aws sts get-caller-identity --no-cli-pager >/dev/null 2>&1 ||
    fail "Refreshed AWS credentials are still expired"
}

configure_administrator_key() {
  command -v ssh-keygen >/dev/null 2>&1 || fail "ssh-keygen is not installed"

  mkdir -p "$(dirname "$WINDOWS_KEY_PATH")"
  chmod 0700 "$(dirname "$WINDOWS_KEY_PATH")"

  if [[ ! -s "$WINDOWS_KEY_PATH" ]]; then
    printf 'Generating the Windows Administrator RSA key: %s\n' "$WINDOWS_KEY_PATH"
    ssh-keygen -q -t rsa -b 2048 -m PEM -N "" \
      -C "mde-windows-lab" -f "$WINDOWS_KEY_PATH"
  fi

  [[ -s "$WINDOWS_KEY_PATH.pub" ]] || fail "Public key is missing: $WINDOWS_KEY_PATH.pub"
  chmod 0600 "$WINDOWS_KEY_PATH"
  chmod 0644 "$WINDOWS_KEY_PATH.pub"

  export TF_VAR_administrator_public_key
  TF_VAR_administrator_public_key=$(tr -d '\r\n' <"$WINDOWS_KEY_PATH.pub")
}

terraform_has_instance() {
  [[ -f terraform.tfstate ]] &&
    terraform state list 2>/dev/null | grep -qx 'aws_instance.lab'
}

terraform_has_onboarding_association() {
  [[ -f terraform.tfstate ]] &&
    terraform state list 2>/dev/null | grep -qx 'aws_ssm_association.onboard'
}

windows_computer_name() {
  local instance_id parameters command_id computer_name
  instance_id=$(terraform output -raw instance_id)
  parameters=$(python3 - <<'PY'
import json

print(json.dumps({"commands": ["Write-Output $env:COMPUTERNAME"]}))
PY
)

  command_id=$(profile_aws ssm send-command \
    --region "$AWS_REGION" \
    --instance-ids "$instance_id" \
    --document-name AWS-RunPowerShellScript \
    --parameters "$parameters" \
    --query 'Command.CommandId' \
    --output text \
    --no-cli-pager)

  profile_aws ssm wait command-executed \
    --region "$AWS_REGION" \
    --command-id "$command_id" \
    --instance-id "$instance_id"

  computer_name=$(profile_aws ssm get-command-invocation \
    --region "$AWS_REGION" \
    --command-id "$command_id" \
    --instance-id "$instance_id" \
    --query StandardOutputContent \
    --output text \
    --no-cli-pager | tr -d '\r\n')

  [[ -n "$computer_name" && "$computer_name" != "None" ]] ||
    fail "Could not retrieve the Windows computer name through SSM"
  printf '%s' "$computer_name"
}

ensure_azure_auth() {
  command -v az >/dev/null 2>&1 || fail "Azure CLI is required for MDE API offboarding"
  local current_tenant
  current_tenant=$(az account show --query tenantId --output tsv 2>/dev/null || true)

  if [[ -n "${AZURE_TENANT_ID:-}" && "$current_tenant" != "$AZURE_TENANT_ID" ]]; then
    printf 'Azure session is missing or uses a different tenant; starting login for %s\n' "$AZURE_TENANT_ID"
    az login --tenant "$AZURE_TENANT_ID" >/dev/null
  elif [[ -z "$current_tenant" ]]; then
    fail "Azure CLI is not signed in. Set AZURE_TENANT_ID and run az login before destroy."
  fi

  az account show >/dev/null 2>&1 || fail "Azure authentication failed"
}

cleanup_directory_devices() {
  local device_name=$1

  if [[ "$SKIP_OFFBOARD" == "--skip-offboard" ]]; then
    printf 'WARNING: Skipping Intune and Entra cleanup because MDE offboarding was skipped.\n'
    return
  fi

  command -v pwsh >/dev/null 2>&1 || fail "PowerShell is required for Intune and Entra cleanup"
  if pwsh -NoProfile -File "$PROJECT_ROOT/scripts/cleanup_directory_devices.ps1" \
    -DeviceName "$device_name" \
    -TenantId "$AZURE_TENANT_ID"; then
    return
  fi

  printf '\nWARNING: Intune or Entra device cleanup failed.\n'
  if [[ -t 0 ]]; then
    local answer
    read -r -p "Continue AWS destroy and leave the stale directory object? [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] && return
  fi
  fail "AWS destroy stopped because directory cleanup was not approved"
}

windows_mde_is_offboarded() {
  local instance_id params_json command_id output
  instance_id=$(terraform output -raw instance_id)
  params_json=$(python3 - <<'PY'
import json

print(json.dumps({"commands": [
    "$sense = Get-Service Sense -ErrorAction SilentlyContinue",
    "$state = (Get-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows Advanced Threat Protection\\Status' -Name OnboardingState -ErrorAction SilentlyContinue).OnboardingState",
    "if (($null -eq $sense -or $sense.Status -ne 'Running') -and $state -eq 0) { Write-Output 'MDE_OFFBOARDED' } else { Write-Error ('MDE is not locally offboarded: Sense={0}, OnboardingState={1}' -f $sense.Status, $state); exit 1 }",
]}))
PY
)

  command_id=$(profile_aws ssm send-command \
    --region "$AWS_REGION" \
    --instance-ids "$instance_id" \
    --document-name AWS-RunPowerShellScript \
    --parameters "$params_json" \
    --query 'Command.CommandId' \
    --output text \
    --no-cli-pager)

  profile_aws ssm wait command-executed \
    --region "$AWS_REGION" \
    --command-id "$command_id" \
    --instance-id "$instance_id" >/dev/null 2>&1 || return 1

  output=$(profile_aws ssm get-command-invocation \
    --region "$AWS_REGION" \
    --command-id "$command_id" \
    --instance-id "$instance_id" \
    --query StandardOutputContent \
    --output text \
    --no-cli-pager)

  [[ "$output" == *MDE_OFFBOARDED* ]]
}

offboard_instance() {
  local device_name=${1:-}
  if [[ "$SKIP_OFFBOARD" == "--skip-offboard" ]]; then
    printf 'WARNING: Skipping MDE offboarding by explicit request.\n'
    return
  fi

  if windows_mde_is_offboarded; then
    printf 'MDE is already offboarded locally: Sense is stopped and OnboardingState is 0.\n'
    return
  fi

  command -v python3 >/dev/null 2>&1 || fail "Python 3 is required for MDE API offboarding"
  ensure_azure_auth

  export MDE_DEVICE_NAME MDE_ACCESS_TOKEN
  MDE_DEVICE_NAME=${device_name:-$(windows_computer_name)}
  MDE_ACCESS_TOKEN=$(az account get-access-token \
    --resource https://api.securitycenter.microsoft.com \
    --query accessToken \
    --output tsv)

  printf 'Offboarding MDE device through the API: %s\n' "$MDE_DEVICE_NAME"
  local api_exit=0
  python3 - <<'PY' || api_exit=$?
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request

API_ROOT = "https://api.security.microsoft.com/api"
DEVICE_NAME = os.environ["MDE_DEVICE_NAME"]
TOKEN = os.environ["MDE_ACCESS_TOKEN"]


def request_json(method, url, body=None, allow_not_found=False):
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {TOKEN}",
            "Accept": "application/json",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        detail = error.read(2000).decode(errors="replace")
        if allow_not_found and error.code == 404:
            return None
        raise SystemExit(f"{method} {url} failed: HTTP {error.code}: {detail}") from error


escaped_name = DEVICE_NAME.replace("'", "''")
query = (
    "DeviceInfo "
    f"| where DeviceName =~ '{escaped_name}' "
    "| summarize arg_max(Timestamp, *) by DeviceId "
    "| project DeviceId, DeviceName, OSPlatform, OnboardingStatus"
)
result = request_json("POST", f"{API_ROOT}/advancedqueries/run", {"Query": query})
matches = result.get("Results", [])
if len(matches) != 1:
    raise SystemExit(
        f"Expected one MDE device named {DEVICE_NAME!r}, found {len(matches)}; "
        "refusing to destroy without confirmed offboarding"
    )

machine = matches[0]
machine_id = machine["DeviceId"]
action = request_json(
    "POST",
    f"{API_ROOT}/machines/{urllib.parse.quote(machine_id, safe='')}/offboard",
    {"Comment": "AWS Windows lab teardown"},
)
action_id = action["id"]
print(f"MDE offboarding action created: {action_id}")

terminal = {"Succeeded", "Failed", "TimeOut", "Cancelled"}
deadline = time.monotonic() + 60
while time.monotonic() < deadline:
    polled_action = request_json(
        "GET",
        f"{API_ROOT}/machineactions/{action_id}",
        allow_not_found=True,
    )
    if polled_action is None:
        print("MDE offboarding action is not queryable yet; retrying")
        time.sleep(5)
        continue
    action = polled_action
    print(f"MDE offboarding status: {action.get('status')}")
    if action.get("status") in terminal:
        break
    time.sleep(5)

if action.get("status") in {"Pending", "InProgress"}:
  print(
    "MDE cloud action is still pending; checking the endpoint's local state"
  )
  raise SystemExit(10)
if action.get("status") != "Succeeded":
    raise SystemExit(
        f"MDE offboarding did not succeed: {json.dumps(action, sort_keys=True)}"
    )

print(f"MDE offboarding succeeded for {machine.get('DeviceName')}")
PY
  unset MDE_ACCESS_TOKEN

  if [[ "$api_exit" == 10 ]] && windows_mde_is_offboarded; then
    printf 'MDE offboarding confirmed locally: Sense is stopped and OnboardingState is 0.\n'
    return
  fi
  [[ "$api_exit" == 0 ]] || fail "MDE API offboarding was not confirmed"
}

ensure_aws_auth
export_terraform_credentials
cd "$WINDOWS_ROOT"

case "$ACTION" in
  plan|apply)
    [[ -s terraform.tfvars ]] || fail "windows/terraform.tfvars is missing"
    [[ -s WindowsDefenderATPOnboardingScript.cmd ]] ||
      fail "Extract the Group Policy onboarding file WindowsDefenderATPOnboardingScript.cmd into $WINDOWS_ROOT"
    configure_administrator_key
    terraform init -input=false
    terraform fmt -check
    terraform validate
    terraform plan -input=false -out=tfplan

    if [[ "$ACTION" == "apply" ]]; then
      terraform apply -input=false tfplan
      association_id=$(terraform output -raw onboarding_association_id)
      profile_aws ssm start-associations-once \
        --region "$AWS_REGION" \
        --association-ids "$association_id" \
        --no-cli-pager >/dev/null
      printf '\nWindows Server deployment started.\n'
      printf 'Check configuration with: %s status\n' "$0"
      printf 'Connect to the desktop with: %s/windows-rdp.sh\n' "$WINDOWS_ROOT"
      printf 'Billing is active until: %s destroy\n' "$0"
    else
      printf '\nPlan only; no Windows lab resources were created.\n'
    fi
    ;;
  status)
    if [[ ! -f terraform.tfstate ]] || [[ -z "$(terraform state list 2>/dev/null)" ]]; then
      printf 'No Windows Terraform state exists; the Windows lab is not deployed.\n'
      exit 0
    fi
    terraform output
    if terraform_has_instance; then
      instance_id=$(terraform output -raw instance_id)
      if ! terraform_has_onboarding_association; then
        printf '\nThe EC2 instance exists, but the onboarding association was not created.\n'
        printf 'This is a partial Terraform apply. Review the apply error before retrying.\n'
        exit 1
      fi
      association_id=$(terraform output -raw onboarding_association_id)
      profile_aws ssm describe-instance-information \
        --region "$AWS_REGION" \
        --filters "Key=InstanceIds,Values=$instance_id" \
        --query 'InstanceInformationList[].{InstanceId:InstanceId,PingStatus:PingStatus,Platform:PlatformName,AgentVersion:AgentVersion}' \
        --output table \
        --no-cli-pager
      profile_aws ssm describe-association \
        --region "$AWS_REGION" \
        --association-id "$association_id" \
        --query 'AssociationDescription.Overview' \
        --output table \
        --no-cli-pager

      execution_id=$(profile_aws ssm describe-association-executions \
        --region "$AWS_REGION" \
        --association-id "$association_id" \
        --query 'AssociationExecutions[0].ExecutionId' \
        --output text \
        --no-cli-pager)

      if [[ -n "$execution_id" && "$execution_id" != "None" ]]; then
        printf '\nLatest association execution:\n'
        profile_aws ssm describe-association-executions \
          --region "$AWS_REGION" \
          --association-id "$association_id" \
          --query 'AssociationExecutions[0].{ExecutionId:ExecutionId,Status:Status,DetailedStatus:DetailedStatus,CreatedTime:CreatedTime}' \
          --output table \
          --no-cli-pager

        printf '\nLatest execution target:\n'
        profile_aws ssm describe-association-execution-targets \
          --region "$AWS_REGION" \
          --association-id "$association_id" \
          --execution-id "$execution_id" \
          --query 'AssociationExecutionTargets[].{ResourceId:ResourceId,Status:Status,DetailedStatus:DetailedStatus,OutputSourceId:OutputSource.OutputSourceId,OutputSourceType:OutputSource.OutputSourceType}' \
          --output table \
          --no-cli-pager

        command_id=$(profile_aws ssm describe-association-execution-targets \
          --region "$AWS_REGION" \
          --association-id "$association_id" \
          --execution-id "$execution_id" \
          --query 'AssociationExecutionTargets[0].OutputSource.OutputSourceId' \
          --output text \
          --no-cli-pager)

        if [[ -n "$command_id" && "$command_id" != "None" ]]; then
          printf '\nRun Command output:\n'
          profile_aws ssm get-command-invocation \
            --region "$AWS_REGION" \
            --command-id "$command_id" \
            --instance-id "$instance_id" \
            --query '{Status:Status,StatusDetails:StatusDetails,ResponseCode:ResponseCode,Output:StandardOutputContent,Error:StandardErrorContent}' \
            --output json \
            --no-cli-pager || true

          printf '\nRun Command plugin details:\n'
          profile_aws ssm list-command-invocations \
            --region "$AWS_REGION" \
            --command-id "$command_id" \
            --details \
            --query 'CommandInvocations[0].CommandPlugins[].{Name:Name,Status:Status,StatusDetails:StatusDetails,ResponseCode:ResponseCode,Output:Output,StandardOutputUrl:StandardOutputUrl,StandardErrorUrl:StandardErrorUrl}' \
            --output json \
            --no-cli-pager || true
        fi
      fi
    fi
    ;;
  destroy)
    if [[ ! -f terraform.tfstate ]] || [[ -z "$(terraform state list 2>/dev/null)" ]]; then
      printf 'No Terraform-managed Windows lab resources exist.\n'
      rm -f tfplan
      exit 0
    fi
    configure_administrator_key
    if terraform_has_instance; then
      device_name=$(windows_computer_name)
      offboard_instance "$device_name"
      cleanup_directory_devices "$device_name"
    fi
    terraform destroy -auto-approve -input=false
    rm -f tfplan
    printf '\nWindows lab resources are removed.\n'
    ;;
esac