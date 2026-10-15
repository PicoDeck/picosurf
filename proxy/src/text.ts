export function collapse(s: string): string {
  return s.replace(/\s+/g, " ").trim();
}

/** "host/path" for labelling a URL, at most 60 characters. */
export function hostPath(url: string): string {
  try {
    const u = new URL(url);
    return (u.host + (u.pathname === "/" ? "" : u.pathname)).slice(0, 60);
  } catch {
    return url.slice(0, 60);
  }
}
