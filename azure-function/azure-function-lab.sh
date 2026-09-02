#!/usr/bin/env bash

set -euo pipefail

FUNCTION_ROOT=$(cd "$(dirname "$0")" && pwd)
PROJECT_ROOT=$(cd "$FUNCTION_ROOT/.." && pwd)
TERRAFORM_ROOT="$FUNCTION_ROOT/terraform"
ENV_FILE="$PROJECT_ROOT/lab.env.file"
ACTION=${1:-}

if [[ -f "$ENV_FILE" ]]; then
  # Shared non-secret tenant and subscription settings.
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

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
  $0 destroy
EOF
  exit 1
}

[[ "$ACTION" =~ ^(plan|apply|status|destroy)$ ]] || usage

command -v az >/dev/null 2>&1 || fail "Azure CLI is not installed"
command -v terraform >/dev/null 2>&1 || fail "Terraform is not installed"

AZURE_TENANT_ID=${AZURE_TENANT_ID:-}
AZURE_SUBSCRIPTION_ID=${AZURE_SUBSCRIPTION_ID:-}
[[ -n "$AZURE_TENANT_ID" ]] || fail "AZURE_TENANT_ID is missing from lab.env.file"
[[ -n "$AZURE_SUBSCRIPTION_ID" ]] || fail "AZURE_SUBSCRIPTION_ID is missing from lab.env.file"

ensure_azure_auth() {
  local current_tenant current_subscription auth_valid
  current_tenant=$(az account show --query tenantId --output tsv 2>/dev/null || true)
  auth_valid=false

  if [[ "$current_tenant" == "$AZURE_TENANT_ID" ]] &&
    az account set --subscription "$AZURE_SUBSCRIPTION_ID" >/dev/null 2>&1 &&
    az account get-access-token \
      --resource https://graph.microsoft.com \
      --query accessToken \
      --output tsv >/dev/null 2>&1 &&
    az rest \
      --method get \
      --url "https://graph.microsoft.com/v1.0/servicePrincipals?\$filter=appId%20eq%20'00000003-0000-0000-c000-000000000000'&\$select=id" \
      --output none >/dev/null 2>&1 &&
    az account get-access-token \
      --resource https://management.azure.com/ \
      --query accessToken \
      --output tsv >/dev/null 2>&1; then
    auth_valid=true
  fi

  if [[ "$auth_valid" != true ]]; then
    printf 'Starting Azure login for tenant %s\n' "$AZURE_TENANT_ID"
    az login --tenant "$AZURE_TENANT_ID" >/dev/null
  fi

  az account set --subscription "$AZURE_SUBSCRIPTION_ID"
  current_tenant=$(az account show --query tenantId --output tsv 2>/dev/null || true)
  current_subscription=$(az account show --query id --output tsv 2>/dev/null || true)
  [[ "$current_tenant" == "$AZURE_TENANT_ID" ]] || fail "Azure tenant verification failed"
  [[ "$current_subscription" == "$AZURE_SUBSCRIPTION_ID" ]] || fail "Azure subscription verification failed"

  az account get-access-token \
    --resource https://graph.microsoft.com \
    --query accessToken \
    --output tsv >/dev/null 2>&1 || fail "Microsoft Graph authentication failed"
  az rest \
    --method get \
    --url "https://graph.microsoft.com/v1.0/servicePrincipals?\$filter=appId%20eq%20'00000003-0000-0000-c000-000000000000'&\$select=id" \
    --output none >/dev/null 2>&1 || fail "Microsoft Graph service-principal access failed; run az logout, then retry"
  az account get-access-token \
    --resource https://management.azure.com/ \
    --query accessToken \
    --output tsv >/dev/null 2>&1 || fail "Azure Resource Manager authentication failed"

  printf 'Azure context:\n'
  az account show \
    --query '{Subscription:name,SubscriptionId:id,TenantId:tenantId,User:user.name}' \
    --output table
}

terraform_has_resources() {
  [[ -f "$TERRAFORM_ROOT/terraform.tfstate" ]] &&
    [[ -n "$(terraform -chdir="$TERRAFORM_ROOT" state list 2>/dev/null)" ]]
}

