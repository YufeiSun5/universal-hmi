// Isolated loopback-only static fixture. No business APIs or credentials.
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { resolve, extname, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
const root = resolve(fileURLToPath(new URL('.', import.meta.url)), 'dist');
const flutterRoot = resolve(root, '../../../.local/fortune-flutter-probe/web');
const types = { '.html':'text/html; charset=utf-8', '.js':'text/javascript', '.css':'text/css', '.json':'application/json', '.wasm':'application/wasm', '.png':'image/png', '.otf':'font/otf', '.ttf':'font/ttf' };
createServer(async (req, res) => {
  try {
    let pathname = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
    const isFlutter = pathname.startsWith('/flutter/');
    const base = isFlutter ? flutterRoot : root;
    if (isFlutter) pathname = pathname.slice('/flutter'.length);
    if (pathname.endsWith('/')) pathname += 'index.html';
    const target = resolve(base, '.' + pathname);
    if (!target.startsWith(base + sep)) { res.writeHead(403).end(); return; }
    const content = await readFile(target);
    res.writeHead(200, { 'Content-Type': types[extname(target)] || 'application/octet-stream', 'Cache-Control':'no-store' });
    res.end(content);
  } catch { res.writeHead(404).end('Not found'); }
}).listen(19275, '127.0.0.1', () => console.log('Probe: http://127.0.0.1:19275/flutter/'));
