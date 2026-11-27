#!/usr/bin/env bash
# Smoke test for one addon image: start it the way Home Assistant would
# (options in /data/options.json, /config mounted) and check that the MCP
# endpoint answers an initialize request, and that it enforces the api_key
# when the addon's schema has one.
#
# Usage: smoke-test.sh <addon-dir> <image>
set -euo pipefail

addon=${1:?addon directory}
image=${2:?image tag}
name="smoke-${addon}"
key="smoke-test-key"

config_yaml="${addon}/config.yaml"
port=$(sed -n 's/^  port: \([0-9][0-9]*\)$/\1/p' "${config_yaml}" | head -n 1)
[ -n "${port}" ] || { echo "No default port in ${config_yaml}" >&2; exit 1; }

requires_key=false
if grep -q '^  api_key: password$' "${config_yaml}"; then
  requires_key=true
fi

# shellcheck source=.github/scripts/annotate.sh
. "$(dirname "$0")/annotate.sh"

fail() {
  local logs
  logs=$(docker logs --tail 40 "${name}" 2>&1 || true)
  annotate_error "smoke test failed: ${addon}" "$1"$'\n'"--- container log (last 40 lines) ---"$'\n'"${logs}"
  echo "FAIL: $1" >&2
  exit 1
}

work=$(mktemp -d)
mkdir -p "${work}/data" "${work}/config"

cleanup() {
  echo "::group::Container log (${name})"
  docker logs "${name}" 2>&1 || true
  echo "::endgroup::"
  docker rm -f "${name}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

path=/mcp
entrypoint=()
case "${addon}" in
  mcp-filesystem)
    options='{"allowed_paths": ["/config"]}'
    ;;
  mcp-git)
    options='{"repo_path": "/config", "ssh_key_path": "/config/.ssh/id_rsa"}'
    git -C "${work}/config" init -q
    ;;
  mcp-node-red)
    options='{"node_red_url": "http://127.0.0.1:1880", "node_red_user": "", "node_red_password": ""}'
    ;;
  mcp-influxdb)
    options='{"influxdb_url": "http://127.0.0.1:8086", "influxdb_database": "homeassistant", "influxdb_user": "", "influxdb_password": ""}'
    ;;
  mcp-azure)
    # run.sh blocks on an interactive `az login`; start the server directly
    # for the HTTP checks. A (fake) organization also starts the DevOps
    # upstream, so both stdio servers have to come up.
    options='{"devops_organization": "smoke-test-org", "devops_projects": [], "read_only": true}'
    path=/azure/mcp
    entrypoint=(--entrypoint node)
    ;;
  *)
    echo "Unknown addon: ${addon}" >&2
    exit 1
    ;;
esac

write_options() {
  jq -n --argjson base "${options}" --argjson port "${port}" --arg key "$1" \
    '$base + {port: $port, api_key: $key}' > "${work}/data/options.json"
}

start() {
  local cmd=()
  if [ "${addon}" = mcp-azure ]; then cmd=(/app/src/server.js); fi
  docker run -d --name "${name}" --network host \
    -v "${work}/data:/data" -v "${work}/config:/config" \
    "${entrypoint[@]}" "${image}" "${cmd[@]}" >/dev/null
}

http_code() {
  # $1: extra curl args (an Authorization header or nothing)
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    "$@" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"smoke-test","version":"1"}}}' \
    "http://127.0.0.1:${port}${path}" || true
}

if [ "${requires_key}" = true ]; then
  echo "--- An empty api_key must stop the addon from starting"
  write_options ""
  start
  for _ in $(seq 1 60); do
    [ "$(docker inspect -f '{{.State.Running}}' "${name}")" = false ] && break
    sleep 1
  done
  if [ "$(docker inspect -f '{{.State.Running}}' "${name}")" != false ]; then
    fail "addon is still running with an empty api_key"
  fi
  rc=$(docker inspect -f '{{.State.ExitCode}}' "${name}")
  [ "${rc}" != 0 ] || fail "exited 0 with an empty api_key"
  echo "ok: exited with code ${rc}"
  cleanup
fi

echo "--- Start with an api_key and wait for ${path} on port ${port}"
write_options "${key}"
start
code=000
for _ in $(seq 1 120); do
  if [ "$(docker inspect -f '{{.State.Running}}' "${name}")" != true ]; then
    fail "container exited during startup (exit code $(docker inspect -f '{{.State.ExitCode}}' "${name}"))"
  fi
  code=$(http_code -H "Authorization: Bearer ${key}")
  [ "${code}" != 000 ] && break
  sleep 1
done

echo "initialize with the key: HTTP ${code}"
[ "${code}" = 200 ] || fail "initialize with the key returned HTTP ${code}, expected 200"

if [ "${requires_key}" = true ]; then
  for header in "" "Authorization: Bearer " "Authorization: Bearer wrong-key"; do
    if [ -n "${header}" ]; then code=$(http_code -H "${header}"); else code=$(http_code); fi
    echo "initialize with '${header:-no header}': HTTP ${code}"
    [ "${code}" = 401 ] || fail "initialize with '${header:-no header}' returned HTTP ${code}, expected 401"
  done
else
  echo "note: ${config_yaml} has no api_key option; auth checks skipped"
fi

# wait_for_log <extended regex> <seconds>: succeed once the container log
# matches. The log goes into a variable first: piping `docker logs` into
# `grep -q` can fail under pipefail when grep exits early.
wait_for_log() {
  local logs
  for _ in $(seq 1 "$2"); do
    logs=$(docker logs "${name}" 2>&1 || true)
    if grep -Eq -- "$1" <<<"${logs}"; then return 0; fi
    sleep 1
  done
  return 1
}

if [ "${addon}" = mcp-azure ]; then
  # The HTTP endpoint answers before the stdio servers are up, so a server
  # that crashes at start (e.g. azmcp without ICU) would otherwise pass.
  echo "--- Both upstream MCP servers must report Ready"
  for id in azure devops; do
    wait_for_log "^\[${id}\] Ready" 120 || fail "no '[${id}] Ready' in the container log within 120s"
    echo "ok: [${id}] Ready"
  done

  echo "--- run.sh without an az session must start a device-code login"
  cleanup
  docker run -d --name "${name}" --network host \
    -v "${work}/data:/data" -v "${work}/config:/config" "${image}" >/dev/null
  if wait_for_log 'enter the code [A-Z0-9]+' 90; then
    echo "ok: device-code prompt shown"
  else
    # Needs login.microsoftonline.com, so a network problem must not fail CI.
    logs=$(docker logs --tail 20 "${name}" 2>&1 || true)
    annotate_warning "smoke test: ${addon}" "no device-code prompt within 90s (needs login.microsoftonline.com)"$'\n'"${logs}"
    echo "WARN: no device-code prompt within 90s" >&2
  fi
fi

echo "PASS: ${addon}"
