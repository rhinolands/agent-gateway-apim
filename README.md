# Agent Gateway on Azure API Management (MCP enforcement)

Working reference implementation of the **agent gateway / A2A boundary** pattern on Azure API Management — the enforcement point that authenticates agent calls, authorizes them to least privilege, mediates tool (MCP) egress, and fails closed.

Methodology + rationale: **[agent-gateway-a2a](https://github.com/rhinolands/agent-gateway-a2a)**. This repo is the *how*.

> **Status: private / pre-validation.** Deploy-tested before it goes public — infra code that doesn't deploy is worse than none.

## What enforces what

| File | Role |
|---|---|
| [`policies/agent-gateway.xml`](policies/agent-gateway.xml) | The enforcement: `validate-jwt` (authN) → required `Agent.Invoke` role (authZ) → per-agent rate-limit by app id → scoped backend auth via managed identity → correlation id → fail-closed `on-error` |
| [`infra/`](infra/) (Terraform) | APIM (system-assigned MI), Key Vault (RBAC), least-privilege role assignment, config named-values, App Insights diagnostics |
| [`identity/app-registration.md`](identity/app-registration.md) | Entra setup — app-only agent identities, the `Agent.Invoke` app role, scoped backend access via the APIM MI, no impersonation |

## Best practices baked in

- **No secrets in code or state.** Config via named-values; real secrets via **Key Vault** referenced by the APIM **managed identity** (pattern shown commented in `main.tf`). Inputs via `TF_VAR_*` env vars or `terraform.tfvars` — both gitignored, examples only.
- **Managed identity, not stored credentials** — APIM authenticates to the backend and Key Vault as itself.
- **Least privilege** — APIM identity gets only `Key Vault Secrets User`, scoped to the one vault; agents get only `Agent.Invoke`.
- **App-only, no impersonation** — agents never inherit a user's reach.
- **Fail closed + audit** — denials on any gap; logs/metrics to App Insights with a correlation id.

## Deploy

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars   # fill in your values (gitignored)
# or: set -a; source ../.env; set +a            # TF_VAR_* env vars instead

az login                      # azurerm uses your Azure CLI / env credentials
terraform init
terraform plan
terraform apply
```
Then set up identities per [`identity/app-registration.md`](identity/app-registration.md), and acquire an agent token:
```bash
# client-credentials; the gateway validates audience + issuer + Agent.Invoke role
curl -X POST "https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/token" \
  -d "grant_type=client_credentials&client_id=$AGENT_APP_ID&client_secret=$AGENT_SECRET&scope=$API_AUDIENCE/.default"
# call through the gateway
curl "$APIM_GATEWAY_URL/agents/..." -H "Authorization: Bearer $TOKEN"
```

## Notes / hardening for production
- Tighten Key Vault + APIM to **Private Endpoints** (the sample uses public networking for clarity).
- Prefer **certificates** over client secrets; rotate; secrets only in Key Vault.
- Add a per-agent **peer allowlist** for A2A and a **tool allowlist** as named-values or an external policy decision point (OPA-style) for richer authZ.

## License
MIT — see [LICENSE](LICENSE). By **Gustavo Norymberg** — Cloud & DevOps Architect.
