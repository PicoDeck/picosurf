import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { parseHTML } from "linkedom";
import { Readability } from "@mozilla/readability";

const fixture = (name: string) => readFileSync(new URL(`./fixtures/pages/${name}`, import.meta.url), "utf8");

describe("library assumptions the design rests on", () => {
  it("Readability extracts the Wikipedia article from a linkedom document", () => {
    const { document } = parseHTML(fixture("wikipedia-gemini.html"));
    const article = new Readability(document as unknown as Document).parse();
    expect(article?.title).toBe("Gemini (protocol)");
    expect((article?.textContent ?? "").length).toBeGreaterThan(5000);
  });

  it("Readability mutates the document it parses, so page.ts re-parses for the full-page fallback", () => {
    const { document } = parseHTML(fixture("wikipedia-gemini.html"));
    const before = document.querySelectorAll("*").length;
    new Readability(document as unknown as Document).parse();
    expect(document.querySelectorAll("*").length).not.toBe(before);
  });
});
