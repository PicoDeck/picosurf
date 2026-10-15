import { describe, expect, it } from "vitest";
import { parseHTML } from "linkedom";
import { type ConvertOptions, pickFromSrcset, toGemtext } from "../src/html2gmi";
import { HOSTILE_BYTES, msToRun } from "./helpers/timing";

const gmi = (body: string, opts: Partial<ConvertOptions> = {}) => {
  const { document } = parseHTML(`<!doctype html><html><head></head><body>${body}</body></html>`);
  return toGemtext(document.body as unknown as Element, { base: "https://example.com/dir/page.html", ...opts });
};

describe("block structure", () => {
  it("maps headings, capping at three levels", () => {
    expect(gmi("<h1>One</h1><h2>Two</h2><h3>Three</h3><h4>Four</h4><h6>Six</h6>")).toBe(
      "# One\n\n## Two\n\n### Three\n\n### Four\n\n### Six\n",
    );
  });

  it("collapses whitespace and splits paragraphs at <br>", () => {
    expect(gmi("<p>Hello   <b>bold</b>\n world</p><p>a<br>b</p>")).toBe("Hello bold world\n\na\nb\n");
  });

  it("drops the first heading that repeats the title", () => {
    expect(gmi("<h1>My  title</h1><p>x</p><h2>My Title</h2>", { dropHeading: "My Title" })).toBe("x\n\n## My Title\n");
  });

  it("flattens lists, numbers ordered ones from start, and separates lists", () => {
    expect(gmi('<ul><li>a</li><li>b <ul><li>c</li></ul></li></ul><ol start="3"><li>x</li><li>y</li></ol>')).toBe(
      "* a\n* b\n* c\n\n* 3. x\n* 4. y\n",
    );
  });

  it("joins paragraphs inside a list item", () => {
    expect(gmi("<ul><li><p>One</p><p>Two</p></li></ul>")).toBe("* One Two\n");
  });

  it("quotes every paragraph of a blockquote", () => {
    expect(gmi("<blockquote><p>q1</p><p>q2 <i>it</i></p></blockquote><p>after</p>")).toBe("> q1\n> q2 it\n\nafter\n");
  });

  it("fences preformatted text with its language, expands tabs and escapes inner fences", () => {
    expect(gmi('<pre><code class="language-lua">local x = 1\n\tif x then\n```nope\nend\n</code></pre>')).toBe(
      "```lua\nlocal x = 1\n    if x then\n ```nope\nend\n```\n",
    );
  });

  it("keeps <br> inside preformatted text as a line break", () => {
    expect(gmi("<pre>one<br>two<br/><b>three<br></b>four</pre>")).toBe("```\none\ntwo\nthree\nfour\n```\n");
  });

  it("keeps inline code in backticks", () => {
    expect(gmi("<p>Use <code>a  b</code> now</p>")).toBe("Use `a b` now\n");
  });

  it("writes table rows as cells joined with |, after the caption", () => {
    expect(gmi("<table><caption>Cap</caption><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table>")).toBe(
      "Cap\n\nA | B\n1 | 2\n",
    );
  });

  it("walks layout tables (tables containing tables) as containers", () => {
    expect(gmi("<table><tr><td><table><tr><td>a</td><td>b</td></tr></table></td></tr></table>")).toBe("a | b\n");
  });

  it("skips scripts, styles, forms, rules and hidden elements", () => {
    expect(
      gmi(
        '<p>keep</p><script>x</script><style>y</style><nav hidden><p>gone</p></nav><div aria-hidden="true">gone</div>' +
          '<p style="display: none">gone</p><form><p>gone</p></form><hr><p>end</p>',
      ),
    ).toBe("keep\n\nend\n");
  });

  it("makes text lines that look like gemtext syntax plain text (Review Focus 3)", () => {
    expect(gmi("<p># not heading</p><p>=&gt; not link</p><p>* not item</p><p>&gt; not quote</p><p>``` not fence</p>")).toBe(
      " # not heading\n\n => not link\n\n * not item\n\n > not quote\n\n ``` not fence\n",
    );
  });

  it("turns inline runs inside mixed containers into paragraphs", () => {
    expect(gmi("<div>intro <b>text</b><p>para</p>tail</div>")).toBe("intro text\n\npara\n\ntail\n");
  });
});

