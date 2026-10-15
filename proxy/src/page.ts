// HTML page → gemtext with a header: reader mode via Readability, falling back
// to the whole page (spec 5.5). Output is not ASCII-folded; the handler does that.

import { Readability } from "@mozilla/readability";
import { parseHTML } from "linkedom";
import { findFeedLink } from "./feed";
import { toGemtext } from "./html2gmi";
import { collapse, hostPath } from "./text";

export type PageMode = "reader" | "full";
export interface Page { title: string; mode: PageMode; gemtext: string; feedUrl: string | null }

/** Below this much article text, reader mode gives way to the full page. */
export const MIN_ARTICLE_CHARS = 500;
/** Pages with elements nested deeper than this go straight to the full page. */
export const MAX_READER_DEPTH = 300;
const JUNK = "script, style, noscript, svg, template, iframe, canvas, video, audio, [hidden], [aria-hidden=true]";

const parse = (html: string) => parseHTML(html).document as unknown as Document;

export function renderPage(html: string, finalUrl: string, want: PageMode): Page {
  const doc = parse(html);
  const base = baseOf(doc, finalUrl);
  const feedUrl = findFeedLink(doc, base);
  const docTitle = titleOf(doc);

  // Readability is super-linear in nesting depth (and recurses), so deep pages skip it.
  const readable = want === "reader" && doc.documentElement !== null && !deeperThan(doc.documentElement, MAX_READER_DEPTH);
  if (readable) {
    let article: ReturnType<Readability["parse"]> = null;
    try {
      prepareForReader(doc);
      article = new Readability(doc, { keepClasses: true }).parse();
    } catch {
      /* junk HTML: fall through to the full page */
    }
    if (article?.content && collapse(article.textContent ?? "").length >= MIN_ARTICLE_CHARS) {
      const title = collapse(article.title ?? "") || docTitle || hostPath(finalUrl);
      const body = parse(`<!doctype html><html><body>${article.content}</body></html>`).body;
      const byline = [article.siteName, article.byline, isoDate(article.publishedTime)]
        .map((s) => collapse(s ?? ""))
        .filter(Boolean)
        .join(" - ");
      return { title, mode: "reader", feedUrl, gemtext: header(title, byline) + toGemtext(body, { base, dropHeading: title }) };
    }
  }

  const full = readable ? parse(html) : doc; // Readability mutated `doc`
  const title = docTitle || hostPath(finalUrl);
  // linkedom's `body` getter throws when there is no documentElement (junk input).
  const root = full.documentElement ? (full.body ?? full.documentElement) : null;
  if (!root) return { title, mode: "full", feedUrl, gemtext: header(title, "") };
  for (const el of Array.from(full.querySelectorAll(JUNK))) el.remove();
  return { title, mode: "full", feedUrl, gemtext: header(title, "") + toGemtext(root, { base, dropHeading: title }) };
}

export function discoverFeed(html: string, finalUrl: string): string | null {
  const doc = parse(html);
  return findFeedLink(doc, baseOf(doc, finalUrl));
}

/** The pre-pass over the document before Readability parses it. Exported for tests. */
export function prepareForReader(doc: Document): void {
  hoistHeadings(doc);
}

/**
 * Readability's conditional cleaning deletes short wrapper divs that hold a
 * heading plus a link (Wikipedia's `div.mw-heading` with its "[edit]" link),
 * taking the section heading with them. Replace such wrappers by the heading,
 * but only when everything else in the wrapper is chrome (edit/anchor affordances).
 */
const CHROME_TAGS = new Set(["A", "SPAN", "BUTTON", "SUP", "SVG"]);
const CHROME_TEXT = /^(\[?(edit|edit source|#|¶|§)\]?|section titled\b.*)$/i; // last: Starlight anchor-link text

function isChrome(n: Node): boolean {
  if (n.nodeType === 3) return collapse(n.textContent ?? "") === "";
  if (n.nodeType !== 1) return n.nodeType === 8; // comments are harmless
  const el = n as Element;
  if (!CHROME_TAGS.has(el.tagName.toUpperCase())) return false;
  const text = collapse(el.textContent ?? "");
  return text === "" || CHROME_TEXT.test(text.replace(/\s+/g, " "));
}

function hoistHeadings(doc: Document): void {
  for (const h of Array.from(doc.querySelectorAll("h1, h2, h3, h4, h5, h6"))) {
    const wrap = h.parentElement;
    if (wrap?.tagName !== "DIV" || !wrap.parentElement) continue;
    if (onlyHeadingAndChrome(wrap, h)) wrap.replaceWith(h);
  }
}

/** Wrappers with more child nodes than this are never hoisted. */
const MAX_WRAPPER_NODES = 8;

/**
 * True when `wrap` has at most MAX_WRAPPER_NODES child nodes, each of them `h`
 * or chrome. Counting first keeps the check O(1) for a wrapper with thousands
 * of headings, whatever the cost of isChrome on its first child.
 */
function onlyHeadingAndChrome(wrap: Element, h: Element): boolean {
  let count = 0;
  for (let n = wrap.firstChild; n; n = n.nextSibling) if (++count > MAX_WRAPPER_NODES) return false;
  for (let n = wrap.firstChild; n; n = n.nextSibling) if (n !== h && !isChrome(n)) return false;
  return true;
}

/** True when some element under `root` is nested more than `limit` deep. Iterative, so it cannot overflow the stack. */
function deeperThan(root: Element, limit: number): boolean {
  const stack: [Element, number][] = [[root, 1]];
  while (stack.length > 0) {
    const [el, depth] = stack.pop()!;
    if (depth > limit) return true;
    for (const child of Array.from(el.children)) stack.push([child, depth + 1]);
  }
  return false;
}

function header(title: string, byline: string): string {
  return `# ${title}\n` + (byline ? `${byline}\n` : "") + "\n";
}

function baseOf(doc: Document, finalUrl: string): string {
  const href = doc.querySelector("base[href]")?.getAttribute("href");
  if (href) {
    try {
      return new URL(href, finalUrl).href;
    } catch {
      /* fall through to the page URL */
    }
  }
  return finalUrl;
}

function titleOf(doc: Document): string {
  return (
    collapse(doc.querySelector("title")?.textContent ?? "") ||
    collapse(doc.querySelector('meta[property="og:title"]')?.getAttribute("content") ?? "")
  );
}

function isoDate(s: string | null | undefined): string {
  if (!s) return "";
  const t = Date.parse(s);
  return Number.isNaN(t) ? "" : new Date(t).toISOString().slice(0, 10);
}
