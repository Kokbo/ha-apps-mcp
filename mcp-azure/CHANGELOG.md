# Changelog

## 1.1.0

- New option `devops_pat`: the Azure DevOps MCP Server can use a personal access token instead of `az login` (`--authentication pat`). Useful when Conditional Access blocks the device-code login but your organisation allows PATs.
- New option `azure_enabled` (default `true`): turn it off to run only the Azure DevOps server. With `azure_enabled: false` and a `devops_pat`, the addon skips `az login` entirely.

## 1.0.1

- Fix the build: `@azure-devops/mcp` 2.11.1 was never published (only nightlies), so `npm install` failed. Pin the latest stable release, 2.11.0.
- Fix startup: install `libicu72`. Without it the Azure MCP Server (`azmcp server start`) aborted with "Couldn't find a valid ICU package".

## 1.0.0

- Initial release.
- Azure MCP Server `@azure/mcp` 3.0.0 (`azmcp server start`, Azure CLI credential, `--read-only` by default).
- Azure DevOps MCP Server `@azure-devops/mcp` 2.11.1 (`--authentication azcli`, read-only tool filtering by default).
- Azure CLI 2.93.0 with the `azure-devops` extension; device-code login with persistent token cache in `/data/.azure`.
- Streamable HTTP endpoints `/azure/mcp` and `/devops/mcp` on port 3005, protected by `api_key`.
