import http from "node:http";
import { Agent, fetch as undiciFetch } from "undici";
import { type Deps, type Env, handleRequest } from "./handler";
import { createSharpResizer } from "./img-sharp";
import { type Resolver, guardedLookup } from "./lookup";

/** Node platform pieces: undici fetch whose DNS lookup refuses private addresses, and sharp. */
export function nodeDeps(resolve?: Resolver): Deps {
  const agent = new Agent({ connect: { lookup: guardedLookup(resolve) as never } });
  return {
    fetch: (url, init) =>
      undiciFetch(url, { ...init, dispatcher: agent } as Parameters<typeof undiciFetch>[1]) as unknown as Promise<Response>,
    resizer: createSharpResizer(),
  };
}

const HOP_BY_HOP = new Set(["host", "connection", "keep-alive", "transfer-encoding", "upgrade"]);

export function createServer(env: Env, deps: Deps): http.Server {
  return http.createServer(async (req, res) => {
    try {
      const headers = new Headers();
      for (const [name, value] of Object.entries(req.headers)) {
        if (HOP_BY_HOP.has(name) || value === undefined) continue;
        for (const v of Array.isArray(value) ? value : [value]) headers.append(name, v);
      }
      const request = new Request(`http://${req.headers.host ?? "localhost"}${req.url ?? "/"}`, { method: req.method, headers });
      const response = await handleRequest(request, env, deps);
      res.writeHead(response.status, Object.fromEntries(response.headers));
      res.end(Buffer.from(await response.arrayBuffer()));
    } catch (e) {
      console.error(e);
      res.writeHead(500, { "Content-Type": "text/plain; charset=us-ascii" });
      res.end("Internal error\n");
    }
  });
}
