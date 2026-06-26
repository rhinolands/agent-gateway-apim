output "apim_gateway_url" {
  description = "Base URL of the agent gateway"
  value       = azurerm_api_management.this.gateway_url
}

output "key_vault_name" {
  description = "Key Vault holding gateway secrets (RBAC mode)"
  value       = azurerm_key_vault.this.name
}

output "apim_principal_id" {
  description = "APIM managed-identity principal id — grant it scoped backend access"
  value       = azurerm_api_management.this.identity[0].principal_id
}
