import assert from "node:assert/strict";
import { Readable } from "node:stream";
import test from "node:test";
import { createHTTPHandler, createQIPDevServer } from "../qip-mcp.mjs";

const protocolVersion = "2026-07-28";
const requestMeta = {
  "io.modelcontextprotocol/protocolVersion": protocolVersion,
  "io.modelcontextprotocol/clientCapabilities": {},
};

function request(id, method, params = {}) {
  return { jsonrpc: "2.0", id, method, params: { ...params, _meta: requestMeta } };
}

async function call(server, name, args = {}) {
  return server.dispatch(request(1, "tools/call", { name, arguments: args }));
}

async function httpCall(handler, message, headers = {}, method = "POST", url = "/mcp") {
  const input = Readable.from(message === null ? [] : [Buffer.from(JSON.stringify(message))]);
  Object.assign(input, {
    method,
    url,
    headers: {
      ...(method === "POST" ? {
        "content-type": "application/json",
        "mcp-protocol-version": protocolVersion,
        "mcp-method": message.method,
        ...(message.method === "tools/call" ? { "mcp-name": message.params.name } : {}),
      } : {}),
      ...headers,
    },
  });
  let status;
  let body = "";
  await handler(input, {
    writeHead(code) { status = code; },
    end(part = "") { body += part; },
  });
  return { status, body: body === "" ? null : (body.startsWith("{") ? JSON.parse(body) : body) };
}

test("MCP discovery and tool listing use qip.dev names", async () => {
  const server = await createQIPDevServer();
  const discovery = await server.dispatch(request(1, "server/discover"));
  assert.deepEqual(discovery.supportedVersions, [protocolVersion]);
  assert.deepEqual(discovery.capabilities, { tools: {} });
  assert.equal(discovery._meta["io.modelcontextprotocol/serverInfo"].name, "qip.dev");

  const listing = await server.dispatch(request(2, "tools/list"));
  assert.deepEqual(listing.tools.map((tool) => tool.name), [
    "qip.dev.content_types.list",
    "qip.dev.recipes.search",
    "qip.dev.recipes.get_cli",
    "qip.dev.recipes.get_browser_javascript",
  ]);
});

test("recipe tools return catalog-backed CLI and browser JavaScript", async () => {
  const server = await createQIPDevServer();
  const search = await call(server, "qip.dev.recipes.search", {
    from: "image/svg+xml",
    to: "image/webp",
    preference: "quality",
  });
  const [recipe] = search.structuredContent.recipes;
  assert.equal(search.structuredContent.output_role, "deliverable");
  assert.match(recipe.steps[0], /svg-rasterize-to-ktx2-r8g8b8a8-srgb-simd\.wasm$/);
  assert.match(recipe.steps[1], /ktx2-r8g8b8a8-or-b8g8r8a8-srgb-to-webp-lossless\.wasm$/);

  const cli = await call(server, "qip.dev.recipes.get_cli", { recipe });
  assert.match(cli.structuredContent.cli, /^qip run -i input\.svg -o output\.webp -- \\\n/);
  assert.doesNotMatch(cli.structuredContent.cli, /\n\+/);

  const browser = await call(server, "qip.dev.recipes.get_browser_javascript", { recipe });
  assert.match(browser.structuredContent.javascript, /const components = await Promise\.all/);
});

test("recipe tools reject made-up recipe steps as tool errors", async () => {
  const server = await createQIPDevServer();
  const result = await call(server, "qip.dev.recipes.get_cli", {
    recipe: {
      from: "image/svg+xml",
      to: "image/webp",
      steps: ["/image/svg+xml/not-a-real-component.wasm"],
    },
  });
  assert.equal(result.isError, true);
  assert.match(result.content[0].text, /not a compatible/);
});

test("HTTP validates the MCP header and JSON-RPC body agreement", async () => {
  const server = await createQIPDevServer();
  const handler = createHTTPHandler(server);
  const message = request(1, "tools/list");

  const good = await httpCall(handler, message);
  assert.equal(good.status, 200);
  assert.equal(good.body.result.resultType, "complete");

  const bad = await httpCall(handler, message, { "mcp-method": "tools/call" });
  assert.equal(bad.status, 400);
  assert.equal(bad.body.error.code, -32020);
});

test("HTTP serves a no-store health check outside the MCP endpoint", async () => {
  const server = await createQIPDevServer();
  const handler = createHTTPHandler(server);
  const health = await httpCall(handler, null, {}, "GET", "/healthz");
  assert.equal(health.status, 200);
  assert.equal(health.body, "ok\n");
});
