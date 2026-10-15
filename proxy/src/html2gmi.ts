// DOM → gemtext (spec 5.5). Works on linkedom documents. Output is not
// ASCII-folded; the handler folds everything once on the way out.

import { collapse, hostPath } from "./text";

export interface ConvertOptions {
  /** Absolute URL that relative links resolve against. */
  base: string;
  /** The first heading whose text equals this (ignoring case) is dropped: it repeats the page title. */
  dropHeading?: string;
}

type Kind = "heading" | "para" | "item" | "quote" | "pre" | "table" | "link" | "image";
interface Block { kind: Kind; lines: string[]; group: number }
interface LinkRef { url: string; label: string }
interface Image { src: string; alt: string; href: string | null }
interface Inline { parts: Array<string | LinkRef>; images: Image[]; bare: LinkRef[] }

const ELEMENT = 1;
const TEXT = 3;
/** Marks a <br> in collected text: private use, so whitespace collapsing keeps it. */
const BR = "";
/** Consecutive blocks of these kinds in the same group get no blank line between them. */
const NO_GAP = new Set<Kind>(["item", "link", "quote", "image"]);
const SKIP = new Set([
  "script", "style", "noscript", "svg", "template", "iframe", "canvas", "video", "audio", "object", "embed",
  "form", "button", "input", "select", "textarea", "hr", "map", "head", "title", "meta", "link",
]);
const BLOCK = new Set([
  "address", "article", "aside", "blockquote", "body", "caption", "center", "dd", "details", "dialog", "div", "dl", "dt",
  "fieldset", "figcaption", "figure", "footer", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hgroup", "html", "li",
  "main", "menu", "nav", "ol", "p", "pre", "section", "summary", "table", "tbody", "td", "tfoot", "th", "thead", "tr", "ul",
]);
/** Children of <li> that stay their own blocks after the item instead of joining its text. */
const STRUCTURAL = new Set(["ul", "ol", "menu", "pre", "table", "blockquote"]);
const DROPPED_SCHEMES = /^(javascript|mailto|tel|sms|data):/i;
const GEMTEXT_PREFIX = /^(=>|#|\* |>|```)/;

export function toGemtext(root: Element, opts: ConvertOptions): string {
  const converter = new Converter(opts);
  converter.container(root, false);
  return converter.render();
}

const tagOf = (el: Element) => el.tagName.toLowerCase();
const isElement = (n: Node): n is Element => n.nodeType === ELEMENT;
const isRef = (p: string | LinkRef): p is LinkRef => typeof p !== "string";
const emptyInline = (): Inline => ({ parts: [], images: [], bare: [] });

function isHidden(el: Element): boolean {
  return (
    el.hasAttribute("hidden") ||
    el.getAttribute("aria-hidden") === "true" ||
    /display\s*:\s*none/i.test(el.getAttribute("style") ?? "")
  );
}

const skipped = (el: Element) => SKIP.has(tagOf(el)) || isHidden(el);

function plainOf(inl: Inline): string {
  return collapse(inl.parts.map((p) => (typeof p === "string" ? p : p.label)).join("").split(BR).join(" "));
}

/** Picks the srcset candidate whose width is nearest `target`, else the 1x one, else the first. */
export function pickFromSrcset(srcset: string, target = 640): string | null {
  const candidates = srcset
    .split(/,\s+|(?<=\d[wx]),/)
    .map((s) => s.trim().split(/\s+/))
    .filter((p) => p[0])
    .map(([url, d = ""]) => ({ url, w: d.endsWith("w") ? parseInt(d, 10) : null, x: d.endsWith("x") ? parseFloat(d) : 1 }));
  const widths = candidates.filter((c) => c.w !== null);
  if (widths.length) return widths.reduce((a, b) => (Math.abs(b.w! - target) < Math.abs(a.w! - target) ? b : a)).url;
  return (candidates.find((c) => c.x === 1) ?? candidates[0])?.url ?? null;
}

function pickSrc(el: Element): string | null {
  const srcset = el.getAttribute("srcset") ?? el.getAttribute("data-srcset");
  if (srcset) {
    const best = pickFromSrcset(srcset);
    if (best) return best;
  }
  for (const attr of ["src", "data-src", "data-lazy-src", "data-original"]) {
    const value = el.getAttribute(attr)?.trim();
    if (value && !value.startsWith("data:")) return value;
  }
  return null;
}

class Converter {
  private blocks: Block[] = [];
  private numbers = new Map<string, number>();
  private nextNumber = 1;
  private dropHeading: string | null;
  private listDepth = 0;
  private listGroup = 0;

  constructor(private readonly opts: ConvertOptions) {
    this.dropHeading = opts.dropHeading ? collapse(opts.dropHeading).toLowerCase() : null;
  }

  render(): string {
    const out: string[] = [];
    let prev: Block | null = null;
    for (const b of this.blocks) {
      if (prev && !(prev.kind === b.kind && prev.group === b.group && NO_GAP.has(b.kind))) out.push("");
      out.push(...b.lines);
      prev = b;
    }
    return out.length ? out.join("\n") + "\n" : "";
  }

  /** Walks a block container: runs of inline nodes become paragraphs (or quote lines). */
  container(el: Element, quote: boolean): void {
    let run: Node[] = [];
    const flush = () => {
      if (run.length) this.add(this.lines(quote ? "quote" : "para", "", this.inline(run)));
      run = [];
    };
    for (const node of Array.from(el.childNodes)) {
      if (node.nodeType === TEXT) {
        run.push(node);
        continue;
      }
      if (!isElement(node) || skipped(node)) continue;
      if (!BLOCK.has(tagOf(node))) {
        run.push(node);
        continue;
      }
      flush();
      this.block(node, quote);
    }
    flush();
  }

  private block(el: Element, quote: boolean): void {
    const tag = tagOf(el);
    if (/^h[1-6]$/.test(tag)) return this.heading(el, Number(tag[1]));
    if (tag === "ul" || tag === "menu") return this.list(el, false);
    if (tag === "ol") return this.list(el, true);
    if (tag === "blockquote") return this.container(el, true);
    if (tag === "pre") return this.pre(el);
    if (tag === "table") return this.table(el);
    this.container(el, quote);
  }

  private heading(el: Element, level: number): void {
    const inl = this.inline(Array.from(el.childNodes));
    if (this.dropHeading !== null && plainOf(inl).toLowerCase() === this.dropHeading) {
      this.dropHeading = null;
      return;
    }
    this.add(this.lines("heading", "#".repeat(Math.min(level, 3)) + " ", inl));
  }

  private list(el: Element, ordered: boolean): void {
    if (this.listDepth === 0) this.listGroup++;
    this.listDepth++;
    let n = ordered ? (parseInt(el.getAttribute("start") ?? "1", 10) || 1) - 1 : 0;
    for (const child of Array.from(el.children)) {
      if (skipped(child)) continue;
      if (tagOf(child) !== "li") {
        this.block(child, false);
        continue;
      }
      n++;
      const textNodes: Node[] = [];
      const nested: Element[] = [];
      for (const node of Array.from(child.childNodes)) {
        if (isElement(node) && STRUCTURAL.has(tagOf(node))) {
          if (!skipped(node)) nested.push(node);
        } else {
          textNodes.push(node);
        }
      }
      this.add(this.lines("item", ordered ? `* ${n}. ` : "* ", this.inline(textNodes)));
      for (const el2 of nested) this.block(el2, false);
    }
    this.listDepth--;
  }

  private pre(el: Element): void {
    const code = el.querySelector("code");
    const classes = `${el.getAttribute("class") ?? ""} ${code?.getAttribute("class") ?? ""}`;
    const lang = /(?:^|\s)(?:language|lang)-([\w+#.-]+)/.exec(classes)?.[1] ?? "";
    const lines = (el.textContent ?? "")
      .replace(/\r\n?/g, "\n")
      .replace(/\t/g, "    ")
      .split("\n")
      .map((l) => l.replace(/\s+$/, ""));
    while (lines.length && lines[0] === "") lines.shift();
    while (lines.length && lines[lines.length - 1] === "") lines.pop();
    if (!lines.length) return;
    this.add({ kind: "pre", lines: ["```" + lang, ...lines.map((l) => (l.startsWith("```") ? " " + l : l)), "```"] });
  }

  private table(el: Element): void {
    if (el.querySelector("table")) return this.container(el, false); // a layout table
    const caption = el.querySelector("caption");
    if (caption) this.add(this.lines("para", "", this.inline(Array.from(caption.childNodes))));
    const lines: string[] = [];
    for (const tr of Array.from(el.querySelectorAll("tr"))) {
      const inl = emptyInline();
      const cells = Array.from(tr.children).filter((c) => /^t[hd]$/.test(tagOf(c)) && !skipped(c));
      cells.forEach((cell, i) => {
        if (i > 0) inl.parts.push(" | ");
        this.inline(Array.from(cell.childNodes), inl);
      });
      const row = this.lines("para", "", inl);
      if (row) lines.push(...row.lines);
    }
    if (lines.length) this.add({ kind: "table", lines });
  }

  /** Collects inline content: text, links (as LinkRefs), images and <br> markers. */
  private inline(nodes: Node[], into: Inline = emptyInline(), href: string | null = null): Inline {
    for (const node of nodes) {
      if (node.nodeType === TEXT) {
        into.parts.push(node.textContent ?? "");
        continue;
      }
      if (!isElement(node) || skipped(node)) continue;
      const tag = tagOf(node);
      if (tag === "br") into.parts.push(BR);
      else if (tag === "img") {
        const img = this.image(node, href);
        if (img) into.images.push(img);
      } else if (tag === "code" && href === null) into.parts.push("`" + collapse(node.textContent ?? "") + "`");
      else if (tag === "a" && href === null) this.anchor(node, into);
      else {
        const block = BLOCK.has(tag);
        if (block) into.parts.push(" ");
        this.inline(Array.from(node.childNodes), into, href);
        if (block) into.parts.push(" ");
      }
    }
    return into;
  }

  private anchor(a: Element, into: Inline): void {
    const url = this.resolveLink(a.getAttribute("href"));
    if (url === null) {
      this.inline(Array.from(a.childNodes), into);
      return;
    }
    const inner = this.inline(Array.from(a.childNodes), emptyInline(), url);
    into.images.push(...inner.images);
    const label = plainOf(inner);
    if (label) into.parts.push({ url, label });
    else if (inner.images.length === 0) {
      const named = collapse(a.getAttribute("aria-label") || a.getAttribute("title") || "");
      into.bare.push({ url, label: named || hostPath(url) });
    }
  }

  private image(el: Element, href: string | null): Image | null {
    const raw = pickSrc(el);
    const src = raw === null ? null : this.resolve(raw);
    if (src === null || !/^https?:/i.test(src)) return null;
    return { src, alt: collapse(el.getAttribute("alt") ?? ""), href };
  }

  private resolveLink(href: string | null): string | null {
    const h = href?.trim() ?? "";
    if (h === "" || h.startsWith("#") || DROPPED_SCHEMES.test(h)) return null;
    return this.resolve(h);
  }

  private resolve(href: string): string | null {
    try {
      const u = new URL(href, this.opts.base);
      u.hash = "";
      return u.href;
    } catch {
      return null;
    }
  }

  private numberFor(url: string): number {
    let n = this.numbers.get(url);
    if (n === undefined) {
      n = this.nextNumber++;
      this.numbers.set(url, n);
    }
    return n;
  }

  /** Renders collected inline content as a block: text line(s), link lines, then image lines. */
  private lines(kind: Kind, marker: string, inl: Inline): { kind: Kind; lines: string[] } | null {
    const out: string[] = [];
    const plain = plainOf(inl);
    const refs = inl.parts.filter(isRef);
    let outKind = kind;
    if (refs.length === 1 && plain === refs[0].label) {
      out.push(`=> ${refs[0].url} ${refs[0].label}`);
      outKind = "link";
    } else if (plain !== "") {
      const used = new Map<string, { n: number; label: string }>();
      const marked = inl.parts
        .map((p) => {
          if (typeof p === "string") return p;
          const n = this.numberFor(p.url);
          if (!used.has(p.url)) used.set(p.url, { n, label: p.label });
          return `${p.label} [${n}]`;
        })
        .join("");
      const text = marked.split(BR).map(collapse).filter(Boolean);
      if (kind === "para") out.push(...text.map((l) => (GEMTEXT_PREFIX.test(l) ? " " + l : l)));
      else if (kind === "quote") out.push(...text.map((l) => `> ${l}`));
      else out.push(marker + text.join(" "));
      for (const [url, { n, label }] of used) out.push(`=> ${url} [${n}] ${label}`);
    }
    for (const b of inl.bare) out.push(`=> ${b.url} ${b.label}`);
    for (const img of inl.images) {
      out.push(`=> ${img.src} [IMG] ${img.alt || "image"}`);
      if (img.href && img.href !== img.src) out.push(`=> ${img.href} ${img.alt || hostPath(img.href)}`);
    }
    if (out.length === 0) return null;
    if (plain === "" && inl.bare.length === 0) outKind = "image";
    return { kind: outKind, lines: out };
  }

  private add(b: { kind: Kind; lines: string[] } | null): void {
    if (b) this.blocks.push({ ...b, group: this.listDepth > 0 ? this.listGroup : 0 });
  }
}
