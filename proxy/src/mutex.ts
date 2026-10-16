/**
 * Runs async jobs one at a time, in call order.
 *
 * A job still running after `maxWaitMs` stops holding up the next one. On
 * Workers, the promises of a request whose client has gone away can be
 * dropped, so a job may never finish; it must not stall every later job in
 * the isolate.
 */
export class Mutex {
  private last: Promise<void> = Promise.resolve();

  constructor(private readonly maxWaitMs = Infinity) {}

  async run<T>(job: () => Promise<T>): Promise<T> {
    const before = this.last;
    let release = () => {};
    this.last = new Promise<void>((resolve) => (release = resolve));
    try {
      await this.wait(before);
      return await job();
    } finally {
      release();
    }
  }

  private async wait(before: Promise<void>): Promise<void> {
    if (!Number.isFinite(this.maxWaitMs)) return before;
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      await Promise.race([before, new Promise<void>((resolve) => (timer = setTimeout(resolve, this.maxWaitMs)))]);
    } finally {
      clearTimeout(timer);
    }
  }
}
