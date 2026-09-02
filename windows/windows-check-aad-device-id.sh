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
AWS_PAGER=""

export AWS_PROFILE AWS_REGION AWS_PAGER

fail() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

command -v aws >/dev/null 2>&1 || fail "AWS CLI is not installed"
command -v terraform >/dev/null 2>&1 || fail "Terraform is not installed"
[[ -f "$WINDOWS_ROOT/terraform.tfstate" ]] || fail "The Windows lab is not deployed"

profile_aws() {
  env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
    aws --profile "$AWS_PROFILE" "$@"
}

if ! profile_aws sts get-caller-identity --no-cli-pager >/dev/null 2>&1; then
  printf 'AWS session is unavailable; starting browser login for profile %s\n' "$AWS_PROFILE"
  aws login --profile "$AWS_PROFILE"
fi

instance_id=$(terraform -chdir="$WINDOWS_ROOT" output -raw instance_id)
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

printf 'Windows MDE device name: %s\n' "$computer_name"
exec "$PROJECT_ROOT/2.1-check-aad-device-id.sh" "$computer_name" "$@"