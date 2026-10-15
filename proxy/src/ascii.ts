// Folds text to what PicoDeck's fonts can draw: 0x20-0x7E plus tab and
// newline (spec 5.6). Applied once, by the handler, to everything it sends.

const TABLE: Record<string, string> = {
  "‘": "'", "’": "'", "‚": "'", "‛": "'", "′": "'",
  "“": '"', "”": '"', "„": '"', "‟": '"', "″": '"',
  "«": "<<", "»": ">>", "‹": "<", "›": ">",
  "‐": "-", "‑": "-", "‒": "-", "–": "-", "−": "-",
  "—": "--", "―": "--",
  "…": "...", "•": "*", "·": "*", "‣": "*", "◦": "*",
  "→": "->", "←": "<-", "↔": "<->", "⇒": "=>", "↑": "^", "↓": "v",
  "≤": "<=", "≥": ">=", "≠": "!=", "≈": "~",
  "×": "x", "÷": "/",
  "©": "(c)", "®": "(R)", "™": "(TM)",
  "€": "EUR", "£": "GBP", "¥": "JPY", "¢": "c",
  "°": " deg",
  "½": "1/2", "¼": "1/4", "¾": "3/4",
  "Æ": "AE", "æ": "ae", "Œ": "OE", "œ": "oe",
  "Ø": "O", "ø": "o", "ß": "ss", "Ł": "L", "ł": "l",
  "Đ": "D", "đ": "d", "Ð": "D", "ð": "d", "Þ": "Th", "þ": "th", "ı": "i",
  "¡": "!", "¿": "?", "§": "S", "¶": "P",
  "†": "+", "‡": "++", "‰": "%o", "ƒ": "f", "ˆ": "^", "˜": "~",
};

const SPACES = /[   -   　]/u;
// Emoji, skin tones, flags, variation selectors, zero-width joiners and spaces, soft hyphen, tag characters.
const REMOVE = /[\p{Extended_Pictographic}\p{Emoji_Modifier}\p{Regional_Indicator}\u{fe00}-\u{fe0f}\u{200b}-\u{200d}\u{2060}\u{feff}\u{00ad}\u{e0020}-\u{e007f}]/u;
const MARKS = /\p{M}/gu;
const PRINTABLE = /^[\x20-\x7e]+$/;

export function foldAscii(input: string): string {
  let out = "";
  for (const ch of input.normalize("NFC")) {
    const cp = ch.codePointAt(0)!;
    if (cp === 0x09 || cp === 0x0a) { out += ch; continue; }
    if (cp < 0x20 || cp === 0x7f || (cp >= 0x80 && cp <= 0x9f)) continue;
    if (cp < 0x80) { out += ch; continue; }
    const mapped = TABLE[ch];
    if (mapped !== undefined) { out += mapped; continue; }
    if (SPACES.test(ch)) { out += " "; continue; }
    if (REMOVE.test(ch)) continue;
    const base = ch.normalize("NFKD").replace(MARKS, "");
    if (base === "") continue; // a lone combining mark
    out += PRINTABLE.test(base) ? base : "?";
  }
  return out;
}
