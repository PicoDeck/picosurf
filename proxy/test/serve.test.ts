import { spawn } from "node:child_process";
import { describe, expect, it } from "vitest";

describe("serve.ts", () => {
  it.each(["SIGTERM", "SIGINT"] as const)("closes the server and exits 0 on %s", async (signal) => {
    const child = spawn(process.execPath, ["--import", "tsx", "src/serve.ts"], {
      cwd: new URL("..", import.meta.url).pathname,
      env: { ...process.env, PORT: "0", PROXY_TOKEN: "t" },
      stdio: ["ignore", "pipe", "pipe"],
    });
    const exited = new Promise<[number | null, string | null]>((done) => child.on("exit", (code, sig) => done([code, sig])));
    await new Promise<void>((listening, failed) => {
      child.stdout.on("data", (chunk) => String(chunk).includes("listening") && listening());
      void exited.then(() => failed(new Error("serve.ts exited before listening")));
    });
    child.kill(signal);
    expect(await exited).toEqual([0, null]);
  });
});
