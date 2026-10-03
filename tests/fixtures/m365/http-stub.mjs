// ZYGGY_M365_HTTP_STUB — the HTTP mode of the ms-365-mcp-server test stand-in (plan 23 Step R8, spec AC-53), started
// by ms-365-mcp-server-stub.sh when it gets --http. Mirrors what the pinned 0.157.2 does on POST /mcp (read from its
// source): no or a non-Bearer Authorization → 401 with WWW-Authenticate; a JWT whose payload "exp" is past → 401
// "The access token has expired"; otherwise stateless JSON-RPC answered with plain JSON — initialize, tools/list (the
// pinned list filtered by ENABLED_TOOLS case-insensitively, no auth tools in HTTP mode, download-bytes-to-file only
// with --http-local-file-tools), tools/call (an empty result). GET /mcp → 405. Binds only the --http address.
// Logs to the stub's server-stub.log: token=match|mismatch|absent per request and rpc=<method> after the door —
// never the token. It is installed in the stub's fixtures/ directory, beside tools-list-0.157.2.json and token-ok.json.
import { createServer } from "node:http";
import { appendFileSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const log = (line) => appendFileSync(join(here, "..", "server-stub.log"), line + "\n");
const fixtures = here;
const args = process.argv.slice(2);
const at = args.indexOf("--http");
const [host, port] = (at >= 0 ? args[at + 1] : "").split(":");
const localFileTools = args.includes("--http-local-file-tools");
const expected = JSON.parse(readFileSync(join(fixtures, "token-ok.json"), "utf8")).access_token;
const filter = new RegExp(process.env.ENABLED_TOOLS || "^$", "i");
const tools = JSON.parse(readFileSync(join(fixtures, "tools-list-0.157.2.json"), "utf8")).tools
  .filter((t) => filter.test(t.name))
  .filter((t) => localFileTools || t.name !== "download-bytes-to-file");

const deny = (res, error, description) => {
  res.writeHead(401, {
    "Content-Type": "application/json",
    "WWW-Authenticate": `Bearer resource_metadata="http://${host}:${port}/.well-known/oauth-protected-resource", error="${error}", error_description="${description}"`,
  });
  res.end(JSON.stringify({ error, error_description: description }));
};

const expired = (token) => {
  try {
    const payload = JSON.parse(Buffer.from(token.split(".")[1], "base64url").toString("utf8"));
    return typeof payload.exp === "number" && payload.exp * 1000 < Date.now();
  } catch {
    return false;
  }
};

const server = createServer((req, res) => {
  if (req.url !== "/mcp") {
    res.writeHead(404).end();
    return;
  }
  if (req.method === "GET") {
    res.writeHead(405, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ jsonrpc: "2.0", error: { code: -32000, message: "Method not allowed." }, id: null }));
    return;
  }
  const auth = req.headers.authorization || "";
  if (!auth.startsWith("Bearer ")) {
    log("token=absent");
    deny(res, "invalid_request", "Missing or invalid access token");
    return;
  }
  const token = auth.slice(7);
  log(token === expected ? "token=match" : "token=mismatch");
  if (expired(token)) {
    deny(res, "invalid_token", "The access token has expired");
    return;
  }
  let body = "";
  req.on("data", (chunk) => (body += chunk));
  req.on("end", () => {
    let rpc;
    try {
      rpc = JSON.parse(body);
    } catch {
      res.writeHead(400, { "Content-Type": "application/json" }).end(JSON.stringify({ error: "parse error" }));
      return;
    }
    log(`rpc=${rpc.method}`);
    const answer = (result) => {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ jsonrpc: "2.0", id: rpc.id ?? null, result }));
    };
    switch (rpc.method) {
      case "initialize":
        answer({ protocolVersion: "2025-06-18", capabilities: { tools: {} }, serverInfo: { name: "ms-365-mcp-server-stub", version: "0.157.2" } });
        break;
      case "tools/list":
        answer({ tools });
        break;
      case "tools/call":
        answer({ content: [{ type: "text", text: "{}" }] });
        break;
      default:
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ jsonrpc: "2.0", id: rpc.id ?? null, error: { code: -32601, message: "Method not found" } }));
    }
  });
});
server.listen(Number(port), host, () => log(`listen=${host}:${port}`));
process.on("SIGTERM", () => server.close(() => process.exit(0)));
