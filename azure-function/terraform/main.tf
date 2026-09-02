terraform {
  required_version = ">= 1.7.0"

  required_providers {
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}

provider "azurerm" {
  features {}

  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
}

variable "subscription_id" {
  type        = string
  description = "Azure subscription ID"
}

variable "tenant_id" {
  type        = string
  description = "Microsoft Entra tenant ID"
}

variable "location" {
  type        = string
  description = "Azure region for the Function App"
  default     = "westus2"
}

variable "resource_prefix" {
  type        = string
  description = "Short name used for Azure resources"
  default     = "mde-tag-sync"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,18}$", var.resource_prefix))
    error_message = "resource_prefix must contain 3-18 lowercase letters, numbers, or hyphens."
  }
}

variable "sync_schedule" {
  type        = string
  description = "NCRONTAB schedule for the MDE tag synchronization timer"
  default     = "0 */30 * * * *"

  validation {
    condition     = trimspace(var.sync_schedule) != ""
    error_message = "sync_schedule cannot be empty."
  }
}

variable "allowed_device_tags" {
  type        = list(string)
  description = "Exact MDE RegistryDeviceTag values that the Function may copy to Entra"

  validation {
    condition = (
      length(var.allowed_device_tags) > 0 &&
      alltrue([for tag in var.allowed_device_tags : trimspace(tag) != ""])
    )
    error_message = "allowed_device_tags must contain at least one non-empty tag."
  }
}

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

locals {
  suffix               = random_string.suffix.result
  resource_group_name  = "rg-${var.resource_prefix}-${local.suffix}"
  function_app_name    = "func-${var.resource_prefix}-${local.suffix}"
  service_plan_name    = "plan-${var.resource_prefix}-${local.suffix}"
  insights_name        = "appi-${var.resource_prefix}-${local.suffix}"
  log_workspace_name   = "log-${var.resource_prefix}-${local.suffix}"
  storage_account_name = substr(replace("st${var.resource_prefix}${local.suffix}", "-", ""), 0, 24)
}

data "archive_file" "function" {
  type        = "zip"
  output_path = "${path.module}/function-app.zip"

  source {
    content  = file("${path.module}/../function_app.py")
    filename = "function_app.py"
  }

  source {
    content  = file("${path.module}/../host.json")
    filename = "host.json"
  }

  source {
    content  = file("${path.module}/../requirements.txt")
    filename = "requirements.txt"
  }
}

resource "azurerm_resource_group" "function" {
  name     = local.resource_group_name
  location = var.location
}

resource "azurerm_storage_account" "function" {
  name                     = local.storage_account_name
  resource_group_name      = azurerm_resource_group.function.name
  location                 = azurerm_resource_group.function.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"

  allow_nested_items_to_be_public = false
  public_network_access_enabled   = true
  shared_access_key_enabled       = true
}

resource "azurerm_storage_container" "function_deployment" {
  name                  = "function-releases"
  storage_account_id    = azurerm_storage_account.function.id
  container_access_type = "private"
}

resource "azurerm_log_analytics_workspace" "function" {
  name                = local.log_workspace_name
  resource_group_name = azurerm_resource_group.function.name
  location            = azurerm_resource_group.function.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_application_insights" "function" {
  name                = local.insights_name
  resource_group_name = azurerm_resource_group.function.name
  location            = azurerm_resource_group.function.location
  workspace_id        = azurerm_log_analytics_workspace.function.id
  application_type    = "web"
}

resource "azurerm_service_plan" "function" {
  name                = local.service_plan_name
  resource_group_name = azurerm_resource_group.function.name
  location            = azurerm_resource_group.function.location
  os_type             = "Linux"
  sku_name            = "FC1"
}

resource "azurerm_function_app_flex_consumption" "tag_sync" {
  name                = local.function_app_name
  resource_group_name = azurerm_resource_group.function.name
  location            = azurerm_resource_group.function.location
  service_plan_id     = azurerm_service_plan.function.id

  storage_container_type      = "blobContainer"
  storage_container_endpoint  = "${azurerm_storage_account.function.primary_blob_endpoint}${azurerm_storage_container.function_deployment.name}"
  storage_authentication_type = "StorageAccountConnectionString"
  storage_access_key          = azurerm_storage_account.function.primary_access_key
  runtime_name                = "python"
  runtime_version             = "3.12"
  maximum_instance_count      = 10
  instance_memory_in_mb       = 2048

  https_only = true

  webdeploy_publish_basic_authentication_enabled = true

  identity {
    type = "SystemAssigned"
  }

  app_settings = {
    PYTHON_ISOLATE_WORKER_DEPENDENCIES = "1"
    MDE_TAG_SYNC_SCHEDULE              = var.sync_schedule
    MDE_ALLOWED_DEVICE_TAGS            = join(",", var.allowed_device_tags)
  }

  site_config {
    application_insights_connection_string = azurerm_application_insights.function.connection_string
    application_insights_key               = azurerm_application_insights.function.instrumentation_key
    minimum_tls_version                    = "1.2"
    scm_minimum_tls_version                = "1.2"
  }
}

output "resource_group_name" {
  value = azurerm_resource_group.function.name
}

output "function_app_name" {
  value = azurerm_function_app_flex_consumption.tag_sync.name
}

output "function_hostname" {
  value = azurerm_function_app_flex_consumption.tag_sync.default_hostname
}

output "managed_identity_principal_id" {
  value = azurerm_function_app_flex_consumption.tag_sync.identity[0].principal_id
}

output "application_insights_name" {
  value = azurerm_application_insights.function.name
}

output "function_package_path" {
  value = abspath(data.archive_file.function.output_path)
}