describe("links and images", () => {
  it("numbers inline links across the page and lists them after each block", () => {
    expect(gmi('<p>See <a href="/a">the docs</a> and <a href="https://x.org/b#frag">B</a>.</p><p>Again <a href="/a">docs</a></p>')).toBe(
      "See the docs [1] and B [2].\n=> https://example.com/a [1] the docs\n=> https://x.org/b [2] B\n\n" +
        "Again docs [1]\n=> https://example.com/a [1] docs\n",
    );
  });

  it("turns blocks that are a single link into plain link lines", () => {
    expect(gmi('<ul><li><a href="/home">Home</a></li><li><a href="about">About</a></li></ul><p><a href="/more">Read more</a></p>')).toBe(
      "=> https://example.com/home Home\n=> https://example.com/dir/about About\n\n=> https://example.com/more Read more\n",
    );
  });

  it("turns a heading that is a single link into a link line", () => {
    expect(gmi('<h2><a href="/p1">Post one</a></h2><p>Summary</p>')).toBe("=> https://example.com/p1 Post one\n\nSummary\n");
  });

  it("drops anchor, javascript, mailto and tel links but keeps their text", () => {
    expect(
      gmi('<p><a href="#top">Top</a> <a href="javascript:void(0)">JS</a> <a href="mailto:a@b.c">Mail</a> <a href="tel:123">Call</a> text</p>'),
    ).toBe("Top JS Mail Call text\n");
  });

  it("labels links without text by aria-label, else host and path", () => {
    expect(gmi('<p>x <a href="https://example.com/rss/feed.xml"><svg></svg></a></p>')).toBe(
      "x\n=> https://example.com/rss/feed.xml example.com/rss/feed.xml\n",
    );
    expect(gmi('<p>x <a href="/share" aria-label="Share this"></a></p>')).toBe("x\n=> https://example.com/share Share this\n");
  });

  it("writes images as [IMG] links, picking the srcset entry nearest 640w", () => {
    expect(
      gmi(
        '<p><img src="/i/a.png" alt="A cat"></p>' +
          '<figure><img srcset="s.jpg 320w, m.jpg 640w, l.jpg 1280w" src="l.jpg"><figcaption>Cap</figcaption></figure>',
      ),
    ).toBe("=> https://example.com/i/a.png [IMG] A cat\n=> https://example.com/dir/m.jpg [IMG] image\n\nCap\n");
  });

  it("uses lazy-load attributes when src is a data: placeholder, and drops data: images", () => {
    expect(gmi('<p><img src="data:image/gif;base64,R0l" data-src="/real.jpg" alt="Lazy"></p><p><img src="data:image/png;base64,xx"></p>')).toBe(
      "=> https://example.com/real.jpg [IMG] Lazy\n",
    );
  });

  it("follows an image inside a link with the link, unless they point to the same place", () => {
    expect(
      gmi(
        '<p><a href="/big.jpg"><img src="/small.jpg" alt="Photo"></a></p>' +
          '<p><a href="/post"><img src="/thumb.jpg" alt="Post"></a></p>' +
          '<p><a href="/same.jpg"><img src="/same.jpg" alt="S"></a></p>',
      ),
    ).toBe(
      "=> https://example.com/small.jpg [IMG] Photo\n=> https://example.com/big.jpg Photo\n" +
        "=> https://example.com/thumb.jpg [IMG] Post\n=> https://example.com/post Post\n" +
        "=> https://example.com/same.jpg [IMG] S\n",
    );
  });

  it("puts a block's images after its text and link lines", () => {
    expect(gmi('<p>Look <img src="/x.png" alt="X"> here <a href="/l">link</a></p>')).toBe(
      "Look here link [1]\n=> https://example.com/l [1] link\n=> https://example.com/x.png [IMG] X\n",
    );
  });

  it("numbers links in table rows", () => {
    expect(gmi('<table><tr><td>1.</td><td><a href="/s">Story</a> (x.org)</td></tr></table>')).toBe(
      "1. | Story [1] (x.org)\n=> https://example.com/s [1] Story\n",
    );
  });

  it("numbers links inside quotes", () => {
    expect(gmi('<blockquote><p>As <a href="/s">source</a> says</p></blockquote>')).toBe(
      "> As source [1] says\n=> https://example.com/s [1] source\n",
    );
  });
});

describe("pickFromSrcset", () => {
  it("prefers the width nearest the target", () => expect(pickFromSrcset("u.jpg 300w,v.jpg 700w")).toBe("v.jpg"));
  it("takes the 1x density candidate", () => expect(pickFromSrcset("a.jpg 1x,b.jpg 2x")).toBe("a.jpg"));
  it("keeps commas inside URLs", () =>
    expect(pickFromSrcset("https://c.com/w_640,h_480/x.jpg 640w, https://c.com/w_1280,h_960/x.jpg 1280w")).toBe(
      "https://c.com/w_640,h_480/x.jpg",
    ));
  it("returns null for an empty srcset", () => expect(pickFromSrcset("  ")).toBeNull());
});

describe("nesting depth", () => {
  it("survives <div> nested 20,000 deep", () => {
    const n = 20000;
    expect(gmi("<div>".repeat(n) + "<p>deep text</p>" + "</div>".repeat(n))).toContain("deep text");
  });

  it("survives <span> nested 20,000 deep inside a paragraph", () => {
    const n = 20000;
    expect(gmi("<p>" + "<span>".repeat(n) + "inner" + "</span>".repeat(n) + "</p>")).toContain("inner");
  });
});

describe("hostile input (about 1 MB in under 1 s)", () => {
  it("a preformatted line of spaces ending in x", () => {
    const body = `<pre>${" ".repeat(HOSTILE_BYTES)}x</pre>`;
    let out = "";
    expect(msToRun(() => (out = gmi(body)))).toBeLessThan(1000);
    expect(out.endsWith(" x\n```\n")).toBe(true);
  });
});
