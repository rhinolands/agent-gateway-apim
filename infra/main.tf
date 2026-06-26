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

data "azurerm_client_config" "current" {}

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

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
}

resource "azurerm_log_analytics_workspace" "this" {
  name                = "${var.name_prefix}-law-${local.suffix}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_application_insights" "this" {
  name                = "${var.name_prefix}-ai-${local.suffix}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  workspace_id        = azurerm_log_analytics_workspace.this.id
  application_type    = "web"
}

# Key Vault in RBAC mode — identity-based least privilege, no access policies.
resource "azurerm_key_vault" "this" {
  name                       = local.kv_name
  location                   = azurerm_resource_group.this.location
  resource_group_name        = azurerm_resource_group.this.name
  tenant_id                  = var.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  soft_delete_retention_days = 7
  # Tighten to a Private Endpoint in production.
}

# APIM with a system-assigned managed identity — no client secrets anywhere.
resource "azurerm_api_management" "this" {
  name                = local.apim_name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  publisher_name      = var.publisher_name
  publisher_email     = var.publisher_email
  sku_name            = "Consumption_0"

  identity {
    type = "SystemAssigned"
  }
}

# Least privilege: ONLY Key Vault Secrets User, scoped to this vault, for the APIM identity.
resource "azurerm_role_assignment" "apim_kv_secrets" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_api_management.this.identity[0].principal_id
}

# Config named-values referenced by the policy. Non-secret.
resource "azurerm_api_management_named_value" "config" {
  for_each            = local.config
  name                = each.key
  display_name        = each.key
  resource_group_name = azurerm_resource_group.this.name
  api_management_name = azurerm_api_management.this.name
  value               = each.value
  secret              = false
}

# Pattern for a REAL secret: a named-value sourced from Key Vault via the APIM managed identity.
# Put the secret in Key Vault, never inline. Depends on the role assignment above.
# resource "azurerm_api_management_named_value" "signing_secret" {
#   name                = "signing-secret"
#   display_name        = "signing-secret"
#   resource_group_name = azurerm_resource_group.this.name
#   api_management_name = azurerm_api_management.this.name
#   secret              = true
#   value_from_key_vault {
#     secret_id = "${azurerm_key_vault.this.vault_uri}secrets/signing-secret"
#   }
#   depends_on = [azurerm_role_assignment.apim_kv_secrets]
# }

resource "azurerm_api_management_api" "gateway" {
  name                  = "agent-gateway"
  resource_group_name   = azurerm_resource_group.this.name
  api_management_name   = azurerm_api_management.this.name
  revision              = "1"
  display_name          = "Agent Gateway (MCP)"
  path                  = "agents"
  protocols             = ["https"]
  subscription_required = false # authN is the JWT, not an APIM key
}

# Apply the enforcement policy from the policies file (single source of truth).
resource "azurerm_api_management_api_policy" "gateway" {
  api_name            = azurerm_api_management_api.gateway.name
  resource_group_name = azurerm_resource_group.this.name
  api_management_name = azurerm_api_management.this.name
  xml_content         = file("${path.module}/../policies/agent-gateway.xml")
  depends_on          = [azurerm_api_management_named_value.config]
}

# Audit trail: APIM logs/metrics to Log Analytics.
resource "azurerm_monitor_diagnostic_setting" "apim" {
  name                       = "apim-to-law"
  target_resource_id         = azurerm_api_management.this.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category_group = "allLogs"
  }
  enabled_metric {
    category = "AllMetrics"
  }
}
