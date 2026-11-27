# MCP Azure Server

Home Assistant addon exposing Microsoft's **Azure MCP Server** and **Azure DevOps MCP Server** via Streamable HTTP MCP, authenticated as **your own account** through `az login` (device code). No service principal or client secret. Azure DevOps can optionally use a personal access token (PAT) instead of `az login`, for example when Conditional Access blocks the device-code login.

See [DOCS.md](./DOCS.md) for the full setup guide (first login, Open WebUI configuration, security).

## What it does

The image contains the Azure CLI (+ `azure-devops` extension), Node.js and two pinned upstream MCP servers:

| Upstream | Version | Started as | Endpoint |
|----------|---------|-----------|----------|
| [`@azure/mcp`](https://github.com/microsoft/mcp/tree/main/servers/Azure.Mcp.Server) | 3.0.0 | `azmcp server start [--read-only]` with `AZURE_TOKEN_CREDENTIALS=AzureCliCredential` | `/azure/mcp` |
| [`@azure-devops/mcp`](https://github.com/microsoft/azure-devops-mcp) | 2.11.0 | `mcp-server-azuredevops <org> --authentication azcli [--tenant <id>]`, or `--authentication pat` when `devops_pat` is set | `/devops/mcp` |

Both run as stdio subprocesses behind a small in-process Node.js proxy (same pattern as `mcp-filesystem`) that serves them over **MCP Streamable HTTP**. No `supergateway` and no `npx` downloads at runtime. The proxy advertises only the `tools` capability and never calls `roots/list` on the client. It restarts an upstream automatically if the process exits.

On startup `run.sh` checks `az account get-access-token`, unless nothing needs `az` (`azure_enabled: false` and either no DevOps organization or a `devops_pat`). If there's no valid session it runs `az login --use-device-code --allow-no-subscriptions` in a retry loop, and the device code shows up in the addon log. The token cache lives in `/data/.azure`, so it survives restarts and updates.

## Configuration

| Option | Default | Description |
|--------|---------|-------------|
| `port` | `3005` | HTTP port for the MCP server |
| `api_key` | `""` (**required**) | Bearer token clients must send (`Authorization: Bearer <api_key>`) |
| `azure_enabled` | `true` | Start the Azure MCP Server (needs `az login`). Turn off to run only Azure DevOps |
| `devops_organization` | `""` | Azure DevOps organization. Empty disables the DevOps server |
| `devops_pat` | *(unset)* | Optional Azure DevOps personal access token. When set, the DevOps server uses it instead of `az login` |
| `devops_projects` | `[]` | Hint for the model about which projects to use by default |
| `tenant` | *(unset)* | Optional Entra tenant ID for `az login` / DevOps auth via `az login` |
| `read_only` | `true` | Azure: `--read-only`. DevOps: only tools annotated `readOnlyHint: true` are exposed |
| `max_result_chars` | *(unset = 100000)* | Largest tool result passed to the client, in characters (minimum 1000). Longer results are cut off with a note to the model |

## Open WebUI connection

```
http://localhost:3005/azure/mcp    # Azure
http://localhost:3005/devops/mcp   # Azure DevOps
```

Type **MCP (Streamable HTTP)**, Auth **Bearer** = your `api_key`.
