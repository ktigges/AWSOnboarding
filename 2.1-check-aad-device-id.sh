#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "$0")" && pwd)
LINUX_ROOT="$PROJECT_ROOT/linux"
WINDOWS_ROOT="$PROJECT_ROOT/windows"
ENV_FILE="$PROJECT_ROOT/lab.env.file"
if [[ -f "$ENV_FILE" ]]; then
  # Shared non-secret lab settings.
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi
AWS_PROFILE=${AWS_PROFILE:-default}
AWS_REGION=${AWS_REGION:-us-west-2}
AWS_PAGER=""

export AWS_PROFILE AWS_REGION AWS_PAGER

profile_aws() {
  env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
    aws --profile "$AWS_PROFILE" "$@"
}

fail() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

APPLY_EXTENSION_ATTRIBUTE=false
HOSTNAME_ARGUMENT=""
for ARG in "$@"; do
  case "$ARG" in
    --apply)
      APPLY_EXTENSION_ATTRIBUTE=true
      ;;
    --*)
      fail "Unknown option: $ARG"
      ;;
    *)
      [[ -z "$HOSTNAME_ARGUMENT" ]] || fail "Only one hostname can be supplied."
      HOSTNAME_ARGUMENT=$ARG
      ;;
  esac
done

DEVICE_NAMES=()
if [[ -n "$HOSTNAME_ARGUMENT" ]]; then
  DEVICE_NAMES+=("$HOSTNAME_ARGUMENT")
elif [[ -n "${LAB_DEVICE_DNS_NAME:-}" ]]; then
  DEVICE_NAMES+=("$LAB_DEVICE_DNS_NAME")
else
  command -v terraform >/dev/null 2>&1 || fail "Terraform is unavailable. Pass the hostname as the first argument."
  command -v aws >/dev/null 2>&1 || fail "AWS CLI is unavailable. Pass the hostname as the first argument."

  if ! profile_aws sts get-caller-identity --no-cli-pager >/dev/null 2>&1; then
    printf 'AWS session is unavailable; starting browser login for profile %s\n' "$AWS_PROFILE"
    aws login --profile "$AWS_PROFILE"
  fi

  printf '\nAWS authentication:\n'
  profile_aws sts get-caller-identity \
    --query '{Account:Account,Arn:Arn}' \
    --output table \
    --no-cli-pager

  LINUX_INSTANCE_ID=$(terraform -chdir="$LINUX_ROOT" output -raw instance_id 2>/dev/null || true)
  if [[ -n "$LINUX_INSTANCE_ID" ]]; then
    LINUX_DEVICE_NAME=$(profile_aws ec2 describe-instances \
      --region "$AWS_REGION" \
      --instance-ids "$LINUX_INSTANCE_ID" \
      --query 'Reservations[0].Instances[0].PrivateDnsName' \
      --output text \
      --no-cli-pager)
    if [[ -n "$LINUX_DEVICE_NAME" && "$LINUX_DEVICE_NAME" != "None" ]]; then
      DEVICE_NAMES+=("$LINUX_DEVICE_NAME")
      printf 'Discovered Linux MDE device name: %s\n' "$LINUX_DEVICE_NAME"
    fi
  fi

  WINDOWS_INSTANCE_ID=$(terraform -chdir="$WINDOWS_ROOT" output -raw instance_id 2>/dev/null || true)
  if [[ -n "$WINDOWS_INSTANCE_ID" ]]; then
    PARAMETERS='{"commands":["Write-Output $env:COMPUTERNAME"]}'
    COMMAND_ID=$(profile_aws ssm send-command \
      --region "$AWS_REGION" \
      --instance-ids "$WINDOWS_INSTANCE_ID" \
      --document-name AWS-RunPowerShellScript \
      --parameters "$PARAMETERS" \
      --query 'Command.CommandId' \
      --output text \
      --no-cli-pager)
    profile_aws ssm wait command-executed \
      --region "$AWS_REGION" \
      --command-id "$COMMAND_ID" \
      --instance-id "$WINDOWS_INSTANCE_ID"
    WINDOWS_DEVICE_NAME=$(profile_aws ssm get-command-invocation \
      --region "$AWS_REGION" \
      --command-id "$COMMAND_ID" \
      --instance-id "$WINDOWS_INSTANCE_ID" \
      --query StandardOutputContent \
      --output text \
      --no-cli-pager | tr -d '\r\n')
    if [[ -n "$WINDOWS_DEVICE_NAME" && "$WINDOWS_DEVICE_NAME" != "None" ]]; then
      DEVICE_NAMES+=("$WINDOWS_DEVICE_NAME")
      printf 'Discovered Windows MDE device name: %s\n' "$WINDOWS_DEVICE_NAME"
    fi
  fi
