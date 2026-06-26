terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {}
}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

locals {
  suffix    = random_string.suffix.result
  apim_name = "${var.name_prefix}-apim-${local.suffix}"
  kv_name   = substr("${var.name_prefix}kv${local.suffix}", 0, 24)

  # Non-secret config consumed by the policy as named-values ({{...}}).
  config = {
    "tenant-id"            = var.tenant_id
    "api-audience"         = var.api_audience
    "mcp-backend-url"      = var.mcp_backend_url
    "mcp-backend-resource" = var.mcp_backend_resource
    "agent-rate-calls"     = tostring(var.agent_rate_calls)
    "agent-rate-period"    = tostring(var.agent_rate_period)
  }
}

# ---- Azure Verified Modules (AVM) ----

module "rg" {
  source           = "Azure/avm-res-resources-resourcegroup/azurerm"
  version          = "~> 0.2"
  name             = var.resource_group_name
  location         = var.location
  enable_telemetry = false
}

module "law" {
  source              = "Azure/avm-res-operationalinsights-workspace/azurerm"
  version             = "~> 0.4"
  name                = "${var.name_prefix}-law-${local.suffix}"
  location            = var.location
  resource_group_name = module.rg.name
  enable_telemetry    = false
}

# Key Vault (AVM) — RBAC by default. Grant the APIM identity least privilege here.
module "kv" {
  source              = "Azure/avm-res-keyvault-vault/azurerm"
  version             = "~> 0.9"
  name                = local.kv_name
  location            = var.location
  resource_group_name = module.rg.name
  tenant_id           = var.tenant_id
  enable_telemetry    = false

  role_assignments = {
    apim_secrets = {
      role_definition_id_or_name = "Key Vault Secrets User"
      principal_id               = module.apim.resource.identity[0].principal_id
    }
  }
}

# APIM (AVM) — system-assigned managed identity, no secrets.
module "apim" {
  source              = "Azure/avm-res-apimanagement-service/azurerm"
  version             = "~> 0.0.5"
  name                = local.apim_name
  location            = var.location
  resource_group_name = module.rg.name
  publisher_name      = var.publisher_name
  publisher_email     = var.publisher_email
  sku_name            = "Consumption_0"
  enable_telemetry    = false

  managed_identities = {
    system_assigned = true
  }
}

# ---- APIM sub-config (raw azurerm against the AVM module outputs) ----

resource "azurerm_application_insights" "this" {
  name                = "${var.name_prefix}-ai-${local.suffix}"
  location            = var.location
  resource_group_name = module.rg.name
  workspace_id        = module.law.resource_id
  application_type    = "web"
}

resource "azurerm_api_management_named_value" "config" {
  for_each            = local.config
  name                = each.key
  display_name        = each.key
  resource_group_name = module.rg.name
  api_management_name = module.apim.name
  value               = each.value
  secret              = false
}

resource "azurerm_api_management_api" "gateway" {
  name                  = "agent-gateway"
  resource_group_name   = module.rg.name
  api_management_name   = module.apim.name
  revision              = "1"
  display_name          = "Agent Gateway (MCP)"
  path                  = "agents"
  protocols             = ["https"]
  subscription_required = false # authN is the JWT, not an APIM key
}

resource "azurerm_api_management_api_policy" "gateway" {
  api_name            = azurerm_api_management_api.gateway.name
  resource_group_name = module.rg.name
  api_management_name = module.apim.name
  xml_content         = file("${path.module}/../policies/agent-gateway.xml")
  depends_on          = [azurerm_api_management_named_value.config]
}

resource "azurerm_monitor_diagnostic_setting" "apim" {
  name                       = "apim-to-law"
  target_resource_id         = module.apim.resource_id
  log_analytics_workspace_id = module.law.resource_id

  enabled_log {
    category_group = "allLogs"
  }
  enabled_metric {
    category = "AllMetrics"
  }
}
