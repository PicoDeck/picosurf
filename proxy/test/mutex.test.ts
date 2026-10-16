import { describe, expect, it } from "vitest";
import { Mutex } from "../src/mutex";

const tick = () => new Promise((r) => setTimeout(r, 5));

describe("Mutex", () => {
  it("runs concurrent jobs one at a time, in call order", async () => {
    const mutex = new Mutex();
    let inFlight = 0;
    let most = 0;
    const order: string[] = [];
    const job = (name: string) => async () => {
      inFlight++;
      most = Math.max(most, inFlight);
      order.push(`${name} start`);
      await tick();
      await tick();
      order.push(`${name} end`);
      inFlight--;
      return name;
    };
    expect(await Promise.all([mutex.run(job("a")), mutex.run(job("b")), mutex.run(job("c"))])).toEqual(["a", "b", "c"]);
    expect(most).toBe(1);
    expect(order).toEqual(["a start", "a end", "b start", "b end", "c start", "c end"]);
  });

  it("lets the next job run after one fails", async () => {
    const mutex = new Mutex();
    const failed = mutex.run(async () => {
      throw new Error("boom");
    });
    await expect(failed).rejects.toThrow("boom");
    expect(await mutex.run(async () => "next")).toBe("next");
  });

  it("stops waiting for a job that never finishes after maxWaitMs", async () => {
    const mutex = new Mutex(30);
    void mutex.run(() => new Promise(() => {}));
    const started = performance.now();
    expect(await mutex.run(async () => "ran")).toBe("ran");
    expect(performance.now() - started).toBeGreaterThanOrEqual(25);
  });
});
