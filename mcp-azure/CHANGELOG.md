# Changelog

## 1.0.1

- Fix the build: `@azure-devops/mcp` 2.11.1 was never published (only nightlies), so `npm install` failed. Pin the latest stable release, 2.11.0.
- Fix startup: install `libicu72`. Without it the Azure MCP Server (`azmcp server start`) aborted with "Couldn't find a valid ICU package".

## 1.0.0

- Initial release.
- Azure MCP Server `@azure/mcp` 3.0.0 (`azmcp server start`, Azure CLI credential, `--read-only` by default).
- Azure DevOps MCP Server `@azure-devops/mcp` 2.11.1 (`--authentication azcli`, read-only tool filtering by default).
- Azure CLI 2.93.0 with the `azure-devops` extension; device-code login with persistent token cache in `/data/.azure`.
- Streamable HTTP endpoints `/azure/mcp` and `/devops/mcp` on port 3005, protected by `api_key`.
