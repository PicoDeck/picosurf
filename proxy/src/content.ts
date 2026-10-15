// What the upstream sent (spec 5.2), and how to turn its bytes into text.

export type Kind = "html" | "feed" | "image" | "text" | "unsupported";
export type ImageType = "jpeg" | "png" | "webp" | "gif";

const IMAGE_MIMES: Record<string, ImageType> = {
  "image/jpeg": "jpeg", "image/jpg": "jpeg", "image/pjpeg": "jpeg",
  "image/png": "png", "image/webp": "webp", "image/gif": "gif",
};
const FEED_MIMES = new Set(["application/rss+xml", "application/atom+xml", "application/rdf+xml"]);
const SNIFF_MIMES = new Set(["text/xml", "application/xml", "", "application/octet-stream", "binary/octet-stream"]);

export function mimeOf(contentType: string): string {
  return contentType.split(";")[0].trim().toLowerCase();
}

export function charsetOf(contentType: string): string | null {
  const m = /;\s*charset\s*=\s*"?([^";\s]+)"?/i.exec(contentType);
  return m ? m[1].toLowerCase() : null;
}

/** Decides from the header alone; "sniff" means read the body first and call sniffKind. */
export function kindFromMime(mime: string): Kind | "sniff" {
  if (mime === "text/html" || mime === "application/xhtml+xml") return "html";
  if (FEED_MIMES.has(mime)) return "feed";
  if (mime in IMAGE_MIMES) return "image";
  if (SNIFF_MIMES.has(mime)) return "sniff";
  if (mime.startsWith("text/")) return "text";
  return "unsupported";
}

export function imageTypeFromMime(mime: string): ImageType | null {
  return IMAGE_MIMES[mime] ?? null;
}

export function sniffImageType(b: Uint8Array): ImageType | null {
  if (b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return "jpeg";
  if (b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) return "png";
  const head = latin1(b.subarray(0, 16));
  if (head.startsWith("GIF87a") || head.startsWith("GIF89a")) return "gif";
  if (head.startsWith("RIFF") && head.slice(8, 12) === "WEBP") return "webp";
  return null;
}

export function sniffKind(bytes: Uint8Array): Kind {
  if (sniffImageType(bytes)) return "image";
  return sniffMarkup(bytes) ?? "unsupported";
}

function sniffMarkup(bytes: Uint8Array): "html" | "feed" | null {
  let head = latin1(bytes.subarray(0, 2048)).replace(/^ï»¿/, "");
  for (;;) {
    const before = head;
    head = head.replace(/^\s+/, "").replace(/^<\?[\s\S]*?\?>/, "").replace(/^<!--[\s\S]*?-->/, "");
    if (/^<!doctype\s+html/i.test(head)) return "html";
    head = head.replace(/^<!doctype[^>]*>/i, "");
    if (head === before) break;
  }
  if (/^<(rss|feed|rdf:rdf)[\s>]/i.test(head)) return "feed";
  if (/^<(html|head|body)[\s>]/i.test(head)) return "html";
  return null;
}

export function decodeText(bytes: Uint8Array, contentType: string): string {
  if (bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) return utf8(bytes.subarray(3));
  const label = charsetOf(contentType) ?? sniffCharset(bytes) ?? "utf-8";
  if (label === "utf-8" || label === "utf8") return utf8(bytes);
  if (CP1252_LABELS.has(label)) return cp1252(bytes);
  try {
    return new TextDecoder(label).decode(bytes);
  } catch {
    return utf8(bytes);
  }
}

function sniffCharset(bytes: Uint8Array): string | null {
  const head = latin1(bytes.subarray(0, 1024));
  const m = /<meta[^>]+charset\s*=\s*["']?([\w-]+)/i.exec(head) ?? /<\?xml[^>]+encoding\s*=\s*["']([\w-]+)/i.exec(head);
  return m ? m[1].toLowerCase() : null;
}

const utf8 = (b: Uint8Array) => new TextDecoder("utf-8").decode(b);

// WHATWG maps the ISO-8859-1 and ASCII labels to windows-1252 too.
const CP1252_LABELS = new Set(["windows-1252", "cp1252", "x-cp1252", "iso-8859-1", "iso8859-1", "iso_8859-1", "latin1", "l1", "us-ascii", "ascii"]);
const CP1252_HIGH = [
  0x20ac, 0x81, 0x201a, 0x192, 0x201e, 0x2026, 0x2020, 0x2021, 0x2c6, 0x2030, 0x160, 0x2039, 0x152, 0x8d, 0x17d, 0x8f,
  0x90, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014, 0x2dc, 0x2122, 0x161, 0x203a, 0x153, 0x9d, 0x17e, 0x178,
];

function cp1252(bytes: Uint8Array): string {
  const parts: string[] = [];
  for (let i = 0; i < bytes.length; i += 8192) {
    const codes = Array.from(bytes.subarray(i, i + 8192), (b) => (b >= 0x80 && b <= 0x9f ? CP1252_HIGH[b - 0x80] : b));
    parts.push(String.fromCharCode(...codes));
  }
  return parts.join("");
}

function latin1(bytes: Uint8Array): string {
  const parts: string[] = [];
  for (let i = 0; i < bytes.length; i += 8192) parts.push(String.fromCharCode(...bytes.subarray(i, i + 8192)));
  return parts.join("");
}
