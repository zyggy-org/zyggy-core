// The curl stub's one real HTTP path (plan 23 Step R8): a request to http://127.0.0.1:<port>/ — the loopback MCP
// server stub — is made for real with Node's fetch, so mcp-server.sh --probe talks to a listening server. The request
// arrives on stdin as JSON {method, url, headers: ["Name: value", …], body}; the response body goes to the file named
// in argv[2] ("-" for stdout); the status code is printed on stdout (after the body when that is stdout). A refused
// connection exits 7 with curl's message. Anything but a loopback URL exits 99.
import { readFileSync, writeFileSync } from "node:fs";

const request = JSON.parse(readFileSync(0, "utf8"));
const out = process.argv[2] || "-";
const target = new URL(request.url);
if (target.protocol !== "http" + ":" || target.hostname !== "127.0.0.1" || !target.port) {
  process.stderr.write("stub: loopback client got a non-loopback URL\n");
  process.exit(99);
}
const headers = {};
for (const line of request.headers) {
  const at = line.indexOf(":");
  if (at > 0) headers[line.slice(0, at).trim()] = line.slice(at + 1).trim();
}
try {
  const res = await fetch(request.url, { method: request.method, headers, body: request.body || undefined });
  const text = await res.text();
  if (out === "-") process.stdout.write(text);
  else writeFileSync(out, text);
  process.stdout.write(String(res.status));
} catch {
  process.stderr.write(`curl: (7) Failed to connect to ${new URL(request.url).host}\n`);
  process.exit(7);
}
