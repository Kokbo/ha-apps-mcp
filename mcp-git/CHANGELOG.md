# Changelog

## 1.1.1

- Dependency update: zod v4.

## 1.1.0

- **Breaking:** the MCP endpoint now requires a bearer token. Set the new `api_key` option (e.g. `openssl rand -hex 32`) and set **Auth** to `Bearer` with that key in Open WebUI. The addon refuses to start with an empty `api_key`.
