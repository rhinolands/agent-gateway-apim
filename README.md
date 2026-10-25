# Agent Gateway on Azure API Management (MCP enforcement)

Working reference implementation of the **agent gateway / A2A boundary** pattern on Azure API Management. It is the enforcement point that authenticates agent calls, authorizes them to least privilege, mediates tool (MCP) egress, and fails closed.

Methodology + rationale: **[agent-gateway-a2a](https://github.com/rhinolands/agent-gateway-a2a)**. This repo is the *how*.

## Architecture

![Request flow: an AI agent gets an app-only token from Microsoft Entra ID, calls Azure APIM with a Bearer JWT. APIM runs a fail-closed policy pipeline (validate-jwt, authorize role, rate-limit, managed-identity auth), then forwards to the MCP/A2A backend, pulling secrets from Key Vault and auditing every allow or deny to Log Analytics.](docs/architecture.svg)

The agent authenticates as an **app-only identity** to Entra ID, then calls APIM with a Bearer JWT. APIM runs a **fail-closed policy pipeline** before any call reaches the backend: `validate-jwt` → `Agent.Invoke` authorization → per-agent rate-limit → managed-identity backend auth. Secrets are pulled from Key Vault by the APIM managed identity. Every allow and deny lands in the APIM resource logs in Log Analytics.

> **What was checked.** `terraform fmt` and `validate` are clean. CI runs fmt/validate, tfsec and gitleaks on every push. One manual `terraform apply` on BasicV2 stood up the stack (APIM, Key Vault, Log Analytics, App Insights, the policy and named values). It was then torn down. CI does not deploy, so changes after that run are checked by validate only.

## What enforces what

| File | Role |
|---|---|
| [`policies/agent-gateway.xml`](policies/agent-gateway.xml) | The enforcement: `validate-jwt` (authN) → required `Agent.Invoke` role (authZ) → per-agent rate-limit by app id → scoped backend auth via managed identity → correlation id → fail-closed `on-error` |
| [`infra/`](infra/) (Terraform + **Azure Verified Modules**) | APIM, Key Vault (RBAC), Log Analytics via AVM modules. System-assigned MI. Least-privilege role assignment. Config named-values. Log Analytics diagnostics. App Insights resource (not yet attached to APIM). |
| [`identity/app-registration.md`](identity/app-registration.md) | Entra setup: app-only agent identities, the `Agent.Invoke` app role, scoped backend access via the APIM MI, no impersonation |

## Best practices baked in

- **No secrets in code or state.** Config via named-values. Real secrets via **Key Vault** referenced by the APIM **managed identity** (pattern shown commented in `main.tf`). Inputs via `TF_VAR_*` env vars or `terraform.tfvars`. Both are gitignored. Only examples are committed.
- **Managed identity, not stored credentials.** APIM authenticates to the backend and Key Vault as itself.
- **Least privilege.** The APIM identity gets only `Key Vault Secrets User`, scoped to the one vault. Agents get only `Agent.Invoke`.
- **App-only, no impersonation.** Agents never inherit a user's reach.
- **Fail closed + audit.** A missing token, role or app id is denied. APIM resource logs and metrics go to Log Analytics. Each request carries a correlation id header.
- **App Insights is created but not attached.** It sits on the same workspace. No APIM logger points at it yet.

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
# client-credentials. The gateway validates audience + issuer + Agent.Invoke role
curl -X POST "https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/token" \
  -d "grant_type=client_credentials&client_id=$AGENT_APP_ID&client_secret=$AGENT_SECRET&scope=$API_AUDIENCE/.default"
# call through the gateway
curl "$APIM_GATEWAY_URL/agents/..." -H "Authorization: Bearer $TOKEN"
```

## SKU / tier
`sku_name` is a variable (default **`BasicV2_1`**). Two patterns, two tier requirements:
- **Policy gateway** (this repo's enforcement, APIM *in front of* an MCP backend): works on **any** tier, incl. `Consumption_0`.
- **APIM native MCP Servers** (APIM *hosts/exposes* MCP servers): supported on **all tiers except Consumption**. Use `BasicV2`/`StandardV2`/`Premium`. Default `BasicV2_1` covers both. Bump to `StandardV2`/`Premium` for production scale + the full AI-gateway policy set.

## Notes / hardening for production
- Tighten Key Vault + APIM to **Private Endpoints** (the sample uses public networking for clarity).
- Prefer **certificates** over client secrets. Rotate them. Keep secrets only in Key Vault.
- Add a per-agent **peer allowlist** for A2A and a **tool allowlist** as named-values or an external policy decision point (OPA-style) for richer authZ.

## Validation

Statically validated (`fmt` + `validate`) and CI-gated (fmt/validate + tfsec + gitleaks). One manual `terraform apply` on Azure (BasicV2) stood up the stack before it was torn down. CI does not repeat that run.

End-to-end test: a client call reaches the backend MCP *through* the gateway, authenticated by a policy-injected scoped credential:
```text
$ curl -i -H "Accept: text/event-stream" https://<your-apim>.azure-api.net/rhino/sse
HTTP/1.1 400 Bad Request
{"jsonrpc":"2.0","error":{"code":-32000,"message":"Bad Request: Server not initialized"}}
```
The `400`/`406` JSON-RPC responses are the *backend MCP server* answering. The gateway authenticated and proxied the request through. A full tools list needs a real MCP client to complete the `initialize` handshake. (Note: in the preview MCP-Servers policy scope, instance named-values didn't resolve yet. The scoped credential was injected inline for the test. Use Key Vault / named-values in production, as `main.tf` shows.)

## License
MIT. See [LICENSE](LICENSE). By **Gustavo Norymberg**, Cloud & DevOps Architect.
