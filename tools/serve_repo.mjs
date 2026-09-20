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
const handler = require("../api/repo.js");

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const PUBLIC = join(ROOT, "public");
const PORT = Number(process.argv[2] || process.env.PORT || 43117);

const REWRITES = {
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
  const { pathname } = new URL(req.url, `http://${req.headers.host}`);

  const file = REWRITES[pathname];
  if (file) {
    req.query = { file };
    return handler(req, shim(res));
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

server.listen(PORT, "127.0.0.1", () => {
  console.log(`repo serving on http://127.0.0.1:${PORT}/`);
});
