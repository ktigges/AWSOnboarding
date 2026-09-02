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
WINDOWS_KEY_PATH=${WINDOWS_KEY_PATH:-$WINDOWS_ROOT/.keys/mde-windows-lab.pem}
LOCAL_RDP_PORT=${LOCAL_RDP_PORT:-13389}

export AWS_PROFILE AWS_REGION AWS_PAGER

fail() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

command -v aws >/dev/null 2>&1 || fail "AWS CLI is not installed"
command -v session-manager-plugin >/dev/null 2>&1 ||
  fail "The Session Manager plugin is not installed"
[[ -s "$WINDOWS_KEY_PATH" ]] || fail "Administrator private key is missing: $WINDOWS_KEY_PATH"
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
ping_status=$(profile_aws ssm describe-instance-information \
  --region "$AWS_REGION" \
  --filters "Key=InstanceIds,Values=$instance_id" \
  --query 'InstanceInformationList[0].PingStatus' \
  --output text \
  --no-cli-pager)
[[ "$ping_status" == "Online" ]] || fail "The instance is not online in SSM: $ping_status"

password=$(profile_aws ec2 get-password-data \
  --region "$AWS_REGION" \
  --instance-id "$instance_id" \
  --priv-launch-key "$WINDOWS_KEY_PATH" \
  --query PasswordData \
  --output text \
  --no-cli-pager)

[[ -n "$password" && "$password" != "None" ]] ||
  fail "The Windows password is not ready yet. Retry after EC2 finishes initialization."

cat <<EOF

Windows desktop connection

PC name:  localhost:$LOCAL_RDP_PORT
User:     Administrator
Password: $password

Keep this terminal open while using the desktop.
Add localhost:$LOCAL_RDP_PORT in Windows App on macOS.

EOF

open -a "Windows App" 2>/dev/null || open -a "Microsoft Remote Desktop" 2>/dev/null || true

exec env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
  aws --profile "$AWS_PROFILE" ssm start-session \
  --region "$AWS_REGION" \
  --target "$instance_id" \
  --document-name AWS-StartPortForwardingSession \
  --parameters "portNumber=3389,localPortNumber=$LOCAL_RDP_PORT"