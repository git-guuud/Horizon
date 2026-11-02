import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { loadHashKeyReference, unavailableLine } from "./reference.mjs";

const root = process.cwd();
const types = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".mjs": "text/javascript; charset=utf-8",
    ".json": "application/json; charset=utf-8",
};

const server = createServer(async (request, response) => {
    if (request.method !== "GET") {
        response.writeHead(405);
        response.end();
        return;
    }
    const url = new URL(request.url ?? "/", "http://127.0.0.1");
    if (url.pathname === "/web/reference.json") {
        await sendReference(url, response);
        return;
    }
    const pathname = url.pathname === "/" ? "/web/index.html" : url.pathname;
    const rel = normalize(pathname).replace(/^(\.\.(\/|\\|$))+/, "").replace(/^[/\\]+/, "");
    const file = join(root, rel);
    if (!file.startsWith(root)) {
        response.writeHead(400);
        response.end();
        return;
    }
    try {
        const body = await readFile(file);
        response.writeHead(200, { "content-type": types[extname(file)] ?? "application/octet-stream", "cache-control": "no-store" });
        response.end(body);
    } catch {
        response.writeHead(404);
        response.end();
    }
});

async function sendReference(url, response) {
    const fair = url.searchParams.get("fair") ?? "";
    const headers = { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" };
    if (!/^[1-9]\d*$/.test(fair)) {
        response.writeHead(200, headers);
        response.end(JSON.stringify({ available: false, line: unavailableLine() }));
        return;
    }
    try {
        const view = await loadHashKeyReference(fair);
        response.writeHead(200, headers);
        response.end(JSON.stringify({ available: true, source: view.source, price: view.price, gapBps: view.gapBps, line: view.line }));
    } catch {
        response.writeHead(200, headers);
        response.end(JSON.stringify({ available: false, line: unavailableLine() }));
    }
}

server.listen(4173, "127.0.0.1", () => {
    console.log("Desk http://127.0.0.1:4173");
});
