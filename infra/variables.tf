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
