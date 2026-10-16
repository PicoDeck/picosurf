import { type Env, handleRequest } from "./handler";
import { createWasmResizer } from "./img-wasm";
import JPEG_DEC from "../node_modules/@jsquash/jpeg/codec/dec/mozjpeg_dec.wasm";
import JPEG_ENC from "../node_modules/@jsquash/jpeg/codec/enc/mozjpeg_enc.wasm";
// @ts-expect-error package ships a .wasm.d.ts with named exports only; wrangler gives a WebAssembly.Module default
import PNG_DEC from "../node_modules/@jsquash/png/codec/pkg/squoosh_png_bg.wasm";
import WEBP_DEC from "../node_modules/@jsquash/webp/codec/dec/webp_dec.wasm";

const resizer = createWasmResizer({ jpegDec: JPEG_DEC, jpegEnc: JPEG_ENC, pngDec: PNG_DEC, webpDec: WEBP_DEC });

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    return handleRequest(request, env, { fetch: (url, init) => fetch(url, init), resizer });
  },
};
