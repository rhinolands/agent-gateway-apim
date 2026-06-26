# Identity provider setup — Entra ID (app-only, least privilege)

The gateway authenticates **app identities**, never users. Each agent is its own app
registration with a client credential; it is granted exactly one app role on the gateway.
**No delegated permissions, no user impersonation, no on-behalf-of.**

Three identities, three jobs:
1. **Gateway API app** — exposes the `Agent.Invoke` app role; its App ID URI is the JWT **audience**.
2. **Agent app(s)** — one app registration per agent (app-only / client-credentials). Granted `Agent.Invoke`.
3. **APIM system-assigned managed identity** — provisioned by Bicep; gets a scoped role on the **backend** (so the agent never holds a backend secret) and `Key Vault Secrets User`.

> Names/IDs below are placeholders. Use your own; put nothing real in this repo.

## 1) Gateway API app — expose the app role
```bash
# Create the app that represents the gateway API
az ad app create --display-name "agent-gateway-api" \
  --identifier-uris "api://agent-gateway"        # => this is your apiAudience

APP_ID=$(az ad app list --display-name "agent-gateway-api" --query "[0].appId" -o tsv)

# Define an APP role 'Agent.Invoke' (allowedMemberTypes = Application => app-only, not users)
# Edit the app manifest / use Graph to add:
#   appRoles: [{ value: "Agent.Invoke", allowedMemberTypes: ["Application"],
#                displayName: "Invoke agents", description: "App may call the gateway", isEnabled: true }]
az ad sp create --id "$APP_ID"   # create the service principal (enterprise app)
```

## 2) Agent app — app-only, granted least privilege
```bash
# One registration per agent
az ad app create --display-name "agent-alpha"
AGENT_ID=$(az ad app list --display-name "agent-alpha" --query "[0].appId" -o tsv)
az ad sp create --id "$AGENT_ID"

# Client credential — prefer a certificate; if a secret, store it in Key Vault, never in code/CI plaintext
az ad app credential reset --id "$AGENT_ID" --display-name "rotated-$(date +%Y%m)"   # rotate on a schedule

# Grant the agent the Agent.Invoke APP role on the gateway (application permission), then admin-consent
az ad app permission add --id "$AGENT_ID" --api "$APP_ID" \
  --api-permissions "<Agent.Invoke-role-guid>=Role"
az ad app permission admin-consent --id "$AGENT_ID"
```
The agent now requests a token with `scope = api://agent-gateway/.default` (client-credentials).
The gateway's `validate-jwt` checks audience + issuer + the `Agent.Invoke` role. Anything else → 401/403.

## 3) Backend access via APIM managed identity (not the agent)
The APIM managed identity (from Bicep) is granted a **scoped** role on the backend resource —
e.g. on a single Storage container, one Key Vault, or `Mail.Read` constrained to one mailbox via an
**application access policy**. The agent never receives backend scopes. Example (one mailbox):
```bash
# Application access policy limiting Mail.Read to a single mailbox (no other mailbox reachable)
New-ApplicationAccessPolicy -AppId <apim-mi-appid> -PolicyScopeGroupId <mailbox-security-group> \
  -AccessRight RestrictAccess -Description "Gateway MI: only this mailbox"
```

## Least-privilege checklist
- App-only everywhere. **No** delegated scopes, **no** `*.ReadWrite` where read suffices, **no** `Send` unless required.
- One app role per agent; reach changes via role assignment, not new secrets.
- Certificates over secrets; rotate; secrets only in Key Vault.
- Backend reach belongs to the APIM managed identity, scoped to the single resource it needs.
- Admin-consent is explicit and reviewed.
