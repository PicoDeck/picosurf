// RSS 2.0 / Atom / RSS 1.0 → a list of dated links (spec 5.7).

import { XMLParser } from "fast-xml-parser";
import { collapse, hostPath } from "./text";

export interface FeedItem { url: string; title: string; time: number | null }
export interface Feed { title: string; items: FeedItem[] }

export const MAX_ITEMS = 50;

const parser = new XMLParser({
  ignoreAttributes: false,
  attributeNamePrefix: "@_",
  textNodeName: "#text",
  parseTagValue: false,
  parseAttributeValue: false,
  trimValues: true,
  processEntities: true,
  htmlEntities: true,
  isArray: (name: string) => name === "item" || name === "entry" || name === "link",
});

// fast-xml-parser returns loosely typed trees; `X` marks those values.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type X = any;

export function parseFeed(xml: string, base: string): Feed | null {
  let doc: X;
  try {
    // Drop the DOCTYPE so no declared entity is ever expanded.
    doc = parser.parse(stripDoctype(xml));
  } catch {
    return null;
  }
  if (doc?.rss?.channel) return rss(doc.rss.channel, base);
  if (doc?.feed) return atom(doc.feed, base);
  const rdf = doc?.["rdf:RDF"];
  if (rdf) return rss({ ...(rdf.channel ?? {}), item: rdf.item }, base);
  return null;
}

/**
 * Removes the first DOCTYPE declaration, internal subset included, in one
 * linear scan (a regex here backtracked quadratically on "<!DOCTYPE [" repeated).
 * An unterminated declaration runs to the end of the input.
 */
function stripDoctype(xml: string): string {
  const start = xml.search(/<!DOCTYPE/i);
  if (start < 0) return xml;
  let end = xml.indexOf(">", start);
  const subset = xml.indexOf("[", start);
  if (subset >= 0 && (end < 0 || subset < end)) {
    const close = xml.indexOf("]", subset);
    end = close < 0 ? -1 : xml.indexOf(">", close);
  }
  return end < 0 ? xml.slice(0, start) : xml.slice(0, start) + xml.slice(end + 1);
}

function rss(channel: X, base: string): Feed {
  const items = asArray(channel.item).map((it: X) => ({
    url: resolve(textOf(it.link) || permalink(it.guid), base),
    title: cleanTitle(textOf(it.title)),
    time: parseDate(textOf(it.pubDate) || textOf(it["dc:date"])),
  }));
  return finish(cleanTitle(textOf(channel.title)) || hostPath(base), items);
}

function atom(feed: X, base: string): Feed {
  const items = asArray(feed.entry).map((e: X) => ({
    url: resolve(atomLink(e.link), base),
    title: cleanTitle(textOf(e.title)),
    time: parseDate(textOf(e.published) || textOf(e.updated)),
  }));
  return finish(cleanTitle(textOf(feed.title)) || hostPath(base), items);
}

function atomLink(links: X): string {
  const list = asArray(links);
  const rel = (l: X) => (typeof l === "object" && l["@_rel"]) || "alternate";
  const type = (l: X) => (typeof l === "object" && l["@_type"]) || "";
  const pick =
    list.find((l: X) => rel(l) === "alternate" && (!type(l) || /html/.test(type(l)))) ??
    list.find((l: X) => rel(l) === "alternate") ??
    list[0];
  if (pick === undefined) return "";
  return typeof pick === "object" ? (pick["@_href"] ?? textOf(pick)) : String(pick);
}

function permalink(guid: X): string {
  if (guid === undefined) return "";
  if (typeof guid === "object" && guid["@_isPermaLink"] === "false") return "";
  const value = textOf(guid);
  return /^https?:\/\//i.test(value) ? value : "";
}

function finish(title: string, raw: FeedItem[]): Feed {
  const items = raw.filter((i) => i.url !== "").map((i) => ({ ...i, title: i.title || "(untitled)" }));
  const dated = items.filter((i) => i.time !== null).sort((a, b) => b.time! - a.time!);
  const undated = items.filter((i) => i.time === null);
  return { title, items: [...dated, ...undated].slice(0, MAX_ITEMS) };
}

function asArray(v: X): X[] {
  return v === undefined || v === null ? [] : Array.isArray(v) ? v : [v];
}

function textOf(v: X): string {
  if (v === undefined || v === null) return "";
  if (typeof v === "string" || typeof v === "number") return String(v);
  if (Array.isArray(v)) return textOf(v[0]);
  if (typeof v === "object" && "#text" in v) return String(v["#text"]);
  return "";
}

const NAMED_ENTITIES: Record<string, string> = {
  amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " ",
  mdash: "—", ndash: "–", hellip: "…", lsquo: "‘", rsquo: "’", ldquo: "“", rdquo: "”",
};

/** Decodes HTML entities left in titles (CDATA sections and double-escaped feeds keep them). */
function decodeEntities(s: string): string {
  return s.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (whole, e: string) => {
    if (e[0] === "#") {
      const cp = e[1] === "x" || e[1] === "X" ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10);
      return cp > 0 && cp <= 0x10ffff ? String.fromCodePoint(cp) : whole;
    }
    const name = e.toLowerCase();
    return Object.hasOwn(NAMED_ENTITIES, name) ? NAMED_ENTITIES[name] : whole; // not &constructor;
  });
}

/** Strips markup that HTML-typed titles carry, decodes entities, collapses whitespace. */
function cleanTitle(s: string): string {
  // [^<>] rather than [^>]: a run of "<" without ">" would otherwise backtrack quadratically.
  return collapse(decodeEntities(s.replace(/<[^<>]*>/g, " ")));
}

function parseDate(s: string): number | null {
  if (!s) return null;
  const t = Date.parse(s.trim());
  return Number.isNaN(t) ? null : t;
}

function resolve(link: string, base: string): string {
  if (!link.trim()) return "";
  try {
    const u = new URL(link.trim(), base);
    u.hash = "";
    return u.href;
  } catch {
    return "";
  }
}

export function feedToGemtext(feed: Feed): string {
  const lines = [`# ${feed.title}`, ""];
  for (const item of feed.items) {
    const date = item.time === null ? "" : new Date(item.time).toISOString().slice(0, 10) + " ";
    lines.push(`=> ${item.url} ${date}${item.title}`);
  }
  return lines.join("\n") + "\n";
}

/** Feed links longer than this are skipped. */
const MAX_FEED_URL = 2048;

/** The first <link rel="alternate"> to an http(s) RSS or Atom feed, resolved against `base`. */
export function findFeedLink(doc: Document, base: string): string | null {
  for (const el of Array.from(doc.querySelectorAll("link[rel][href]"))) {
    const rel = (el.getAttribute("rel") ?? "").toLowerCase().split(/\s+/);
    const type = (el.getAttribute("type") ?? "").toLowerCase();
    if (!rel.includes("alternate") || (type !== "application/rss+xml" && type !== "application/atom+xml")) continue;
    const href = resolve(el.getAttribute("href") ?? "", base);
    if (/^https?:/i.test(href) && href.length <= MAX_FEED_URL) return href;
  }
  return null;
}
