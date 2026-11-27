#!/bin/sh
set -eu

OPTIONS=/data/options.json
LOGIN_TIMEOUT=900        # device codes expire after ~15 minutes
LOGIN_RETRY_DELAY=30

log() { echo "[mcp-azure] $*"; }

API_KEY=$(jq -r '.api_key // ""' "$OPTIONS")
TENANT=$(jq -r '.tenant // ""' "$OPTIONS")

if [ -z "$API_KEY" ]; then
  log "ERROR: the 'api_key' option is empty. Set it on the Configuration tab and start the addon again."
  exit 1
fi

# `false // true` is true in jq, so compare explicitly.
AZURE_ENABLED=$(jq -r 'if .azure_enabled == false then "false" else "true" end' "$OPTIONS")
DEVOPS_ORG=$(jq -r '(.devops_organization // "") | gsub("^\\s+|\\s+$"; "")' "$OPTIONS")
HAS_DEVOPS_PAT=$(jq -r 'if ((.devops_pat // "") | gsub("^\\s+|\\s+$"; "")) != "" then "true" else "false" end' "$OPTIONS")

# The Azure MCP Server always needs az login; the DevOps server only when it
# has no personal access token.
if [ "$AZURE_ENABLED" = false ] && { [ -z "$DEVOPS_ORG" ] || [ "$HAS_DEVOPS_PAT" = true ]; }; then
  log "Azure MCP Server disabled and Azure DevOps uses a personal access token: no az login needed."
  exec node /app/src/server.js
fi

mkdir -p "$AZURE_CONFIG_DIR"
chmod 700 "$AZURE_CONFIG_DIR"

# Run long commands in the background + wait, so HA's stop (SIGTERM) is
# handled immediately instead of after az login returns.
child=""
term() {
  log "Stopping."
  if [ -n "$child" ]; then kill "$child" 2>/dev/null || true; fi
  exit 0
}
trap term TERM INT

token_ok() {
  if [ -n "$TENANT" ]; then
    az account get-access-token --tenant "$TENANT" --output none >/dev/null 2>&1
  else
    az account get-access-token --output none >/dev/null 2>&1
  fi
}

log "Azure CLI config dir: $AZURE_CONFIG_DIR"

while ! token_ok; do
  log "No valid Azure CLI session. Starting device-code login${TENANT:+ for tenant $TENANT}."
  log ">>> Open https://microsoft.com/devicelogin and enter the code from the next line <<<"
  if [ -n "$TENANT" ]; then
    timeout "$LOGIN_TIMEOUT" az login --use-device-code --allow-no-subscriptions --tenant "$TENANT" --output none &
  else
    timeout "$LOGIN_TIMEOUT" az login --use-device-code --allow-no-subscriptions --output none &
  fi
  child=$!
  if wait "$child"; then
    child=""
    log "az login finished."
  else
    rc=$?
    child=""
    log "az login failed or timed out (exit $rc). Retrying in ${LOGIN_RETRY_DELAY}s..."
    sleep "$LOGIN_RETRY_DELAY" &
    child=$!
    wait "$child" || true
    child=""
  fi
done

ACCOUNT=$(az account show --query user.name --output tsv 2>/dev/null || echo "unknown")
ACCOUNT_TENANT=$(az account show --query tenantId --output tsv 2>/dev/null || echo "unknown")
log "Logged in to Azure as ${ACCOUNT} (tenant ${ACCOUNT_TENANT})."

exec node /app/src/server.js
