# MCP Azure Server – documentation

This addon gives Open WebUI (or any MCP client) access to **Azure** and **Azure DevOps** through Microsoft's official MCP servers:

- **Azure MCP Server** (`@azure/mcp` 3.0.0) on `http://localhost:3005/azure/mcp`
- **Azure DevOps MCP Server** (`@azure-devops/mcp` 2.11.0) for the organization set in `devops_organization` on `http://localhost:3005/devops/mcp`

Both act as **you**: they use the Azure CLI login (`az login`) of your own account. No service principal, client secret or PAT is involved.

## 1. Configure

On the addon's **Configuration** tab:

1. Set `api_key` to a long random string, for example the output of `openssl rand -hex 32`. The addon won't start without it.
2. Set `devops_organization` to your Azure DevOps organization (the `<org>` in `https://dev.azure.com/<org>`). Leave it empty to disable the Azure DevOps server.
3. Optional: set `tenant` to your Entra tenant ID if your account has access to more than one tenant.
4. Leave `read_only` on `true` unless you really need write access (see Security below).

## 2. First start: sign in with a device code

The Home Assistant host has no browser, so the addon uses the device-code flow:

1. Start the addon and open its **Log** tab.
2. You'll see a line like:
   ```
   To sign in, use a web browser to open the page https://microsoft.com/devicelogin and enter the code ABCD-EFGH to authenticate.
   ```
3. On any device, go to <https://microsoft.com/devicelogin>, enter the code and sign in with your work account. Complete MFA if asked.
4. The log then shows `Logged in to Azure as <you> (tenant ...)`, followed by `[azure] Ready, N tools` and `[devops] Ready, N tools`.

If you don't complete the login within about 15 minutes, the code expires. The addon logs this and shows a new code after 30 seconds. It keeps retrying and won't crash-loop.

The token cache is stored in `/data/.azure` (addon-private storage). It survives addon restarts and updates, and it is included in Home Assistant backups of this addon. Treat those backups as sensitive.

## 3. Add the tool servers in Open WebUI

This addon uses `host_network: true`, like the other addons in this repository, so Open WebUI reaches it on `localhost`.

In Open WebUI go to **Admin Panel → Settings → External Tools** (older versions: **Settings → Tools**) → **+ Add Connection**, and add **two** connections:

| Field | Azure | Azure DevOps |
|-------|-------|--------------|
| **Type** | `MCP (Streamable HTTP)` | `MCP (Streamable HTTP)` |
| **URL** | `http://localhost:3005/azure/mcp` | `http://localhost:3005/devops/mcp` |
| **Auth** | `Bearer`, key = your `api_key` | `Bearer`, key = your `api_key` |
| **Function Name Filter List** | `,` | `,` |

Notes:
- The bearer key must be filled in. With an empty bearer, Open WebUI's "Verify connection" can still succeed, but tool calls will fail with 401.
- An empty Function Name Filter List exposes **no** tools in Open WebUI. A single `,` exposes all of them (see the root README).

Then, for the model(s) you want to use with these tools: **Workspace → Models → edit → Advanced Params → Function Calling → `Native`**. Enable the two tool servers for the model or in the chat.

Try: *"List my Azure subscriptions"* or *"Show my open work items in project MyProject"*.

## 4. When the login expires

Azure refresh tokens normally stay valid for a long time (rolling up to 90 days), but your organisation's Conditional Access policies, a password change or a revoked session can end the login sooner. Tool calls then fail with authentication errors.

To sign in again, **restart the addon** and follow step 2. If no valid token is found at startup, a new device code appears in the log.

To sign out completely or switch accounts, stop the addon, uninstall and reinstall it (this wipes `/data`). Alternatively, set a different `tenant` and restart.

## 5. Security

- **Read-only by default.** With `read_only: true`, the Azure MCP Server runs with `--read-only`, and the Azure DevOps server only exposes tools that Microsoft annotates as read-only (`readOnlyHint: true`). Some "read-only" tools can still return sensitive data, such as repository contents and pipeline logs.
- **It acts as you.** Every call runs with **all** permissions of the signed-in account in Azure and Azure DevOps. If you set `read_only: false`, the model can create, change and delete resources, work items, branches, pipelines, and so on, wherever *you* can.
- **Never expose port 3005 to the internet.** With `host_network` the port is reachable from your LAN, and the `api_key` is the only thing protecting it. Don't forward it on your router or publish it through a reverse proxy or tunnel. Use a long random `api_key`, and change it if it ever leaks.
- Anyone who can open the addon's Log tab during a login can see the device code. The code is only useful for a few minutes, and only to someone who can also sign in as you.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `ERROR: the 'api_key' option is empty` | Set `api_key` and start again. |
| Tools return "not available right now" | The upstream is starting, restarting or waiting for login. Check the log. |
| Azure DevOps tools fail with 401/403 | Make sure your account has access to `https://dev.azure.com/<organization>`. If you have several tenants, set `tenant`. |
| No tools visible in Open WebUI | Set the Function Name Filter List to `,`, check the bearer key, and set Function Calling to Native. |
