import dns from "node:dns";
import { isPublicIp } from "./addr";
import { BlockedAddressError } from "./errors";

export type Address = { address: string; family: number };
export type Resolver = (
  hostname: string,
  options: { all: true; family?: number },
  cb: (err: Error | null, addresses: Address[]) => void,
) => void;
type Callback = (err: Error | null, address?: string | Address[], family?: number) => void;

const systemResolve: Resolver = (hostname, options, cb) =>
  dns.lookup(hostname, options, (err, addresses) => cb(err, (addresses ?? []) as Address[]));

/**
 * A `lookup` for net/tls.connect that refuses any non-public address, so the
 * address checked is the one connected to: no DNS-rebinding gap (spec 5.4).
 * Handles both callback shapes: Node asks for `all: true` when it races
 * address families.
 */
export function guardedLookup(resolve: Resolver = systemResolve) {
  return (hostname: string, options: { all?: boolean; family?: number } | number, callback: Callback): void => {
    const opts = typeof options === "number" ? { family: options } : options;
    resolve(hostname, { all: true, family: opts.family }, (err, addresses) => {
      if (err) return callback(err);
      const bad = addresses.find((a) => !isPublicIp(a.address));
      if (bad || addresses.length === 0) {
        return callback(new BlockedAddressError(`${hostname} resolves to a blocked address${bad ? ` (${bad.address})` : ""}`));
      }
      if (opts.all) callback(null, addresses);
      else callback(null, addresses[0].address, addresses[0].family);
    });
  };
}
