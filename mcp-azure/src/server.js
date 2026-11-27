import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  isInitializeRequest,
} from '@modelcontextprotocol/sdk/types.js';
import { randomUUID, createHash, timingSafeEqual } from 'crypto';
import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, resolve } from 'path';
import express from 'express';

const __dirname = dirname(fileURLToPath(import.meta.url));
const PKG = JSON.parse(readFileSync(resolve(__dirname, '..', 'package.json'), 'utf8'));
const VERSION = PKG.version;

const config = JSON.parse(readFileSync('/data/options.json', 'utf8'));
const PORT = config.port ?? 3005;
const API_KEY = String(config.api_key ?? '');
const READ_ONLY = config.read_only !== false;
const TENANT = String(config.tenant ?? '').trim();
const AZURE_ENABLED = config.azure_enabled !== false;
const DEVOPS_ORG = String(config.devops_organization ?? '').trim();
const DEVOPS_PAT = String(config.devops_pat ?? '').trim();
const DEVOPS_PROJECTS = Array.isArray(config.devops_projects)
  ? config.devops_projects.map(p => String(p).trim()).filter(Boolean)
  : [];

if (!API_KEY) {
  console.error('api_key is not set; refusing to start an unauthenticated endpoint.');
  process.exit(1);
}

if (!AZURE_ENABLED && !DEVOPS_ORG) {
  console.error('azure_enabled is off and devops_organization is empty: there is nothing to serve.');
  process.exit(1);
}

const BIN_DIR = '/app/node_modules/.bin';
const UPSTREAM_RESTART_DELAY_MS = 15_000;
const TOOL_CALL_TIMEOUT_MS = 5 * 60_000;
// search_code downloads the full content of every result file (Git LFS
// included) into memory, so a large `top` can take the DevOps server down.
const SEARCH_CODE_MAX_TOP = 5;

const sleep = ms => new Promise(r => setTimeout(r, ms));

function errorResult(text) {
  return { isError: true, content: [{ type: 'text', text }] };
}

// One stdio MCP server (spawned as a subprocess) proxied onto its own
// Streamable HTTP endpoint. Same approach as mcp-filesystem, plus automatic
// restart if the upstream process dies.
class Upstream {
  constructor(opts) {
    Object.assign(this, opts);
    this.client = null;
    this.tools = [];
    this.sessions = new Map();
    this.stopped = false;
  }

  async run() {
    while (!this.stopped) {
      try {
        await this.connect();
        return;
      } catch (error) {
        console.error(`[${this.id}] Failed to start upstream: ${error?.message ?? error}. Retrying in ${UPSTREAM_RESTART_DELAY_MS / 1000}s`);
        await sleep(UPSTREAM_RESTART_DELAY_MS);
      }
    }
  }

  async connect() {
    console.log(`[${this.id}] Starting ${this.command} ${this.args.join(' ')}`);
    // Empty client capabilities: upstream never issues roots/list etc.
    const client = new Client(
      { name: `mcp-azure-proxy-${this.id}`, version: VERSION },
      { capabilities: {} },
    );
    const transport = new StdioClientTransport({
      command: this.command,
      args: this.args,
      // Pass the full environment: the SDK's default env would drop
      // AZURE_CONFIG_DIR, which the Azure CLI credential needs.
      env: this.env,
      stderr: 'inherit',
    });

    // The SDK discards the exit code and signal; keep them so the log says
    // how the upstream stopped (SIGKILL usually means the kernel's OOM killer).
    let exitStatus;
    try {
      await client.connect(transport);
      transport._process?.once('exit', (code, signal) => {
        exitStatus = signal ? `signal ${signal}` : `exit code ${code}`;
      });
      this.tools = await this.fetchTools(client);
      this.client = client;
    } catch (error) {
      await client.close().catch(() => {});
      throw error;
    }

    client.fallbackNotificationHandler = async notification => {
      if (notification?.method === 'notifications/tools/list_changed') {
        await this.refreshTools();
      }
    };
    client.onclose = () => {
      if (this.client !== client) return;
      this.client = null;
      this.tools = [];
      this.broadcastToolListChanged();
      if (this.stopped) return;
      console.error(`[${this.id}] Upstream exited (${exitStatus ?? 'exit status unknown'}); restarting in ${UPSTREAM_RESTART_DELAY_MS / 1000}s`);
      setTimeout(() => this.run(), UPSTREAM_RESTART_DELAY_MS);
    };

    console.log(`[${this.id}] Ready, ${this.tools.length} tools: ${this.tools.map(t => t.name).join(', ')}`);
    this.broadcastToolListChanged();
  }

