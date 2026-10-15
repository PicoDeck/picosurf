import { describe, expect, it } from "vitest";
import { parseHTML } from "linkedom";
import { type Feed, MAX_ITEMS, feedToGemtext, findFeedLink, parseFeed } from "../src/feed";
import { HOSTILE_BYTES, msToRun } from "./helpers/timing";

const BASE = "https://blog.example.com/feed.xml";

describe("parseFeed", () => {
  it("reads RSS 2.0: dates, guid permalinks, relative links, entities and markup in titles", () => {
    const xml = `<?xml version="1.0"?><rss version="2.0"><channel><title>My &amp; Blog</title>
      <item><title>Older</title><link>/older</link><pubDate>Mon, 12 Oct 2026 08:00:00 GMT</pubDate></item>
      <item><title><![CDATA[<b>Newer</b>&nbsp;post]]></title><link>https://blog.example.com/newer#c</link><pubDate>Tue, 13 Oct 2026 09:30:00 +0000</pubDate></item>
      <item><title>No date</title><guid>https://blog.example.com/undated</guid></item>
      <item><title>Not a permalink</title><guid isPermaLink="false">tag:x,1</guid></item>
    </channel></rss>`;
    const feed = parseFeed(xml, BASE)!;
    expect(feed.title).toBe("My & Blog");
    expect(feed.items.map((i) => [i.url, i.title])).toEqual([
      ["https://blog.example.com/newer", "Newer post"],
      ["https://blog.example.com/older", "Older"],
      ["https://blog.example.com/undated", "No date"],
    ]);
    expect(feed.items[2].time).toBeNull();
  });

  it("reads Atom: alternate links over self, updated when there is no published date, HTML titles", () => {
    const xml = `<feed xmlns="http://www.w3.org/2005/Atom"><title type="html">Atom &lt;i&gt;Site&lt;/i&gt;</title>
      <entry><title>First</title><link rel="self" href="https://a.example/self"/><link rel="alternate" type="text/html" href="/posts/1"/>
        <published>2026-10-01T10:00:00Z</published></entry>
      <entry><title>Second</title><link href="https://a.example/posts/2"/><updated>2026-10-05T10:00:00Z</updated></entry>
    </feed>`;
    const feed = parseFeed(xml, "https://a.example/atom.xml")!;
    expect(feed.title).toBe("Atom Site");
    expect(feed.items.map((i) => i.url)).toEqual(["https://a.example/posts/2", "https://a.example/posts/1"]);
  });

  it("reads RSS 1.0 (RDF) with dc:date", () => {
    const xml = `<?xml version="1.0"?><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns="http://purl.org/rss/1.0/" xmlns:dc="http://purl.org/dc/elements/1.1/">
      <channel><title>RDF Site</title></channel>
      <item><title>R1</title><link>https://r.example/1</link><dc:date>2026-10-02T00:00:00Z</dc:date></item>
    </rdf:RDF>`;
    const feed = parseFeed(xml, "https://r.example/rss")!;
    expect(feed.title).toBe("RDF Site");
    expect(feed.items).toEqual([{ url: "https://r.example/1", title: "R1", time: Date.parse("2026-10-02T00:00:00Z") }]);
  });

  it("does not expand DOCTYPE entities (Review Focus 5)", () => {
    const bomb = `<?xml version="1.0"?><!DOCTYPE rss [<!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;"><!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;">]>
      <rss version="2.0"><channel><title>T &c;</title><item><title>i</title><link>https://e.example/1</link></item></channel></rss>`;
    // Whether the parser keeps or rejects the now-undefined &c; doesn't matter; it must never expand.
    expect(parseFeed(bomb, "https://e.example/feed")?.title ?? "").not.toContain("aaaa");
  });

  it("keeps the newest 50 items", () => {
    const items = Array.from(
      { length: 60 },
      (_, i) => `<item><title>P${i}</title><link>https://e.example/${i}</link><pubDate>${new Date(Date.UTC(2026, 0, 1 + i)).toUTCString()}</pubDate></item>`,
    ).join("");
    const feed = parseFeed(`<rss><channel><title>T</title>${items}</channel></rss>`, "https://e.example/f")!;
    expect(feed.items).toHaveLength(MAX_ITEMS);
    expect(feed.items[0].title).toBe("P59");
  });

  it("falls back to the host for a missing title and (untitled) for items", () => {
    const feed = parseFeed("<rss><channel><item><link>https://e.example/x</link></item></channel></rss>", "https://e.example/feed")!;
    expect(feed.title).toBe("e.example/feed");
    expect(feed.items[0].title).toBe("(untitled)");
  });

  it.each(["hello", "<html><body>no</body></html>"])("returns null for %j", (xml) => {
    expect(parseFeed(xml, BASE)).toBeNull();
  });

  it("keeps an entity named like an Object property literally", () => {
    const xml = `<rss><channel><title><![CDATA[A &constructor; B]]></title><item><link>https://e.example/1</link></item></channel></rss>`;
    expect(parseFeed(xml, BASE)!.title).toBe("A &constructor; B");
  });

  it("removes a DOCTYPE with or without an internal subset", () => {
    const rss = `<rss version="2.0"><channel><title>T</title><item><title>i</title><link>https://e.example/1</link></item></channel></rss>`;
    expect(parseFeed(`<?xml version="1.0"?><!DOCTYPE rss>${rss}`, BASE)?.title).toBe("T");
    expect(parseFeed(`<!doctype rss [<!ENTITY x "a>b">]>${rss}`, BASE)?.title).toBe("T");
  });
});

