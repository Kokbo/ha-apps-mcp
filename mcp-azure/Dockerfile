# Debian instead of the repo's usual node:*-alpine base:
#  - Azure CLI is only officially packaged for glibc distros (Microsoft apt repo,
#    amd64 + arm64).
#  - @azure/mcp ships glibc-only native binaries in its npm platform packages
#    (@azure/mcp-linux-x64 / -linux-arm64) and requires Node >= 22.
FROM node:26-bookworm-slim

# Pinned versions. Bump deliberately (and update CHANGELOG / config.yaml version).
# renovate: datasource=github-releases depName=Azure/azure-cli extractVersion=^azure-cli-(?<version>.+)$
ARG AZURE_CLI_VERSION=2.93.0
# Empty = latest azure-devops extension at build time.
ARG AZURE_DEVOPS_EXTENSION_VERSION=

# AZURE_CONFIG_DIR lives in /data so the az token cache survives restarts and
# addon updates. Extensions are installed in the image (not in /data) so they
# are versioned with the image.
ENV AZURE_CONFIG_DIR=/data/.azure \
    AZURE_EXTENSION_DIR=/opt/az-extensions \
    AZURE_CORE_COLLECT_TELEMETRY=false \
    AZURE_CORE_LOGIN_EXPERIENCE_V2=off \
    AZURE_CORE_NO_COLOR=true \
    PYTHONUNBUFFERED=1

# bash + pipefail so a failed key download (curl | gpg) fails the build.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# libicu72: azmcp is a .NET app; without ICU, `azmcp server start` aborts with
# "Couldn't find a valid ICU package" (`azmcp --version` still works).
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl gnupg jq libicu72; \
    mkdir -p /etc/apt/keyrings; \
    curl -sLS https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg; \
    chmod go+r /etc/apt/keyrings/microsoft.gpg; \
    . /etc/os-release; \
    printf 'Types: deb\nURIs: https://packages.microsoft.com/repos/azure-cli/\nSuites: %s\nComponents: main\nArchitectures: %s\nSigned-by: /etc/apt/keyrings/microsoft.gpg\n' \
      "$VERSION_CODENAME" "$(dpkg --print-architecture)" > /etc/apt/sources.list.d/azure-cli.sources; \
    apt-get update; \
    apt-get install -y --no-install-recommends "azure-cli=${AZURE_CLI_VERSION}-1~${VERSION_CODENAME}"; \
    rm -rf /var/lib/apt/lists/*; \
    mkdir -p "$AZURE_EXTENSION_DIR"; \
    AZURE_CONFIG_DIR=/tmp/az-build az extension add --name azure-devops --yes \
      ${AZURE_DEVOPS_EXTENSION_VERSION:+--version "$AZURE_DEVOPS_EXTENSION_VERSION"}; \
    AZURE_CONFIG_DIR=/tmp/az-build az version; \
    rm -rf /tmp/az-build

WORKDIR /app

COPY package.json ./
# Installs the pinned MCP servers locally (same pattern as the other addons).
# The azmcp --version call fails the build if npm skipped the native platform
# package, so nothing is downloaded at runtime.
RUN set -eux; \
    npm install --omit=dev --no-audit --no-fund; \
    test -x node_modules/.bin/azmcp; \
    test -x node_modules/.bin/mcp-server-azuredevops; \
    node_modules/.bin/azmcp --version; \
    npm cache clean --force

COPY src/ ./src/
COPY run.sh /
RUN chmod +x /run.sh

CMD ["/run.sh"]