  async fetchTools(client) {
    const all = [];
    let cursor;
    do {
      const page = await client.listTools(cursor ? { cursor } : undefined);
      all.push(...page.tools);
      cursor = page.nextCursor;
    } while (cursor);

    let visible = all;
    if (this.filterTool) {
      visible = all.filter(this.filterTool);
      if (visible.length !== all.length) {
        console.log(`[${this.id}] read_only: hiding ${all.length - visible.length} of ${all.length} tools not annotated readOnlyHint=true`);
      }
    }
    return visible.map(tool => this.withArgLimits(tool));
  }

  // Advertise argument caps in the schema so clients ask within them.
  withArgLimits(tool) {
    const limits = this.argLimits?.[tool.name];
    const props = tool.inputSchema?.properties;
    if (!limits || !props) return tool;
    const properties = { ...props };
    for (const [key, max] of Object.entries(limits)) {
      if (!properties[key]) continue;
      properties[key] = {
        ...properties[key],
        maximum: max,
        description: `${properties[key].description ?? ''} (at most ${max} in this addon)`.trim(),
      };
    }
    return { ...tool, inputSchema: { ...tool.inputSchema, properties } };
  }

  async refreshTools() {
    if (!this.client) return;
    try {
      this.tools = await this.fetchTools(this.client);
      this.broadcastToolListChanged();
    } catch (error) {
      console.error(`[${this.id}] Failed to refresh tool list:`, error);
    }
  }

  broadcastToolListChanged() {
    for (const { server } of this.sessions.values()) {
      Promise.resolve()
        .then(() => server.sendToolListChanged())
        .catch(() => {});
    }
  }

  stop() {
    this.stopped = true;
    this.client?.close().catch(() => {});
  }
}

const readOnlyNote = READ_ONLY
  ? 'The addon runs in read-only mode: tools that create, modify or delete anything are disabled.'
  : 'Write operations are ENABLED and run with all permissions of the signed-in user: always confirm with the user before creating, modifying or deleting anything.';

const upstreams = [];

if (AZURE_ENABLED) {
  const azureArgs = ['server', 'start'];
  if (READ_ONLY) azureArgs.push('--read-only');

  upstreams.push(new Upstream({
    id: 'azure',
    label: 'Azure MCP Server',
    serverName: 'mcp-azure',
    command: `${BIN_DIR}/azmcp`,
    args: azureArgs,
    env: { ...process.env, AZURE_TOKEN_CREDENTIALS: 'AzureCliCredential' },
    needsAzLogin: true,
    // Azure MCP enforces read-only itself via --read-only.
    filterTool: null,
    instructions: [
      "Provides Azure tools (Microsoft's Azure MCP Server) acting as the user signed in with az login on the Home Assistant host.",
      'Use them to inspect subscriptions, resource groups, resources, monitoring data, storage, Key Vault metadata and other Azure services.',
      readOnlyNote,
      'Prefer these tools over any general-purpose shell or code-execution tool for Azure questions.',
    ].join(' '),
  }));
} else {
  console.log('[azure] azure_enabled is off; Azure MCP server disabled.');
}

