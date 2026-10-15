// wrangler bundles .wasm imports as compiled modules.
declare module "*.wasm" {
  const module: WebAssembly.Module;
  export default module;
}
