import { readFileSync } from "node:fs";
import { createWasmResizer } from "../src/img-wasm";
import { resizerContract } from "./helpers/resizer-contract";

const mod = (path: string) => new WebAssembly.Module(readFileSync(new URL(`../node_modules/${path}`, import.meta.url)));

resizerContract("wasm", async () =>
  createWasmResizer({
    jpegDec: mod("@jsquash/jpeg/codec/dec/mozjpeg_dec.wasm"),
    jpegEnc: mod("@jsquash/jpeg/codec/enc/mozjpeg_enc.wasm"),
    pngDec: mod("@jsquash/png/codec/pkg/squoosh_png_bg.wasm"),
    webpDec: mod("@jsquash/webp/codec/dec/webp_dec.wasm"),
    resize: mod("@jsquash/resize/lib/resize/pkg/squoosh_resize_bg.wasm"),
  }),
);
