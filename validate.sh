#!/usr/bin/env bash
set -euo pipefail

ERRORS=0

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; ((ERRORS++)) || true; }

echo "=== Repository structure ==="
for f in repository.json README.md; do
  if [ -f "$f" ]; then pass "$f exists"; else fail "$f missing"; fi
done

for addon in mcp-filesystem mcp-git mcp-node-red mcp-influxdb mcp-azure; do
  echo ""
  echo "--- $addon ---"
  for f in config.yaml Dockerfile run.sh README.md; do
    if [ -f "$addon/$f" ]; then pass "$f"; else fail "$f missing"; fi
  done
done

echo ""
echo "=== JSON syntax ==="
for f in repository.json mcp-filesystem/package.json mcp-git/package.json mcp-node-red/package.json mcp-azure/package.json; do
  if [ -f "$f" ]; then
    if python3 -c "import json; json.load(open('$f'))" 2>/dev/null; then
      pass "$f"
    else
      fail "$f invalid JSON"
    fi
  fi
done

echo ""
echo "=== YAML syntax ==="
for f in mcp-filesystem/config.yaml mcp-git/config.yaml mcp-node-red/config.yaml mcp-influxdb/config.yaml mcp-azure/config.yaml; do
  if [ -f "$f" ]; then
    if python3 -c "import yaml; yaml.safe_load(open('$f'))" 2>/dev/null; then
      pass "$f"
    else
      fail "$f invalid YAML"
    fi
  fi
done

echo ""
echo "=== aarch64 declared in all config.yaml ==="
for f in mcp-*/config.yaml; do
  [ -f "$f" ] || continue
  if grep -q "aarch64" "$f"; then pass "$f"; else fail "$f missing aarch64"; fi
done

echo ""
echo "=== Ports are unique ==="
PORTS=$(grep -hE '^  [0-9]+/tcp: [0-9]+$' mcp-*/config.yaml 2>/dev/null | grep -oE '[0-9]+/tcp' | sort)
UNIQUE=$(echo "$PORTS" | sort -u)
if [ "$PORTS" = "$UNIQUE" ]; then
  pass "Ports unique: $(echo "$PORTS" | tr '\n' ' ')"
else
  fail "Duplicate ports detected"
fi

echo ""
echo "=== map: config present in filesystem and git addons ==="
for addon in mcp-filesystem mcp-git; do
  f="$addon/config.yaml"
  [ -f "$f" ] || continue
  if grep -q "config" "$f"; then pass "$addon/config.yaml has map"; else fail "$addon/config.yaml missing map: config"; fi
done

echo ""
if [ "$ERRORS" -eq 0 ]; then
  echo "All validations passed."
else
  echo "$ERRORS error(s) found." >&2
  exit 1
fi
