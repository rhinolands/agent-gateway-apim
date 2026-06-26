variable "resource_group_name" {
  type        = string
  description = "Resource group to create the gateway in"
  default     = "rg-agent-gateway"
}

variable "location" {
  type        = string
  description = "Azure region"
  default     = "westeurope"
}

variable "name_prefix" {
  type        = string
  description = "Short prefix for resource names (lowercase, 3-11 chars)"
  validation {
    condition     = can(regex("^[a-z0-9]{3,11}$", var.name_prefix))
    error_message = "name_prefix must be 3-11 lowercase alphanumeric chars."
  }
}

variable "publisher_name" {
  type        = string
  description = "APIM publisher display name"
}

variable "publisher_email" {
  type        = string
  description = "APIM publisher email"
}

variable "tenant_id" {
  type        = string
  description = "Entra ID tenant GUID the gateway validates tokens against"
}

variable "api_audience" {
  type        = string
  description = "Audience (App ID URI / client id) the gateway expects in the JWT"
}

variable "mcp_backend_url" {
  type        = string
  description = "Base URL of the protected MCP backend"
}

variable "mcp_backend_resource" {
  type        = string
  description = "Resource (App ID URI) APIM requests a managed-identity token for, to call the backend"
}

variable "sku_name" {
  type        = string
  description = "APIM SKU. Use a non-Consumption tier (BasicV2/StandardV2/Premium) for native MCP Servers + AI-gateway features. Consumption_0 = policy gateway only (no native MCP Servers)."
  default     = "BasicV2_1"
  validation {
    condition     = can(regex("^Consumption_0$|^Basic_[12]$|^BasicV2_([1-9]|10)$|^Developer_1$|^Standard_[1-4]$|^StandardV2_([1-9]|10)$|^Premium_([1-9][0-9]?)$|^PremiumV2_([1-9]|[12][0-9]|30)$", var.sku_name))
    error_message = "Invalid APIM sku_name."
  }
}

variable "agent_rate_calls" {
  type        = number
  description = "Per-agent rate limit: calls per renewal period"
  default     = 60
}

variable "agent_rate_period" {
  type        = number
  description = "Per-agent rate limit: renewal period in seconds"
  default     = 60
}
