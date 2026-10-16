// linkedom's parser (htmlparser2 10.1.0) kept its open-element stack with the top at index 0,
// so N nested tags cost O(N^2). proxy/patches/htmlparser2+10.1.0.patch moves the top to the end.
import { readFileSync } from "node:fs";
import { Parser } from "htmlparser2";
import { parseHTML } from "linkedom";
import { describe, expect, it } from "vitest";
import { HOSTILE_BYTES, msToRun } from "./helpers/timing";

const shapes: [string, string][] = [
  ["div", "<div>"],
  ["span", "<span>"],
  ["table cells", "<table><tr><td>"],
  ["p then li", "<p><li>"],
  ["li then dd", "<li><dd>"],
  ["dd then p", "<dd><p>"],
  ["self-closing div", "<div/>"],
  ["svg", "<svg>"],
  ["malformed a", "<a "],
  ["comment starts", "<!--"],
];
const repeat = (unit: string, bytes: number) => unit.repeat(Math.floor(bytes / unit.length));

const bare = (html: string) => {
  const p = new Parser({});
  p.write(html);
  return p as unknown as { stack: string[]; openCounts: Map<string, number>; write(s: string): void; end(): void };
};

describe("the htmlparser2 patch is applied", () => {
  it("keeps the open-element stack with its top at the end, and counts open names", () => {
    const p = bare("<div><span><b>");
    expect(p.stack).toEqual(["div", "span", "b"]);
    expect(p.openCounts).toBeInstanceOf(Map);
    expect(Object.fromEntries(p.openCounts)).toEqual({ div: 1, span: 1, b: 1 });
  });

  it("closes from the top down, leaves the stack alone on an unmatched close, and tracks counts", () => {
    const p = bare("<div><span><b>");
    p.write("</i>");
    expect(p.stack).toEqual(["div", "span", "b"]);
    p.write("</span>");
    expect(p.stack).toEqual(["div"]);
    expect(p.openCounts.get("span")).toBe(0);
    expect(p.openCounts.get("b")).toBe(0);
    expect(p.openCounts.get("div")).toBe(1);
  });

  it("keeps the order of close callbacks: innermost first", () => {
    const closed: string[] = [];
    const p = new Parser({ onclosetag: (n) => closed.push(n) });
    p.write("<a><b><i>x</a><u>");
    p.end();
    expect(closed).toEqual(["i", "b", "a", "u"]);
  });
});

// Coarse guards only: quadratic parsing takes minutes here, linear well under 2 s even under load.
describe("HTML parsing is not quadratic in nesting depth", { retry: 2, timeout: 60_000 }, () => {
  it("400,000 nested <div> through the bare parser in under 10 s", () => {
    expect(msToRun(() => { bare("<div>".repeat(400_000)).end(); })).toBeLessThan(10_000);
  });

  it("400,000 <div> then unmatched </span> through the bare parser in under 10 s", () => {
    expect(msToRun(() => { bare("<div>".repeat(400_000) + "</span>".repeat(400_000)).end(); })).toBeLessThan(10_000);
  });

  it.each(shapes)("1 MB of %s through linkedom in under 10 s", (_n, unit) => {
    expect(msToRun(() => parseHTML(`<html><body>${repeat(unit, HOSTILE_BYTES)}`))).toBeLessThan(10_000);
  });
});

describe("the patched parser builds the same tree as before", () => {
  const snippets = [
    "<p>one<p>two<ul><li>a<li>b<dl><dt>t<dd>d<dt>u</dl></ul>",
    "<b><i>x</b>y</i>z",
    "<div>a</span>b</p>c</div></div>",
    "<table><tr><td>1<td>2<tr><td>3</table>after",
    "<p>a<br>b<img src=x><hr>c<input>d</br>",
    "<select><option>a<option>b<optgroup><option>c</select>",
    "<svg><circle/><g><path/></g></svg><math><mi>x</mi></math><p/>q",
    "<div/><span/>text</div>",
    "<a href=1>x<a href=2>y</a>z</a>",
    "<ruby>漢<rt>kan<rp>)</ruby><div><p>x</div>",
    "</p>stray<p>",
    "<h1>a<h2>b</h1>c</h2>",
    "<div><div><div></span></span>x</div>y",
  ];
  it.each(snippets)("snippet %j", (html) => {
    expect(parseHTML(`<!doctype html><html><body>${html}</body></html>`).document.toString()).toMatchSnapshot();
  });
  it.each(["wikipedia-gemini", "mdn-http-status", "picodeck-api-tcp"])("fixture %s", async (name) => {
    const html = readFileSync(new URL(`./fixtures/pages/${name}.html`, import.meta.url), "utf8");
    await expect(parseHTML(html).document.toString()).toMatchFileSnapshot(`./__snapshots__/parse-${name}.html`);
  });
});
