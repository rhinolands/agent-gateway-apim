output "apim_gateway_url" {
  description = "Base URL of the agent gateway"
  value       = module.apim.apim_gateway_url
}

output "key_vault_name" {
  description = "Key Vault holding gateway secrets (RBAC mode)"
  value       = module.kv.name
}

output "apim_principal_id" {
  description = "APIM managed-identity principal id — grant it scoped backend access"
  value       = module.apim.resource.identity[0].principal_id
  sensitive   = true
}