confirm_storage_access() {
  local response

  printf '\nBefore continuing, verify the Function storage account has:\n'
  printf '  - Public network access enabled\n'
  printf '  - Allow storage account key access enabled\n'
  read -r -p 'Have you verified both settings? [y/N] ' response
  [[ "$response" =~ ^[Yy]$ ]] || fail "Storage access was not confirmed"
}

build_function_package() {
  local package_path=$1
  local build_dir
  build_dir=$(mktemp -d)

  printf '\nBuilding Linux Python 3.12 Function package...\n'
  if ! python3 -m pip install \
    --target "$build_dir/.python_packages/lib/site-packages" \
    --platform manylinux2014_x86_64 \
    --implementation cp \
    --python-version 3.12 \
    --only-binary=:all: \
    --requirement "$FUNCTION_ROOT/requirements.txt"; then
    rm -rf "$build_dir"
    fail "Function dependency packaging failed"
  fi

  cp "$FUNCTION_ROOT/function_app.py" "$build_dir/function_app.py"
  cp "$FUNCTION_ROOT/host.json" "$build_dir/host.json"
  cp "$FUNCTION_ROOT/requirements.txt" "$build_dir/requirements.txt"
  rm -f "$package_path"
  pushd "$build_dir" >/dev/null
  zip -q -r "$package_path" .
  popd >/dev/null
  rm -rf "$build_dir"
}

prepare_flex_deployment() {
  local resource_group=$1
  local function_app=$2

  printf '\nClearing legacy remote-build settings...\n'
  az functionapp config appsettings delete \
    --resource-group "$resource_group" \
    --name "$function_app" \
    --setting-names SCM_DO_BUILD_DURING_DEPLOYMENT ENABLE_ORYX_BUILD \
    --only-show-errors \
    --output none

  printf 'Restarting Function App to refresh deployment settings...\n'
  az functionapp restart \
    --resource-group "$resource_group" \
    --name "$function_app" \
    --only-show-errors
}

deploy_function_package() {
  local resource_group=$1
  local function_app=$2
  local package_path=$3
  local attempt

  [[ -s "$package_path" ]] || fail "Function package is missing: $package_path"

  for attempt in {1..6}; do
    printf '\nPublishing Function package (attempt %s of 6)...\n' "$attempt"
    if az functionapp deployment source config-zip \
      --resource-group "$resource_group" \
      --name "$function_app" \
      --src "$package_path" \
      --build-remote false \
      --timeout 600 \
      --only-show-errors \
      --output none; then
      return 0
    fi

    if [[ "$attempt" -lt 6 ]]; then
      printf 'Deployment endpoint is not ready; retrying.\n'
    fi
  done

  fail "Function package deployment failed after 6 attempts"
}

graph_service_principal_id() {
  az rest \
    --method get \
    --url "https://graph.microsoft.com/v1.0/servicePrincipals?\$filter=appId%20eq%20'00000003-0000-0000-c000-000000000000'&\$select=id" \
    --query 'value[0].id' \
    --output tsv
}

assign_graph_role() {
  local principal_id=$1
  local graph_principal_id=$2
  local role_id=$3
  local role_name=$4
  local assignment_id body

  assignment_id=$(az rest \
    --method get \
    --url "https://graph.microsoft.com/v1.0/servicePrincipals/$principal_id/appRoleAssignments" \
    --query "value[?resourceId=='$graph_principal_id' && appRoleId=='$role_id'].id | [0]" \
    --output tsv)

  if [[ -n "$assignment_id" ]]; then
    printf 'Microsoft Graph role already assigned: %s\n' "$role_name"
    return
  fi

  body=$(printf '{"principalId":"%s","resourceId":"%s","appRoleId":"%s"}' \
    "$principal_id" "$graph_principal_id" "$role_id")
  az rest \
    --method post \
    --url "https://graph.microsoft.com/v1.0/servicePrincipals/$principal_id/appRoleAssignments" \
    --headers Content-Type=application/json \
    --body "$body" \
    --output none
  printf 'Assigned Microsoft Graph role: %s\n' "$role_name"
}

assign_graph_roles() {
  local principal_id=$1
  local graph_principal_id
  graph_principal_id=$(graph_service_principal_id)

  assign_graph_role "$principal_id" "$graph_principal_id" \
    "dd98c7f5-2d42-42d3-a0e4-633161547251" "ThreatHunting.Read.All"
  assign_graph_role "$principal_id" "$graph_principal_id" \
    "1138cb37-bd11-4084-a2b7-9f71582aeddb" "Device.ReadWrite.All"
}