fi

[[ ${#DEVICE_NAMES[@]} -gt 0 ]] ||
  fail "No deployed Linux or Windows devices were discovered. Pass an MDE device name as the first argument."

export APPLY_EXTENSION_ATTRIBUTE

command -v az >/dev/null 2>&1 || fail "Azure CLI is not installed."

CURRENT_TENANT=$(az account show --query tenantId --output tsv 2>/dev/null || true)
AZURE_TENANT_ID=${AZURE_TENANT_ID:-}

if [[ -n "$AZURE_TENANT_ID" && "$CURRENT_TENANT" != "$AZURE_TENANT_ID" ]]; then
  printf 'Azure session is missing or uses a different tenant; starting login for %s\n' "$AZURE_TENANT_ID"
  az login --tenant "$AZURE_TENANT_ID" >/dev/null
elif [[ -z "$CURRENT_TENANT" ]]; then
  if [[ -z "$AZURE_TENANT_ID" ]]; then
    if [[ -t 0 ]]; then
      read -r -p "Enter the Entra tenant ID: " AZURE_TENANT_ID
    else
      fail "Azure CLI is not signed in. Set AZURE_TENANT_ID and rerun."
    fi
  fi
  [[ -n "$AZURE_TENANT_ID" ]] || fail "Entra tenant ID cannot be empty."
  printf 'Starting Azure login for tenant %s\n' "$AZURE_TENANT_ID"
  az login --tenant "$AZURE_TENANT_ID" >/dev/null
fi

az account show >/dev/null 2>&1 || fail "Azure authentication failed."

verify_graph_auth() {
  az rest \
    --method get \
    --url "https://graph.microsoft.com/v1.0/devices?\$select=id&\$top=1" \
    --output none >/dev/null 2>&1
}

if ! verify_graph_auth; then
  [[ -n "$AZURE_TENANT_ID" ]] || fail "Microsoft Graph authentication requires AZURE_TENANT_ID."
  printf 'Microsoft Graph token is stale or requires interaction; refreshing Azure sign-in.\n'
  az logout >/dev/null 2>&1 || true
  az login \
    --tenant "$AZURE_TENANT_ID" \
    --scope "https://graph.microsoft.com/.default" >/dev/null
  if [[ -n "${AZURE_SUBSCRIPTION_ID:-}" ]]; then
    az account set --subscription "$AZURE_SUBSCRIPTION_ID"
  fi
  verify_graph_auth || fail "Microsoft Graph authentication still requires interaction after sign-in."
fi

printf '\nAzure authentication:\n'
az account show \
  --query '{Subscription:name,SubscriptionId:id,TenantId:tenantId,User:user.name}' \
  --output table

if [[ "$APPLY_EXTENSION_ATTRIBUTE" == true ]]; then
  printf '\nWRITE MODE: extensionAttribute1 will be updated only after unique target verification.\n'
fi

printf 'Azure and Microsoft Graph authentication verified.\n'

if [[ -x "$PROJECT_ROOT/.venv/bin/python" ]]; then
  PYTHON="$PROJECT_ROOT/.venv/bin/python"
else
  command -v python3 >/dev/null 2>&1 || fail "Python 3 is not installed."
  PYTHON=$(command -v python3)
fi

printf 'Python: %s\n' "$PYTHON"
FAILED=0
for LAB_DEVICE_DNS_NAME in "${DEVICE_NAMES[@]}"; do
  export LAB_DEVICE_DNS_NAME
  printf '\nChecking MDE device: %s\n' "$LAB_DEVICE_DNS_NAME"
  if ! "$PYTHON" "$PROJECT_ROOT/scripts/gate_aad_device_id.py"; then
    FAILED=$((FAILED + 1))
  fi
done

if [[ "$FAILED" -ne 0 ]]; then
  fail "$FAILED of ${#DEVICE_NAMES[@]} device checks failed"
fi

printf '\nAll %s device checks completed successfully.\n' "${#DEVICE_NAMES[@]}"
