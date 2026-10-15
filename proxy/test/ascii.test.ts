import { describe, expect, it } from "vitest";
import { foldAscii } from "../src/ascii";

describe("foldAscii", () => {
  it.each([
    ["“Hello” — it’s… fine", "\"Hello\" -- it's... fine"],
    ["café naïve façade", "cafe naive facade"],
    ["é", "e"],
    ["ﬁne ①", "fine 1"],
    ["Straße Œuvre Łódź", "Strasse OEuvre Lodz"],
    ["a b c　d", "a b c d"],
    ["20°C ½ €5 ™ © × → ≤", "20 degC 1/2 EUR5 (TM) (c) x -> <="],
    ["• item · dot", "* item * dot"],
    ["↑ up ↓ down", "^ up v down"],
    ["x² Ａ", "x2 A"],
    ["ok \u{1f44d}\u{1f3fd} \u{1f1ec}\u{1f1e7} \u{1f468}‍\u{1f469}‍\u{1f467} 1️⃣", "ok    1"],
    ["日本語 текст", "??? ?????"],
    ["tab\tnew\nline\r\u0007bell\u0085­", "tab\tnew\nlinebell"],
    ["plain ASCII ~!@#$%^&*()", "plain ASCII ~!@#$%^&*()"],
  ])("%j → %j", (input, expected) => {
    expect(foldAscii(input)).toBe(expected);
  });

  it("only ever outputs printable ASCII, tab and newline", () => {
    let all = "";
    for (let cp = 0; cp < 0x3000; cp++) all += String.fromCodePoint(cp);
    expect(foldAscii(all)).toMatch(/^[\t\n\x20-\x7e]*$/);
  });
});
