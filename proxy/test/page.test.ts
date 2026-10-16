import { readFileSync } from "node:fs";
import { parseHTML } from "linkedom";
import { describe, expect, it } from "vitest";
import { ProxyError } from "../src/errors";
import { LONG_ARTICLE_CHARS, MAX_ELEMENTS, MIN_COVERAGE, type Page, discoverFeed, prepareForReader, renderPage } from "../src/page";
import { articleHtml } from "./helpers/pages";
import { HOSTILE_BYTES, msToRun } from "./helpers/timing";

const URL_ = "https://example.com/dir/page.html";

describe("renderPage", () => {
  it("uses reader mode for an article: header with byline, nav and footer gone, title heading not repeated", () => {
    const page = renderPage(articleHtml(), URL_, "reader");
    expect(page.mode).toBe("reader");
    expect(page.title).toBe("Test Article");
    expect(page.feedUrl).toBe("https://example.com/feed.xml");
    expect(page.gemtext.startsWith("# Test Article\nExample Site - Jane Doe - 2026-10-12\n\n")).toBe(true);
    expect(page.gemtext.split("# Test Article").length - 1).toBe(1);
    expect(page.gemtext).toContain("See the reference [1] for details.");
    expect(page.gemtext).toContain("=> https://example.com/ref [1] reference");
    expect(page.gemtext).not.toContain("Copyright footer");
    expect(page.gemtext).not.toContain("https://example.com/about");
  });

  it("falls back to the full page when there is too little article text", () => {
    const html = '<html><head><title>Links</title></head><body><nav><a href="/a">A</a></nav><p>Short.</p></body></html>';
    const page = renderPage(html, URL_, "reader");
    expect(page.mode).toBe("full");
    expect(page.gemtext).toBe("# Links\n\n=> https://example.com/a A\n\nShort.\n");
  });

  it("escapes a byline line that looks like gemtext syntax", () => {
    const html = articleHtml().replace('content="Example Site"', 'content="```Site"');
    expect(renderPage(html, URL_, "reader").gemtext.split("\n")[1]).toBe(" ```Site - Jane Doe - 2026-10-12");
  });

  it("keeps a term whose id looks like a byline in the body, not the byline", () => {
    const lorem = articleHtml().match(/<p>(.*?)<\/p>/)![1];
    const html = `<html><head><title>Glossary</title></head><body><article><h1>Glossary</h1><p>${lorem}</p>
<dl><dt id="author_header">Author header</dt><dd>${lorem}</dd></dl><p>${lorem}</p></article></body></html>`;
    const page = renderPage(html, URL_, "reader");
    expect(page.mode).toBe("reader");
    const lines = page.gemtext.split("\n");
    expect(lines[1]).toBe(""); // no byline line under the title
    expect(lines.slice(2)).toContain("Author header");
  });

  describe("article coverage of the page (Ruling 11)", () => {
    const lorem = articleHtml().match(/<p>(.*?)<\/p>/)![1];
    const headlines = (n: number) =>
      `<ul class="headlines">${Array.from({ length: n }, (_, i) => `<li><a href="/story/${i}">Headline ${i}: an important development in the news today</a></li>`).join("")}</ul>`;

    it("falls back to the full page when a short article is a small part of a front page", () => {
      const html = `<html><head><title>Front</title></head><body><main>${headlines(150)}</main>
<section class="about"><h2>About us</h2><p>${lorem}</p><p>${lorem}</p></section></body></html>`;
      const page = renderPage(html, URL_, "reader");
      expect(page.mode).toBe("full");
      expect(page.coverage).toBeNull();
      expect(page.gemtext).toContain("=> https://example.com/story/149 Headline 149");
    });

    it("measures the coverage of a short article that stays in reader mode", () => {
      const page = renderPage(articleHtml(), URL_, "reader");
      expect(page.mode).toBe("reader");
      expect(page.coverage).toBeGreaterThanOrEqual(MIN_COVERAGE);
    });

    it(`keeps an article of ${LONG_ARTICLE_CHARS} characters or more in reader mode whatever its coverage`, () => {
      const article = `<article><h1>Long</h1>${`<p>${lorem}</p>`.repeat(12)}</article>`;
      const html = `<html><head><title>Long</title></head><body>${article}<aside>${headlines(300)}</aside></body></html>`;
      const page = renderPage(html, URL_, "reader");
      expect(page.mode).toBe("reader");
      expect(page.coverage).toBeNull();
    });
  });

  it("returns the full page, navigation included, when asked", () => {
    const page = renderPage(articleHtml(), URL_, "full");
    expect(page.mode).toBe("full");
    expect(page.gemtext).toContain("=> https://example.com/about About");
    expect(page.gemtext).toContain("Copyright footer text");
  });

  it("resolves links against <base href>", () => {
    const html = '<html><head><base href="https://cdn.example.org/sub/"><title>T</title></head><body><p><a href="x">X</a> text</p></body></html>';
    expect(renderPage(html, URL_, "full").gemtext).toContain("=> https://cdn.example.org/sub/x [1] X");
  });

  it("titles a page from <title>, then og:title, then host and path", () => {
    const og = '<html><head><meta property="og:title" content="OG Title"></head><body><p>x</p></body></html>';
    expect(renderPage(og, URL_, "full").title).toBe("OG Title");
    expect(renderPage("<html><body><p>x</p></body></html>", URL_, "full").title).toBe("example.com/dir/page.html");
  });

  it("keeps a section heading that sits in a short wrapper div with an edit link", () => {
    const lorem = articleHtml().match(/<p>(.*?)<\/p>/)![1];
    const html = `<html><head><title>T</title></head><body><article><h1>T</h1><p>${lorem}</p>
<div class="mw-heading"><h2 id="s">Section One</h2><span class="editsection">[<a href="/edit">edit</a>]</span></div>
<p>${lorem}</p><p>${lorem}</p></article></body></html>`;
    const page = renderPage(html, URL_, "reader");
    expect(page.mode).toBe("reader");
    expect(page.gemtext).toContain("\n## Section One\n");
  });

  describe("heading hoisting keeps wrapper content", () => {
    const lorem = articleHtml().match(/<p>(.*?)<\/p>/)![1];
    const wrap = (inner: string) =>
      `<html><head><title>T</title></head><body><article><h1>T</h1><p>${lorem}</p>${inner}<p>${lorem}</p><p>${lorem}</p></article></body></html>`;

    it("keeps the summary in a card div", () => {
      const page = renderPage(wrap("<div><h3>Card title</h3><p>Short summary of the thing.</p></div>"), URL_, "reader");
      expect(page.mode).toBe("reader");
      expect(page.gemtext).toContain("Card title");
      expect(page.gemtext).toContain("Short summary of the thing.");
    });

    it("keeps the summaries of two cards", () => {
      const card = (n: number) => `<div><h3>Card ${n}</h3><p>Summary number ${n} here.</p></div>`;
      const page = renderPage(wrap(card(1) + card(2)), URL_, "reader");
      expect(page.mode).toBe("reader");
      expect(page.gemtext).toContain("Summary number 1 here.");
      expect(page.gemtext).toContain("Summary number 2 here.");
    });

    it("keeps the text of a callout with a bare text node", () => {
      const page = renderPage(wrap('<div class="note"><h4>Warning</h4>Do not do X.</div>'), URL_, "reader");
      expect(page.mode).toBe("reader");
      expect(page.gemtext).toContain("Do not do X.");
    });
  });

  it.each([["Forbidden"], [""]])("never throws on junk HTML (%j)", (junk) => {
    const page = renderPage(junk, URL_, "reader");
    expect(page.mode).toBe("full");
    expect(page.gemtext.startsWith("# example.com/dir/page.html\n")).toBe(true);
  });

  it("skips reader mode for an article nested more than 300 elements deep", () => {
    const article = articleHtml().match(/<article>[\s\S]*<\/article>/)![0];
    const html = `<html><head><title>Deep</title></head><body>${"<div>".repeat(400)}${article}${"</div>".repeat(400)}</body></html>`;
    const page = renderPage(html, URL_, "reader");
    expect(page.mode).toBe("full");
    expect(page.gemtext).toContain("for details.");
  });
});

