import { foldAscii } from "./ascii";

/** An error that becomes an HTTP response: a status and a one-line reason (spec 5.3). */
export class ProxyError extends Error {
  constructor(
    readonly status: number,
    message: string,
    readonly headers: Record<string, string> = {},
  ) {
    super(message);
    this.name = "ProxyError";
  }
}

/** A host name or address the proxy must not fetch (spec 5.4). */
export class BlockedAddressError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "BlockedAddressError";
  }
}

export function textResponse(status: number, text: string, headers: Record<string, string> = {}): Response {
  const line = foldAscii(text).replace(/\s+/g, " ").trim();
  return new Response(line + "\n", {
    status,
    headers: { "Content-Type": "text/plain; charset=us-ascii", "Cache-Control": "no-store", ...headers },
  });
}
