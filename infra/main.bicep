// Agent Gateway on Azure API Management — MCP enforcement point.
// Best practices: system-assigned managed identity, Key Vault (RBAC) for secrets,
// least-privilege role assignments, named-values for config, no secrets in code/params,
// diagnostics to App Insights. Deploy: see README.

@description('Azure region')
param location string = resourceGroup().location

@description('Short prefix for resource names (lowercase, 3-11 chars)')
@minLength(3)
@maxLength(11)
param namePrefix string

@description('APIM publisher display name')
param publisherName string

@description('APIM publisher email')
param publisherEmail string

@description('Entra ID tenant GUID the gateway validates tokens against')
param tenantId string = subscription().tenantId

@description('Audience (App ID URI / client id) the gateway API expects in the JWT')
param apiAudience string

@description('Base URL of the protected MCP backend')
param mcpBackendUrl string

@description('Resource (App ID URI) the gateway requests a managed-identity token for, to call the backend')
param mcpBackendResource string

@description('Per-agent rate limit: calls per renewal period')
param agentRateCalls int = 60

@description('Per-agent rate limit: renewal period in seconds')
param agentRatePeriod int = 60

var suffix = uniqueString(resourceGroup().id)
var apimName = '${namePrefix}-apim-${suffix}'
var kvName = take('${namePrefix}kv${suffix}', 24)
// Built-in role: Key Vault Secrets User (least privilege — read secret values only)
var kvSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${namePrefix}-law-${suffix}'
  location: location
  properties: { sku: { name: 'PerGB2018' }, retentionInDays: 30 }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${namePrefix}-ai-${suffix}'
  location: location
  kind: 'web'
  properties: { Application_Type: 'web', WorkspaceResourceId: law.id }
}

// Key Vault in RBAC mode — no access policies, identity-based least privilege.
resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: kvName
  location: location
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    publicNetworkAccess: 'Enabled' // tighten to Private Endpoint in production
  }
}

// APIM with a system-assigned managed identity (no client secrets anywhere).
resource apim 'Microsoft.ApiManagement/service@2023-05-01-preview' = {
  name: apimName
  location: location
  sku: { name: 'Consumption', capacity: 0 }
  identity: { type: 'SystemAssigned' }
  properties: {
    publisherName: publisherName
    publisherEmail: publisherEmail
  }
}

// Least privilege: grant ONLY Key Vault Secrets User to the APIM identity, scoped to this vault.
resource kvRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(kv.id, apim.id, kvSecretsUserRoleId)
  scope: kv
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', kvSecretsUserRoleId)
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Config named-values referenced by the policy ({{...}}). Non-secret config.
var config = {
  'tenant-id': tenantId
  'api-audience': apiAudience
  'mcp-backend-url': mcpBackendUrl
  'mcp-backend-resource': mcpBackendResource
  'agent-rate-calls': string(agentRateCalls)
  'agent-rate-period': string(agentRatePeriod)
}
resource namedValues 'Microsoft.ApiManagement/service/namedValues@2023-05-01-preview' = [for item in items(config): {
  parent: apim
  name: item.key
  properties: { displayName: item.key, value: item.value, secret: false }
}]

// Pattern for a REAL secret: a named-value sourced from Key Vault via the APIM managed identity.
// Uncomment + put the secret in Key Vault; never inline it. Requires kvRbac above.
// resource secretNamedValue 'Microsoft.ApiManagement/service/namedValues@2023-05-01-preview' = {
//   parent: apim
//   name: 'signing-secret'
//   dependsOn: [ kvRbac ]
//   properties: {
//     displayName: 'signing-secret'
//     secret: true
//     keyVault: { secretIdentifier: '${kv.properties.vaultUri}secrets/signing-secret' }
//   }
// }

resource api 'Microsoft.ApiManagement/service/apis@2023-05-01-preview' = {
  parent: apim
  name: 'agent-gateway'
  properties: {
    displayName: 'Agent Gateway (MCP)'
    path: 'agents'
    protocols: [ 'https' ]
    subscriptionRequired: false // authN is the JWT, not an APIM key
  }
}

// Apply the enforcement policy (loaded from the policies file — single source of truth).
resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2023-05-01-preview' = {
  parent: api
  name: 'policy'
  dependsOn: [ namedValues ]
  properties: {
    format: 'rawxml'
    value: loadTextContent('../policies/agent-gateway.xml')
  }
}

// Ship APIM logs/metrics to App Insights for the audit trail.
resource apimDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'apim-to-law'
  scope: apim
  properties: {
    workspaceId: law.id
    logs: [ { categoryGroup: 'allLogs', enabled: true } ]
    metrics: [ { category: 'AllMetrics', enabled: true } ]
  }
}

output apimGatewayUrl string = apim.properties.gatewayUrl
output keyVaultName string = kv.name
output apimPrincipalId string = apim.identity.principalId