remove_graph_roles() {
  local principal_id=$1
  local graph_principal_id assignment_id
  graph_principal_id=$(graph_service_principal_id)

  while IFS= read -r assignment_id; do
    [[ -n "$assignment_id" ]] || continue
    az rest \
      --method delete \
      --url "https://graph.microsoft.com/v1.0/servicePrincipals/$principal_id/appRoleAssignments/$assignment_id" \
      --output none
  done < <(az rest \
    --method get \
    --url "https://graph.microsoft.com/v1.0/servicePrincipals/$principal_id/appRoleAssignments" \
    --query "value[?resourceId=='$graph_principal_id' && (appRoleId=='dd98c7f5-2d42-42d3-a0e4-633161547251' || appRoleId=='1138cb37-bd11-4084-a2b7-9f71582aeddb')].id" \
    --output tsv)
}

ensure_azure_auth

export ARM_SUBSCRIPTION_ID="$AZURE_SUBSCRIPTION_ID"
export ARM_TENANT_ID="$AZURE_TENANT_ID"

case "$ACTION" in
  plan|apply)
    confirm_storage_access
    terraform -chdir="$TERRAFORM_ROOT" init -input=false
    terraform -chdir="$TERRAFORM_ROOT" fmt -check
    terraform -chdir="$TERRAFORM_ROOT" validate
    terraform -chdir="$TERRAFORM_ROOT" plan -input=false -out=tfplan

    if [[ "$ACTION" == "apply" ]]; then
      terraform -chdir="$TERRAFORM_ROOT" apply -input=false tfplan
      resource_group=$(terraform -chdir="$TERRAFORM_ROOT" output -raw resource_group_name)
      function_app=$(terraform -chdir="$TERRAFORM_ROOT" output -raw function_app_name)
      package_path="$TERRAFORM_ROOT/function-app.zip"
      principal_id=$(terraform -chdir="$TERRAFORM_ROOT" output -raw managed_identity_principal_id)
      prepare_flex_deployment "$resource_group" "$function_app"
      build_function_package "$package_path"
      deploy_function_package "$resource_group" "$function_app" "$package_path"
      assign_graph_roles "$principal_id"
      printf '\nFunction App deployment complete.\n'
      printf 'API role assignments can take several minutes to become active.\n'
      printf 'Check deployment with: %s status\n' "$0"
    else
      printf '\nPlan only; no Azure resources were changed.\n'
      printf 'Review with: terraform -chdir=azure-function/terraform show tfplan\n'
    fi
    ;;
  status)
    if ! terraform_has_resources; then
      printf 'No Terraform-managed Azure Function resources exist.\n'
      exit 0
    fi

    terraform -chdir="$TERRAFORM_ROOT" output
    resource_group=$(terraform -chdir="$TERRAFORM_ROOT" output -raw resource_group_name)
    function_app=$(terraform -chdir="$TERRAFORM_ROOT" output -raw function_app_name)

    printf '\nFunction App status:\n'
    az functionapp show \
      --resource-group "$resource_group" \
      --name "$function_app" \
      --query '{Name:name,State:state,Host:defaultHostName,Runtime:siteConfig.linuxFxVersion,Identity:identity.principalId}' \
      --output table

    printf '\nDiscovered functions:\n'
    az functionapp function list \
      --resource-group "$resource_group" \
      --name "$function_app" \
      --query '[].{Name:name,Trigger:config.bindings[0].type}' \
      --output table
    ;;
  destroy)
    if ! terraform_has_resources; then
      printf 'No Terraform-managed Azure Function resources exist.\n'
      rm -f "$TERRAFORM_ROOT/tfplan"
      exit 0
    fi

    principal_id=$(terraform -chdir="$TERRAFORM_ROOT" output -raw managed_identity_principal_id 2>/dev/null || true)
    if [[ -n "$principal_id" ]]; then
      remove_graph_roles "$principal_id"
    fi
    terraform -chdir="$TERRAFORM_ROOT" destroy -auto-approve -input=false
    rm -f "$TERRAFORM_ROOT/tfplan" "$TERRAFORM_ROOT/function-app.zip"
    printf '\nAzure Function App resources and managed identity permissions are removed.\n'
    ;;
esac