# Changelog

## 1.1.1

- Restore the `mcp<2` pin that a dependency update had removed: `mcp` 2.x renamed `FastMCP`, so the addon failed at startup.

## 1.1.0

- **Breaking:** the MCP endpoint now requires a bearer token. Set the new `api_key` option (e.g. `openssl rand -hex 32`) and set **Auth** to `Bearer` with that key in Open WebUI. The addon refuses to start with an empty `api_key`.
- Pin the MCP Python SDK to `<2`: `mcp` 2.x renamed `FastMCP`, which made fresh installs fail at startup.