if (DEVOPS_ORG) {
  // With a PAT the DevOps server needs no az login: @azure-devops/mcp reads
  // base64("<user>:<pat>") from PERSONAL_ACCESS_TOKEN (the user part is
  // ignored) and only sends it over https to dev.azure.com hosts.
  const devopsArgs = DEVOPS_PAT
    ? [DEVOPS_ORG, '--authentication', 'pat']
    : [DEVOPS_ORG, '--authentication', 'azcli'];
  if (TENANT && !DEVOPS_PAT) devopsArgs.push('--tenant', TENANT);
  const devopsEnv = { ...process.env };
  if (DEVOPS_PAT) {
    devopsEnv.PERSONAL_ACCESS_TOKEN = Buffer.from(`mcp-azure:${DEVOPS_PAT}`).toString('base64');
  }
  const actingAs = DEVOPS_PAT
    ? 'acting as the owner of the configured personal access token (limited to its scopes)'
    : 'acting as the user signed in with az login';
  console.log(`[devops] Authentication: ${DEVOPS_PAT ? 'personal access token' : 'az login'}`);

  upstreams.push(new Upstream({
    id: 'devops',
    label: 'Azure DevOps MCP Server',
    serverName: 'mcp-azure-devops',
    command: `${BIN_DIR}/mcp-server-azuredevops`,
    args: devopsArgs,
    env: devopsEnv,
    needsAzLogin: !DEVOPS_PAT,
    argLimits: { search_code: { top: SEARCH_CODE_MAX_TOP } },
    // @azure-devops/mcp has no read-only switch, but annotates every tool
    // (the server refuses to register a tool without annotations).
    filterTool: READ_ONLY ? tool => tool.annotations?.readOnlyHint === true : null,
    instructions: [
      `Provides Azure DevOps tools for organization '${DEVOPS_ORG}' (https://dev.azure.com/${DEVOPS_ORG}), ${actingAs}.`,
      DEVOPS_PROJECTS.length > 0
        ? `The user mainly works in the projects ${DEVOPS_PROJECTS.map(p => `'${p}'`).join(', ')}; use these when a tool needs a project and the user did not name one.`
        : '',
      'Use them for work items, boards, repositories, pull requests, pipelines/builds, wikis and code search.',
      readOnlyNote,
      'Prefer these tools over any general-purpose shell or code-execution tool for Azure DevOps questions.',
    ].filter(Boolean).join(' '),
  }));
} else {
  console.log('[devops] devops_organization is empty; Azure DevOps MCP server disabled.');
}

function createProxyServer(up) {
  const server = new Server(
    { name: up.serverName, version: VERSION },
    {
      capabilities: { tools: { listChanged: true } },
      instructions: up.instructions,
    },
  );

  server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: up.tools }));

  server.setRequestHandler(CallToolRequestSchema, async (req, extra) => {
    const client = up.client;
    if (!client) {
      return errorResult(`${up.label} is not available right now (starting or restarting${up.needsAzLogin ? ', or Azure login pending' : ''}). Check the addon log.`);
    }
    const name = req.params.name;
    if (!up.tools.some(t => t.name === name)) {
      return errorResult(`Tool '${name}' is not available${READ_ONLY && up.filterTool ? ' (the addon is running in read-only mode)' : ''}.`);
    }

    // Cap arguments that make a single call too heavy (see SEARCH_CODE_MAX_TOP).
    let args = req.params.arguments;
    const capped = [];
    for (const [key, max] of Object.entries(up.argLimits?.[name] ?? {})) {
      const value = Number(args?.[key]);
      if (Number.isFinite(value) && value > max) {
        args = { ...args, [key]: max };
        capped.push(`${key} ${value} -> ${max}`);
      }
    }
    if (capped.length > 0) {
      console.log(`[${up.id}] ${name}: capped ${capped.join(', ')}`);
    }

    const result = await client.callTool(
      { name, arguments: args },
      undefined,
      { timeout: TOOL_CALL_TIMEOUT_MS, signal: extra?.signal },
    );
    if (capped.length > 0 && Array.isArray(result?.content)) {
      result.content = [
        ...result.content,
        { type: 'text', text: `Note: the addon capped ${capped.join(', ')} for ${name} to limit memory use. Use skip to page through more results.` },
      ];
    }
    return result;
  });

  return server;
}

