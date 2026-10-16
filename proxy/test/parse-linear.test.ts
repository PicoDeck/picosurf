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

describe("HTML parsing is linear in nesting depth", () => {
  it.each(shapes)("1 MB of %s parses in under 3 s", (_n, unit) => {
    expect(msToRun(() => parseHTML(`<html><body>${repeat(unit, HOSTILE_BYTES)}`))).toBeLessThan(3000);
  });

  it("1 MB of <div> then unmatched </span> parses in under 3 s", () => {
    const n = Math.floor(HOSTILE_BYTES / 11);
    expect(msToRun(() => parseHTML(`<html><body>${"<div>".repeat(n)}${"</span>".repeat(n)}`))).toBeLessThan(3000);
  });

  // Doubling the input must not quadruple the time. Measured on the bare tokenizer and tag stack,
  // where noise is lowest; best of three.
  const parseOnly = (html: string) => msToRun(() => {
    const p = new Parser({});
    p.write(html);
    p.end();
  });
  const best = (html: string) => Math.min(parseOnly(html), parseOnly(html), parseOnly(html));
  it.each([...shapes.slice(0, 8), ["unmatched", "<div></span>"] as [string, string]])("doubling %s less than triples the time", (_n, unit) => {
    const nested = unit === "<div></span>" ? (k: number) => "<div>".repeat(k) + "</span>".repeat(k) : (k: number) => unit.repeat(k);
    const k = Math.floor(2_000_000 / unit.length);
    const t1 = best(nested(k));
    const t2 = best(nested(2 * k));
    expect(t2 / Math.max(t1, 20)).toBeLessThan(3);
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
