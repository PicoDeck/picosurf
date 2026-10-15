import { createServer, nodeDeps } from "./node";

const port = Number(process.env.PORT ?? 8080);
const env = { PROXY_TOKEN: process.env.PROXY_TOKEN, USER_AGENT: process.env.USER_AGENT };
if (!env.PROXY_TOKEN) console.warn("PROXY_TOKEN is not set: every request will get 500");
createServer(env, nodeDeps()).listen(port, () => console.log(`picosurf-proxy listening on :${port}`));