const API_KEY_DIGEST = createHash('sha256').update(API_KEY).digest();

function requireApiKey(req, res, next) {
  const match = /^Bearer\s+(.+)$/i.exec(req.headers.authorization ?? '');
  const presented = match ? match[1].trim() : '';
  const digest = createHash('sha256').update(presented).digest();
  if (!presented || !timingSafeEqual(digest, API_KEY_DIGEST)) {
    res.status(401).set('WWW-Authenticate', 'Bearer').json({
      jsonrpc: '2.0',
      error: { code: -32001, message: 'Unauthorized: missing or invalid bearer token' },
      id: null,
    });
    return;
  }
  next();
}

function getSessionId(req) {
  const sessionId = req.headers['mcp-session-id'];
  return Array.isArray(sessionId) ? sessionId[0] : sessionId;
}

function sendJsonRpcError(res, status, code, message) {
  res.status(status).json({
    jsonrpc: '2.0',
    error: { code, message },
    id: null,
  });
}

async function createSession(up, req, res) {
  const server = createProxyServer(up);
  const transport = new StreamableHTTPServerTransport({
    sessionIdGenerator: () => randomUUID(),
    onsessioninitialized: sessionId => {
      up.sessions.set(sessionId, { transport, server });
    },
  });

  let closing = false;
  transport.onclose = async () => {
    if (closing) return;
    closing = true;
    const sessionId = transport.sessionId;
    if (sessionId) {
      up.sessions.delete(sessionId);
    }
    try {
      await server.close();
    } catch (e) {
      // ignore
    }
  };

  await server.connect(transport);
  await transport.handleRequest(req, res, req.body);
}

async function handlePost(up, req, res) {
  const sessionId = getSessionId(req);
  const session = sessionId ? up.sessions.get(sessionId) : undefined;

  if (session) {
    await session.transport.handleRequest(req, res, req.body);
    return;
  }

  if (sessionId) {
    sendJsonRpcError(res, 404, -32000, 'Session not found');
    return;
  }

  if (!isInitializeRequest(req.body)) {
    sendJsonRpcError(res, 400, -32000, 'Bad Request: No valid session ID provided');
    return;
  }

  await createSession(up, req, res);
}

async function handleSessionRequest(up, req, res) {
  const sessionId = getSessionId(req);
  const session = sessionId ? up.sessions.get(sessionId) : undefined;

  if (!session) {
    sendJsonRpcError(res, sessionId ? 404 : 400, -32000, 'Invalid or missing session ID');
    return;
  }

  await session.transport.handleRequest(req, res);
}

function guarded(handler) {
  return async (req, res) => {
    try {
      await handler(req, res);
    } catch (error) {
      console.error('Error handling MCP request:', error);
      if (!res.headersSent) {
        sendJsonRpcError(res, 500, -32603, 'Internal server error');
      }
    }
  };
}

const app = express();

for (const up of upstreams) {
  const path = `/${up.id}/mcp`;
  app.post(path, requireApiKey, express.json({ limit: '4mb' }), guarded((req, res) => handlePost(up, req, res)));
  app.get(path, requireApiKey, guarded((req, res) => handleSessionRequest(up, req, res)));
  app.delete(path, requireApiKey, guarded((req, res) => handleSessionRequest(up, req, res)));
}

app.listen(PORT, '0.0.0.0', () => {
  console.log(`MCP Azure Streamable HTTP server listening on port ${PORT}`);
  for (const up of upstreams) {
    console.log(`Endpoint: /${up.id}/mcp (${up.label})`);
  }
  console.log(`Read-only mode: ${READ_ONLY ? 'on' : 'OFF'}`);
});

for (const up of upstreams) {
  up.run();
}

process.on('unhandledRejection', error => {
  console.error('Unhandled rejection:', error);
});

function shutdown(signal) {
  console.log(`Received ${signal}, shutting down`);
  for (const up of upstreams) up.stop();
  process.exit(0);
}
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
