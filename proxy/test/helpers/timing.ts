/** Wall-clock milliseconds that `fn` takes. Hostile-input tests assert about 1 MB runs in under 1 s. */
export function msToRun(fn: () => unknown): number {
  const started = performance.now();
  fn();
  return performance.now() - started;
}

/** Hostile inputs are about this big. */
export const HOSTILE_BYTES = 1_000_000;