describe("parseFeed on hostile input (about 1 MB in under 1 s)", () => {
  it("an unterminated DOCTYPE repeated", () => {
    const xml = "<!DOCTYPE [".repeat(Math.ceil(HOSTILE_BYTES / 11));
    let feed: Feed | null = null;
    expect(msToRun(() => (feed = parseFeed(xml, BASE)))).toBeLessThan(1000);
    expect(feed).toBeNull();
  });

  it("a CDATA title that is all '<'", () => {
    const xml = `<rss><channel><title><![CDATA[${"<".repeat(HOSTILE_BYTES)}]]></title><item><link>https://e.example/1</link></item></channel></rss>`;
    let feed: Feed | null = null;
    expect(msToRun(() => (feed = parseFeed(xml, BASE)))).toBeLessThan(1000);
    expect(feed!.items).toHaveLength(1);
  });
});

describe("feedToGemtext", () => {
  it("writes a title and dated link lines", () => {
    const text = feedToGemtext({
      title: "Blog",
      items: [
        { url: "https://b.example/2", title: "Two", time: Date.parse("2026-10-13T09:30:00Z") },
        { url: "https://b.example/u", title: "Undated", time: null },
      ],
    });
    expect(text).toBe("# Blog\n\n=> https://b.example/2 2026-10-13 Two\n=> https://b.example/u Undated\n");
  });
});

describe("findFeedLink", () => {
  it("returns the first RSS or Atom alternate link, resolved", () => {
    const { document } = parseHTML(`<html><head>
      <link rel="stylesheet" href="/s.css"><link rel="alternate" type="application/json" href="/feed.json">
      <link rel="alternate" type="application/atom+xml" href="/atom.xml"><link rel="alternate" type="application/rss+xml" href="/rss.xml">
      </head><body></body></html>`);
    expect(findFeedLink(document as unknown as Document, "https://b.example/post/1")).toBe("https://b.example/atom.xml");
  });
  it("skips data: links and links over 2048 characters", () => {
    const long = `https://b.example/${"x".repeat(2040)}.xml`;
    const { document } = parseHTML(`<html><head>
      <link rel="alternate" type="application/rss+xml" href="data:application/rss+xml,%3Crss%3E%3C/rss%3E">
      <link rel="alternate" type="application/rss+xml" href="${long}">
      <link rel="alternate" type="application/atom+xml" href="/atom.xml">
      </head><body></body></html>`);
    expect(findFeedLink(document as unknown as Document, "https://b.example/")).toBe("https://b.example/atom.xml");
  });
  it("returns null without one", () => {
    const { document } = parseHTML("<html><head></head><body></body></html>");
    expect(findFeedLink(document as unknown as Document, "https://b.example/")).toBeNull();
  });
});