describe("hostile input (about 1 MB in under 1 s)", () => {
  // The whole of renderPage on 1 MB of headings takes about 1.7 s, almost all of it
  // linkedom and Readability, so this times the pre-pass that used to be quadratic.
  it("the reader pre-pass on 58,000 headings in one div", () => {
    const unit = "<h2>Heading</h2>\n";
    const html = `<html><head><title>H</title></head><body><div>${unit.repeat(Math.ceil(HOSTILE_BYTES / unit.length))}</div></body></html>`;
    const { document } = parseHTML(html);
    expect(msToRun(() => prepareForReader(document as unknown as Document))).toBeLessThan(1000);
    expect(document.querySelectorAll("body > div > h2").length).toBeGreaterThan(50_000);
  });

  // The HTML parser is linear in nesting depth (proxy/patches), so the hostile megabyte is 45
  // chains, each 2000 deep; the reader limit of 300 sends the page to the flattened full mode.
  it("renderPage on 45 chains of divs, each nested 2000 deep", () => {
    const chain = `<div>${"<div>".repeat(2000)}<p>deep text</p>${"</div>".repeat(2000)}</div>`;
    const html = `<html><head><title>D</title></head><body>${chain.repeat(Math.ceil(HOSTILE_BYTES / chain.length))}</body></html>`;
    let page: Page | null = null;
    expect(msToRun(() => (page = renderPage(html, URL_, "reader")))).toBeLessThan(1000);
    expect(page!.mode).toBe("full");
    expect(page!.gemtext).toContain("deep text");
  });

  it("renderPage on one chain of 100,000 nested divs renders in full mode", () => {
    const html = `<html><head><title>D</title></head><body>${"<div>".repeat(100_000)}<p>bottom</p></body></html>`;
    let page: Page | null = null;
    expect(msToRun(() => (page = renderPage(html, URL_, "reader")))).toBeLessThan(3000);
    expect(page!.mode).toBe("full");
    expect(page!.gemtext).toContain("bottom");
  });

  it("discoverFeed on 100,000 nested divs is fast", () => {
    const html = `<html><head><link rel="alternate" type="application/rss+xml" href="/f.xml"></head><body>${"<div>".repeat(100_000)}</body></html>`;
    expect(msToRun(() => expect(discoverFeed(html, URL_)).toBe("https://example.com/f.xml"))).toBeLessThan(3000);
  });
});

