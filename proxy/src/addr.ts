import ipaddr from "ipaddr.js";
import { BlockedAddressError } from "./errors";

/**
 * True only for globally routable unicast addresses. ipaddr.js names every
 * special range (private, loopback, linkLocal, carrierGradeNat, uniqueLocal,
 * multicast, 6to4, teredo, rfc6052 NAT64, reserved, ...); anything other than
 * "unicast" is refused. IPv4-mapped IPv6 is judged as the IPv4 address.
 */
export function isPublicIp(ip: string): boolean {
  if (!ipaddr.isValid(ip)) return false;
  let addr = ipaddr.parse(ip);
  if (addr.kind() === "ipv6") {
    const v6 = addr as ipaddr.IPv6;
    if (v6.isIPv4MappedAddress()) addr = v6.toIPv4Address();
  }
  return addr.range() === "unicast";
}

const BLOCKED_SUFFIXES = [".localhost", ".local", ".internal"];

/**
 * Throws for host names and IP literals the proxy must not fetch. Pass
 * `new URL(...).hostname`: the WHATWG URL parser has already normalised
 * IPv4 spellings like 2130706433, 0x7f.1 and 0177.0.0.1 to dotted decimal.
 */
export function checkHost(hostname: string): void {
  const host = hostname.toLowerCase().replace(/^\[(.*)\]$/, "$1").replace(/\.$/, "");
  if (ipaddr.isValid(host)) {
    if (!isPublicIp(host)) throw new BlockedAddressError(`Blocked address: ${host}`);
    return;
  }
  if (host === "localhost" || !host.includes(".") || BLOCKED_SUFFIXES.some((s) => host.endsWith(s))) {
    throw new BlockedAddressError(`Blocked host: ${host}`);
  }
}
