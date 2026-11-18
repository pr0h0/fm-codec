const roots: Record<string,string> = { "/bpl/": process.env.BPLDIR!, "/data/": process.env.DATADIR! };
Bun.serve({ port: 8765, hostname: "127.0.0.1", fetch(req) {
  const p = new URL(req.url).pathname;
  if (p === "/") return new Response(Bun.file(process.env.PAGE!));
  for (const [k, d] of Object.entries(roots)) if (p.startsWith(k) && !p.includes("..")) {
    const f = Bun.file(d + "/" + p.slice(k.length));
    const type = p.endsWith(".mjs") ? "text/javascript" : p.endsWith(".wasm") ? "application/wasm" : p.endsWith(".html") ? "text/html" : "application/octet-stream";
    return new Response(f, { headers: { "content-type": type } });
  }
  return new Response("nf", { status: 404 });
}});
