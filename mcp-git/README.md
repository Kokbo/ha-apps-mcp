# MCP Git Server

Home Assistant addon exposing git operations on `/config` via a Streamable HTTP MCP server.

## What it does

Custom MCP server built with `simple-git` (Node.js) that exposes git operations on a local repository as MCP tools, served over **MCP Streamable HTTP** directly — no `supergateway`, no stdio bridge. The server uses `@modelcontextprotocol/sdk`'s native `StreamableHTTPServerTransport` mounted on an Express HTTP server at `/mcp`. It only advertises the `tools` server capability, so it never issues `roots/list` requests to the client.

**Available MCP tools:**

| Tool | Description |
|------|-------------|
| `git_status` | Show working tree status |
| `git_diff` | Show unstaged changes |
| `git_add` | Stage all changes (`git add -A`) |
| `git_commit(message)` | Commit staged changes |
| `git_push` | Push to remote via SSH |
| `git_log(n)` | Show last `n` commits (default 10) |

## Configuration

| Option | Default | Description |
|--------|---------|-------------|
| `port` | `3002` | HTTP port for the MCP server |
| `api_key` | `""` (**required**) | Bearer token clients must send (`Authorization: Bearer <api_key>`). The addon won't start without it |
| `repo_path` | `/config` | Path to the git repository |
| `ssh_key_path` | `/config/.ssh/id_rsa` | Path to SSH private key for git push |

## SSH key setup

`git_push` uses the SSH key at `ssh_key_path` with `StrictHostKeyChecking=no`. Ensure the key is present and has correct permissions:

```bash
chmod 600 /config/.ssh/id_rsa
```

The public key must be added to your GitHub/GitLab account.

## Open WebUI connection

```
http://localhost:3002/mcp
```

Set **Auth** to `Bearer` with the addon's `api_key`. Generate a key with `openssl rand -hex 32`.

**Never expose port 3002 to the internet.** With `host_network` it is reachable from your LAN, and the `api_key` is the only thing protecting it.
