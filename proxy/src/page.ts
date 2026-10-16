// HTML page → gemtext with a header: reader mode via Readability, falling back
// to the whole page (spec 5.5). Output is not ASCII-folded; the handler does that.

import { Readability } from "@mozilla/readability";
import { parseHTML } from "linkedom";
import { findFeedLink } from "./feed";
import { escapeLine, toGemtext } from "./html2gmi";
import { collapse, hostPath } from "./text";

export type PageMode = "reader" | "full";
export interface Page {
  title: string;
  mode: PageMode;
  gemtext: string;
  feedUrl: string | null;
  /** Reader mode only: the share of the page's visible text that the article covers, when it was measured. */
  coverage: number | null;
}

/** Below this much article text, reader mode gives way to the full page. */
export const MIN_ARTICLE_CHARS = 500;
/** An article at least this long stays in reader mode whatever share of the page it covers (Ruling 11). */
export const LONG_ARTICLE_CHARS = 3000;
/** A shorter article must cover at least this share of the page's visible text (Ruling 11). */
export const MIN_COVERAGE = 0.25;
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
  // The full-mode body, junk removed: built at most once, for the coverage check or the fallback.
  let fullRoot: Element | null | undefined;
  const full = () => (fullRoot === undefined ? (fullRoot = junkFreeBody(readable ? parse(html) : doc)) : fullRoot); // Readability mutates `doc`

  if (readable) {
    let article: ReturnType<Readability["parse"]> = null;
    try {
      prepareForReader(doc);
      article = new Readability(doc, { keepClasses: true }).parse();
    } catch {
      /* junk HTML: fall through to the full page */
    }
    const chars = collapse(article?.textContent ?? "").length;
    if (article?.content && chars >= MIN_ARTICLE_CHARS) {
      const coverage = chars >= LONG_ARTICLE_CHARS ? null : coverageOf(chars, full());
      if (coverage === null || coverage >= MIN_COVERAGE) {
        const title = collapse(article.title ?? "") || docTitle || hostPath(finalUrl);
        const body = parse(`<!doctype html><html><body>${article.content}</body></html>`).body;
        const byline = [article.siteName, article.byline, isoDate(article.publishedTime)]
          .map((s) => collapse(s ?? ""))
          .filter(Boolean)
          .join(" - ");
        const gemtext = header(title, byline) + toGemtext(body, { base, dropHeading: title });
        return { title, mode: "reader", feedUrl, coverage, gemtext };
      }
    }
  }

  const title = docTitle || hostPath(finalUrl);
  const root = full();
  if (!root) return { title, mode: "full", feedUrl, coverage: null, gemtext: header(title, "") };
  return { title, mode: "full", feedUrl, coverage: null, gemtext: header(title, "") + toGemtext(root, { base, dropHeading: title }) };
}

/** The body of a full-mode parse with junk elements removed; null for junk input. */
function junkFreeBody(doc: Document): Element | null {
  // linkedom's `body` getter throws when there is no documentElement (junk input).
  const root = doc.documentElement ? (doc.body ?? doc.documentElement) : null;
  if (root) for (const el of Array.from(doc.querySelectorAll(JUNK))) el.remove();
  return root;
}

/** The share of the page's visible text (`root`'s collapsed text) that `chars` characters of article cover. */
function coverageOf(chars: number, root: Element | null): number {
  const visible = root ? collapse(root.textContent ?? "").length : 0;
  return visible > 0 ? chars / visible : 1;
}

export function discoverFeed(html: string, finalUrl: string): string | null {
  const doc = parse(html);
  return findFeedLink(doc, baseOf(doc, finalUrl));
}

/** The pre-pass over the document before Readability parses it. Exported for tests. */
export function prepareForReader(doc: Document): void {
  hoistHeadings(doc);
  defuseBylines(doc);
}

/** Readability's byline pattern, matched against an element's class and id. */
const BYLINE_LIKE = /byline|author|dateline|writtenby|p-author/i;

/**
 * Readability takes a short element whose class or id matches BYLINE_LIKE as
 * the byline and deletes it from the article. MDN's
 * <dt id="203_non-authoritative_information"> matched, so the term left the
 * body and became the byline. Headings, terms and table headers are never
 * bylines, so such ids and classes are removed from them.
 */
function defuseBylines(doc: Document): void {
  for (const el of Array.from(doc.querySelectorAll("h1, h2, h3, h4, h5, h6, dt, th"))) {
    for (const attr of ["id", "class"]) {
      if (BYLINE_LIKE.test(el.getAttribute(attr) ?? "")) el.removeAttribute(attr);
    }
  }
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
  return `# ${title}\n` + (byline ? `${escapeLine(byline)}\n` : "") + "\n";
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
