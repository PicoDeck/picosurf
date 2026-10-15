// Fetches real sites through the handler in-process and reports what came back
// (spec 7.1). Nothing is saved. Usage: npm run smoke [urls.txt]
// A line in urls.txt is a URL, or "feed <URL>" to fetch it with as=feed.
import { readFileSync } from "node:fs";
import { handleRequest } from "../src/handler";
import { nodeDeps } from "../src/node";

const DEFAULT = [
  "https://news.ycombinator.com/",
  "https://lobste.rs/",
  "https://www.bbc.com/news",
  "https://arstechnica.com/",
  "https://jvns.ca/",
  "https://github.com/PicoDeck/picodeck",
  "https://en.wikipedia.org/wiki/Special:Random",
  "feed https://hnrss.org/frontpage",
  "feed https://lobste.rs/rss",
  "feed https://jvns.ca/atom.xml",
  "feed https://feeds.bbci.co.uk/news/rss.xml",
];

const lines = process.argv[2] ? readFileSync(process.argv[2], "utf8").split("\n") : DEFAULT;
const deps = nodeDeps();
const env = { PROXY_TOKEN: "smoke" };

console.log(["status", "mode", "KB", "links", "wall ms", "cpu ms", "url"].join("\t"));
for (const line of lines.map((l) => l.trim()).filter(Boolean)) {
  const [as, url] = line.startsWith("feed ") ? ["feed", line.slice(5).trim()] : ["reader", line];
  const started = performance.now();
  const cpu = process.cpuUsage();
  const res = await handleRequest(
    new Request(`http://smoke/v1/get?url=${encodeURIComponent(url)}&as=${as}`, { headers: { Authorization: "Bearer smoke" } }),
    env,
    deps,
  );
  const body = await res.text();
  const used = process.cpuUsage(cpu);
  const links = body.split("\n").filter((l) => l.startsWith("=> ")).length;
  const mode = res.headers.get("X-Mode") ?? (res.ok ? "-" : body.trim());
  console.log(
    [res.status, mode, (body.length / 1024).toFixed(1), links, Math.round(performance.now() - started), Math.round((used.user + used.system) / 1000), url].join("\t"),
  );
}