describe("element cap (413 before the DOM is built)", { retry: 2 }, () => {
  const MESSAGE = "Page is too large to read (over 200,000 elements)";
  const wrap = (body: string) => `<html><head><title>E</title></head><body>${body}</body></html>`;
  const refused = (run: () => unknown) => {
    let err: unknown;
    try {
      run();
    } catch (e) {
      err = e;
    }
    expect(err).toBeInstanceOf(ProxyError);
    expect((err as ProxyError).status).toBe(413);
    expect((err as ProxyError).message).toBe(MESSAGE);
  };

  it("is 200,000", () => expect(MAX_ELEMENTS).toBe(200_000));

  it("refuses 1,000,000 nested divs quickly, in renderPage and discoverFeed", () => {
    const html = wrap("<div>".repeat(1_000_000));
    expect(msToRun(() => refused(() => renderPage(html, URL_, "reader")))).toBeLessThan(2000);
    expect(msToRun(() => refused(() => discoverFeed(html, URL_)))).toBeLessThan(2000);
  });

  it("refuses 200,001 flat paragraphs", () => {
    // html, head, title, body and 199,997 <p> make exactly 200,001 elements
    refused(() => renderPage(wrap("<p>x".repeat(199_997)), URL_, "full"));
  });

  it("accepts exactly 200,000 elements", () => {
    const page = renderPage(wrap("<p>x".repeat(199_996)), URL_, "full"); // 4 + 199,996
    expect(page.gemtext).toContain("x");
    expect(discoverFeed(wrap("<p>x".repeat(199_996)), URL_)).toBeNull();
  });
});

describe("discoverFeed", () => {
  it("finds the advertised feed", () => {
    expect(discoverFeed(articleHtml(), URL_)).toBe("https://example.com/feed.xml");
  });
});

describe("real pages (committed fixtures)", () => {
  const fixture = (name: string) => readFileSync(new URL(`./fixtures/pages/${name}.html`, import.meta.url), "utf8");
  const cases: [string, string, boolean][] = [
    ["wikipedia-gemini", "https://en.wikipedia.org/wiki/Gemini_(protocol)", true],
    ["mdn-http-status", "https://developer.mozilla.org/en-US/docs/Web/HTTP/Status", true],
    ["picodeck-api-tcp", "https://picodeck.net/docs/api-tcp/", false],
  ];
  it.each(cases)("%s matches its snapshot", async (name, url, mustBeReader) => {
    const page = renderPage(fixture(name), url, "reader");
    if (mustBeReader) expect(page.mode).toBe("reader");
    await expect(page.gemtext).toMatchFileSnapshot(`./__snapshots__/${name}.gmi`);
  });
  it("titles the Wikipedia article", () => {
    expect(renderPage(fixture("wikipedia-gemini"), cases[0][1], "reader").title).toBe("Gemini (protocol)");
  });
});
