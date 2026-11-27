#!/usr/bin/env bash
# After a Renovate PR lands on main, bump the patch version of every addon it
# touched, so Home Assistant offers the update (the Supervisor only rebuilds
# an addon when the version in config.yaml changes).
#
# Runs in .github/workflows/bump-version.yml. Inputs (environment):
#   GH_TOKEN  token for the GitHub API and the push (GITHUB_TOKEN)
#   REPO      owner/name
#   SHA       the commit that landed on main
#   DRY_RUN   if "true", commit but don't push (for local testing)
set -euo pipefail

: "${REPO:?}" "${SHA:?}"
DRY_RUN=${DRY_RUN:-false}

# 1. Was this commit a Renovate PR? Ask GitHub which PR the commit belongs to,
#    so hand merges of Renovate PRs count too.
pr_json=$(gh api "repos/${REPO}/commits/${SHA}/pulls" \
  --jq '[.[] | select(.head.ref | startswith("renovate/"))] | first // empty')
if [ -z "${pr_json}" ]; then
  echo "Commit ${SHA} is not from a Renovate PR; nothing to do."
  exit 0
fi
pr_number=$(jq -r '.number' <<<"${pr_json}")
pr_title=$(jq -r '.title' <<<"${pr_json}")
echo "Commit ${SHA} comes from Renovate PR #${pr_number}: ${pr_title}"

# 2. Which addons did it touch, and did it already change their version?
parent="${SHA}^1"
mapfile -t touched < <(git diff --name-only "${parent}" "${SHA}" \
  | sed -n 's#^\(mcp-[^/]*\)/.*#\1#p' | sort -u)

addons=()
for addon in "${touched[@]}"; do
  [ -f "${addon}/config.yaml" ] || continue
  if git diff "${parent}" "${SHA}" -- "${addon}/config.yaml" | grep -qE '^[-+]version:'; then
    echo "${addon}: the PR already changed the version; skipping."
    continue
  fi
  addons+=("${addon}")
done

if [ "${#addons[@]}" -eq 0 ]; then
  echo "No addon needs a version bump."
  exit 0
fi

bump_patch() {
  local v=$1
  [[ "${v}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || { echo "Unsupported version '${v}'" >&2; return 1; }
  echo "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((BASH_REMATCH[3] + 1))"
}

# Apply the bump to the current working tree; prints "addon x.y.z" per addon.
apply_bumps() {
  local addon current next changelog tmp
  for addon in "${addons[@]}"; do
    current=$(sed -n 's/^version: "\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "${addon}/config.yaml")
    next=$(bump_patch "${current}")
    sed -i "s/^version: .*/version: \"${next}\"/" "${addon}/config.yaml"
    if [ -f "${addon}/package.json" ]; then
      tmp=$(mktemp)
      jq --arg v "${next}" '.version = $v' "${addon}/package.json" > "${tmp}"
      mv "${tmp}" "${addon}/package.json"
    fi
    changelog="${addon}/CHANGELOG.md"
    [ -f "${changelog}" ] || printf '# Changelog\n' > "${changelog}"
    tmp=$(mktemp)
    {
      head -n 1 "${changelog}"
      printf '\n## %s\n\n- Dependency update: %s (#%s).\n' "${next}" "${pr_title}" "${pr_number}"
      tail -n +2 "${changelog}"
    } > "${tmp}"
    mv "${tmp}" "${changelog}"
    echo "${addon} ${next}"
  done
}

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

# 3. Commit and push; if main moved meanwhile, redo the bump on a fresh tree.
for attempt in 1 2 3; do
  bumped=$(apply_bumps)
  echo "${bumped}"
  git add -- "${addons[@]}"
  {
    printf 'Bump %s after #%s\n\n' "$(awk '{printf "%s%s to %s", (NR > 1 ? ", " : ""), $1, $2}' <<<"${bumped}")" "${pr_number}"
    printf 'Renovate PR #%s: %s\n' "${pr_number}" "${pr_title}"
  } | git commit -q -F -

  if [ "${DRY_RUN}" = true ]; then
    git log -1 --stat
    exit 0
  fi
  if git push origin HEAD:main; then
    exit 0
  fi
  echo "Push rejected (attempt ${attempt}); refreshing main and retrying."
  git fetch --quiet origin main
  git reset --quiet --hard origin/main
done

echo "Could not push the version bump after 3 attempts." >&2
exit 1
