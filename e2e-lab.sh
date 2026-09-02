#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "$0")" && pwd)
BUILD_AMI=false
WINDOWS_ONLY=false
LINUX_ONLY=false
TEARDOWN=false
DELETE_AMI=false
SKIP_OFFBOARD=false

fail() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage:
  $0 [--build-ami] [--windows-only | --linux-only]
  $0 --teardown [--windows-only | --linux-only] [--delete-ami] [--skip-offboard]

Deploy options:
  --build-ami      Build or adopt the Linux MDE AMI before deployment.
  --windows-only   Run only the Windows workflow.
  --linux-only     Run only the Linux workflow.

Teardown options:
  --teardown       Offboard and destroy the selected platform resources.
  --delete-ami     Deregister the Linux AMI and delete its snapshot after teardown.
  --skip-offboard  Explicitly skip MDE, Intune, and Entra cleanup.
  --help           Show this help text.

The Azure Function is not managed by this script.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-ami)
      BUILD_AMI=true
      ;;
    --windows-only)
      WINDOWS_ONLY=true
      ;;
    --linux-only)
      LINUX_ONLY=true
      ;;
    --teardown)
      TEARDOWN=true
      ;;
    --delete-ami)
      DELETE_AMI=true
      ;;
    --skip-offboard)
      SKIP_OFFBOARD=true
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
  shift
done

[[ "$WINDOWS_ONLY" != true || "$LINUX_ONLY" != true ]] ||
  fail "--windows-only and --linux-only cannot be used together"
[[ "$TEARDOWN" == true || "$DELETE_AMI" != true ]] ||
  fail "--delete-ami requires --teardown"
[[ "$TEARDOWN" == true || "$SKIP_OFFBOARD" != true ]] ||
  fail "--skip-offboard requires --teardown"
[[ "$TEARDOWN" != true || "$BUILD_AMI" != true ]] ||
  fail "--build-ami cannot be used with --teardown"
[[ "$WINDOWS_ONLY" != true || "$BUILD_AMI" != true ]] ||
  fail "--build-ami cannot be used with --windows-only"
[[ "$WINDOWS_ONLY" != true || "$DELETE_AMI" != true ]] ||
  fail "--delete-ami cannot be used with --windows-only"

RUN_LINUX=true
RUN_WINDOWS=true
if [[ "$WINDOWS_ONLY" == true ]]; then
  RUN_LINUX=false
elif [[ "$LINUX_ONLY" == true ]]; then
  RUN_WINDOWS=false
fi

run_step() {
  local label=$1
  shift
  printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$label"
  "$@"
}

for script in \
  "$PROJECT_ROOT/linux/1-build-ami.sh" \
  "$PROJECT_ROOT/linux/2-terraform-lab.sh" \
  "$PROJECT_ROOT/linux/3-deregister-ami.sh" \
  "$PROJECT_ROOT/windows/windows-lab.sh"; do
  [[ -x "$script" ]] || fail "Required executable script is missing: $script"
done

if [[ "$TEARDOWN" == true ]]; then
  if [[ "$RUN_WINDOWS" == true ]]; then
    if [[ "$SKIP_OFFBOARD" == true ]]; then
      run_step "Tearing down Windows without offboarding" \
        "$PROJECT_ROOT/windows/windows-lab.sh" destroy --skip-offboard
    else
      run_step "Offboarding and tearing down Windows" \
        "$PROJECT_ROOT/windows/windows-lab.sh" destroy
    fi
  fi

  if [[ "$RUN_LINUX" == true ]]; then
    if [[ "$SKIP_OFFBOARD" == true ]]; then
      run_step "Tearing down Linux without offboarding" \
        "$PROJECT_ROOT/linux/2-terraform-lab.sh" destroy --skip-offboard
    else
      run_step "Offboarding and tearing down Linux" \
        "$PROJECT_ROOT/linux/2-terraform-lab.sh" destroy
    fi

    if [[ "$DELETE_AMI" == true ]]; then
      run_step "Deleting the Linux AMI and snapshot" \
        "$PROJECT_ROOT/linux/3-deregister-ami.sh" --confirm
    fi
  fi

  printf '\nEnd-to-end teardown completed.\n'
  exit 0
fi

if [[ "$RUN_LINUX" == true ]]; then
  if [[ "$BUILD_AMI" == true ]]; then
    run_step "Building or adopting the Linux AMI" \
      "$PROJECT_ROOT/linux/1-build-ami.sh"
  fi
  run_step "Deploying and onboarding Linux" \
    "$PROJECT_ROOT/linux/2-terraform-lab.sh" apply
fi

if [[ "$RUN_WINDOWS" == true ]]; then
  run_step "Deploying and onboarding Windows" \
    "$PROJECT_ROOT/windows/windows-lab.sh" apply
fi

printf '\nEnd-to-end AWS deployment started.\n'
printf 'Check Linux:  ./linux/2-terraform-lab.sh status\n'
printf 'Check Windows: ./windows/windows-lab.sh status\n'
printf 'The Azure Function runs independently and is not changed by this script.\n'