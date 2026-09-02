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

fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
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
[[ "${1:-}" == "--confirm" ]] || fail "Usage: $0 --confirm"

AMI_IDS=$(profile_aws ec2 describe-images \
  --region "$AWS_REGION" \
  --owners self \
  --filters 'Name=tag:Name,Values=mde-al2023-golden' \
  --query 'Images[].ImageId' \
  --output text \
  --no-cli-pager)

if [[ -n "$AMI_IDS" ]]; then
  for AMI_ID in $AMI_IDS; do
    IN_USE=$(profile_aws ec2 describe-instances \
      --region "$AWS_REGION" \
      --filters "Name=image-id,Values=$AMI_ID" 'Name=instance-state-name,Values=pending,running,stopping,stopped' \
      --query 'Reservations[].Instances[].InstanceId' \
      --output text \
      --no-cli-pager)
    [[ -z "$IN_USE" ]] || fail "AMI $AMI_ID is used by instance(s): $IN_USE. Destroy or terminate them first."
  done
fi

if profile_aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" --no-cli-pager >/dev/null 2>&1; then
  PROFILE_ARN=$(profile_aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" --query 'InstanceProfile.Arn' --output text --no-cli-pager)
  PROFILE_ASSOCIATIONS=$(profile_aws ec2 describe-iam-instance-profile-associations \
    --region "$AWS_REGION" \
    --filters 'Name=state,Values=associating,associated' \
    --query "IamInstanceProfileAssociations[?IamInstanceProfile.Arn=='$PROFILE_ARN'].InstanceId" \
    --output text \
    --no-cli-pager)
  [[ -z "$PROFILE_ASSOCIATIONS" ]] || fail "Packer instance profile is still attached to instance(s): $PROFILE_ASSOCIATIONS"
fi

SNAPSHOT_IDS=""
if [[ -n "$AMI_IDS" ]]; then
  SNAPSHOT_IDS=$(profile_aws ec2 describe-images \
    --region "$AWS_REGION" \
    --image-ids $AMI_IDS \
    --query 'Images[].BlockDeviceMappings[].Ebs.SnapshotId' \
    --output text \
    --no-cli-pager)
fi

printf 'Deregistering AMI(s): %s\n' "${AMI_IDS:-none}"
for AMI_ID in $AMI_IDS; do
  profile_aws ec2 deregister-image --region "$AWS_REGION" --image-id "$AMI_ID" --no-cli-pager
done

if [[ -z "$SNAPSHOT_IDS" ]]; then
  SNAPSHOT_IDS=$(profile_aws ec2 describe-snapshots \
    --region "$AWS_REGION" \
    --owner-ids self \
    --filters 'Name=tag:Name,Values=mde-al2023-golden' \
    --query 'Snapshots[].SnapshotId' \
    --output text \
    --no-cli-pager)
fi

printf 'Deleting backing snapshot(s): %s\n' "${SNAPSHOT_IDS:-none}"
for SNAPSHOT_ID in $SNAPSHOT_IDS; do
  profile_aws ec2 delete-snapshot --region "$AWS_REGION" --snapshot-id "$SNAPSHOT_ID" --no-cli-pager
done

if profile_aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" --no-cli-pager >/dev/null 2>&1; then
  ATTACHED_ROLE=$(profile_aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" --query 'InstanceProfile.Roles[0].RoleName' --output text --no-cli-pager)
  if [[ "$ATTACHED_ROLE" != "None" ]]; then
    profile_aws iam remove-role-from-instance-profile --instance-profile-name "$PROFILE_NAME" --role-name "$ATTACHED_ROLE" --no-cli-pager
  fi
  profile_aws iam delete-instance-profile --instance-profile-name "$PROFILE_NAME" --no-cli-pager
fi

if profile_aws iam get-role --role-name "$ROLE_NAME" --no-cli-pager >/dev/null 2>&1; then
  profile_aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$SSM_POLICY_ARN" --no-cli-pager || true
  profile_aws iam delete-role --role-name "$ROLE_NAME" --no-cli-pager
fi

rm -f "$STATE_FILE" "$LINUX_ROOT/packer-build.log" "$LINUX_ROOT/packer-manifest.json"

printf '\nAMI cleanup complete. Remaining matching AMIs: '
profile_aws ec2 describe-images --region "$AWS_REGION" --owners self --filters 'Name=tag:Name,Values=mde-al2023-golden' --query 'length(Images)' --output text --no-cli-pager
printf 'Remaining matching snapshots: '
profile_aws ec2 describe-snapshots --region "$AWS_REGION" --owner-ids self --filters 'Name=tag:Name,Values=mde-al2023-golden' --query 'length(Snapshots)' --output text --no-cli-pager
