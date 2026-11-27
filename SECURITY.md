# Security policy

## Reporting a vulnerability

Please report security issues privately through GitHub's
[private vulnerability reporting](https://github.com/Kokbo/ha-apps-mcp/security/advisories/new)
("Report a vulnerability" on the Security tab). Don't open a public issue.

You can expect an acknowledgement within a week. This is a personal project,
so fixes are best-effort.

## Supported versions

Only the latest version of each addon in this repository is supported.

## Scope

These addons give an MCP client access to Home Assistant's `/config`, git,
Node-RED, InfluxDB and Azure. Each endpoint requires a bearer `api_key` and is
meant for your local network only: never expose the addon ports to the
internet. Reports about bypassing the `api_key`, escaping the configured paths,
or leaking credentials are especially welcome.
