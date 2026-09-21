/**
 * Serves the repository locally the way the hosting does.
 *
 *     node tools/serve_repo.mjs [port]
 *
 * Static files come out of public/, and the four routes vercel.json rewrites are
 * handed to the same api/repo.js the deployment runs, so `apt`, Sileo or a
 * browser pointed at this port sees exactly what the published repo serves.
 */

import { createServer } from "node:http";
import { createRequire } from "node:module";
import { extname, join, normalize, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { readFile, stat } from "node:fs/promises";

const require = createRequire(import.meta.url);

// Hosting runs the handler fresh, so it reads whatever index it was deployed
// with. This process outlives publishing a new build, so it has to forget the
// handler and the index between requests; otherwise a repo that has just been
// rebuilt keeps serving the version it started with.
function freshHandler() {
  for (const path of ["../api/repo.js", "../api/package-index.json"]) {
    delete require.cache[require.resolve(path)];
  }
  return require("../api/repo.js");
}

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const PUBLIC = join(ROOT, "public");
const PORT = Number(process.argv[2] || process.env.PORT || 43117);
// HOST=0.0.0.0 makes it reachable from the phone on the same network, which is
// enough to add the repo in Sileo without hosting it anywhere.
const HOST = process.env.HOST || "127.0.0.1";

// The handler names its own host from the request, which is right on hosting and wrong
// behind a tunnel: a tunnel that terminates TLS for you forwards the connection as plain
// HTTP and says nothing about it, so every absolute URL in the index comes out http://
// under an https:// source. Set PUBLIC_URL to the address the device will use and the
// forwarded headers hosting would have sent are added here.
//
//     PUBLIC_URL=https://example.lhr.life node tools/serve_repo.mjs
const PUBLIC_URL = process.env.PUBLIC_URL ? new URL(process.env.PUBLIC_URL) : null;

const REWRITES = {
  "/Release": "release",
  "/Packages": "packages",
  "/Packages.gz": "packages.gz",
  "/depiction.json": "depiction",
  "/sileo-featured.json": "featured",
};

const TYPES = {
  ".html": "text/html; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".png": "image/png",
  ".deb": "application/vnd.debian.binary-package",
};

/** The slice of the Vercel/Express response the handler uses. */
function shim(res) {
  res.status = (code) => {
    res.statusCode = code;
    return res;
  };
  res.send = (body) => res.end(body);
  return res;
}

const server = createServer(async (req, res) => {
  let pathname;
  try {
    ({ pathname } = new URL(req.url, `http://${req.headers.host}`));
  } catch {
    res.writeHead(400, { "Content-Type": "text/plain; charset=utf-8" });
    return res.end("bad request\n");
  }

  const file = REWRITES[pathname];
  if (file) {
    if (PUBLIC_URL) {
      req.headers["x-forwarded-proto"] = PUBLIC_URL.protocol.replace(":", "");
      req.headers["x-forwarded-host"] = PUBLIC_URL.host;
    }
    req.query = { file };
    return freshHandler()(req, shim(res));
  }

  const path = join(PUBLIC, normalize(pathname).replace(/^(\.\.[/\\])+/, ""));
  const target = pathname.endsWith("/") ? join(path, "index.html") : path;

  try {
    const info = await stat(target);
    if (info.isDirectory()) {
      res.writeHead(302, { Location: pathname + "/" });
      return res.end();
    }

    const body = await readFile(target);
    res.writeHead(200, {
      "Content-Type": TYPES[extname(target)] || "text/plain; charset=utf-8",
      "Content-Length": body.length,
      "Access-Control-Allow-Origin": "*",
    });
    res.end(body);
  } catch {
    res.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
    res.end("not found\n");
  }
});

// A malformed request should be answered, not fatal: this stays up for as long
// as a device is pointed at it.
server.on("clientError", (error, socket) => {
  if (socket.writable) socket.end("HTTP/1.1 400 Bad Request\r\n\r\n");
});

process.on("uncaughtException", (error) => {
  console.error("request failed:", error.message);
});

server.listen(PORT, HOST, () => {
  console.log(`repo serving on http://${HOST}:${PORT}/`);
});
