// Generates the committed image fixtures. Re-run only to change them.
import { mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import sharp from "sharp";

const dir = fileURLToPath(new URL("../test/fixtures/images/", import.meta.url));
mkdirSync(dir, { recursive: true });

const rgba = () => sharp({ create: { width: 800, height: 600, channels: 4, background: { r: 30, g: 120, b: 200, alpha: 0.5 } } });
const rgb = () => sharp({ create: { width: 800, height: 600, channels: 3, background: { r: 30, g: 120, b: 200 } } });

await rgba().png().toFile(dir + "photo.png"); // transparent
await rgb().jpeg({ quality: 80, progressive: false }).toFile(dir + "photo.jpg");
await rgb().jpeg({ quality: 80, progressive: true }).toFile(dir + "photo-progressive.jpg");
await rgb().webp({ quality: 80 }).toFile(dir + "photo.webp"); // VP8
await rgb().webp({ lossless: true }).toFile(dir + "photo-lossless.webp"); // VP8L
await rgba().webp({ quality: 80 }).toFile(dir + "photo-alpha.webp"); // VP8X
await rgb().gif().toFile(dir + "photo.gif");
await sharp({ create: { width: 200, height: 100, channels: 3, background: "#ff0000" } }).png().toFile(dir + "small.png");
console.log("wrote", dir);
