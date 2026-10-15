import { createServer, nodeDeps } from "./node";

const port = Number(process.env.PORT ?? 8080);
const env = { PROXY_TOKEN: process.env.PROXY_TOKEN, USER_AGENT: process.env.USER_AGENT };
if (!env.PROXY_TOKEN) console.warn("PROXY_TOKEN is not set: every request will get 500");
const server = createServer(env, nodeDeps()).listen(port, () => console.log(`picosurf-proxy listening on :${port}`));

// `docker stop` sends SIGTERM and Ctrl-C sends SIGINT. As PID 1 in a container,
// node would otherwise ignore SIGTERM until Docker kills it 10 s later.
for (const signal of ["SIGTERM", "SIGINT"] as const) {
  process.on(signal, () => server.close(() => process.exit(0)));
}
