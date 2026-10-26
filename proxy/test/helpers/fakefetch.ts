export type Route = Response | ((url: string, init: RequestInit) => Response | Promise<Response>);

/** A fetch that serves fixed routes by exact URL and records every call. */
export function fakeFetch(routes: Record<string, Route>) {
  const calls: { url: string; init: RequestInit }[] = [];
  const fn = async (url: string, init: RequestInit): Promise<Response> => {
    calls.push({ url, init });
    const route = routes[url];
    if (route === undefined) throw new TypeError("fetch failed", { cause: new Error(`no route for ${url}`) });
    if (typeof route === "function") return route(url, init);
    // A fresh copy, not route.clone(): a clone's body is one branch of a tee, and cancelling it
    // waits for the other branch (the stored route) to be cancelled too, which never happens.
    const body = route.body && (await route.clone().arrayBuffer());
    return new Response(body, { status: route.status, statusText: route.statusText, headers: route.headers });
  };
  return Object.assign(fn, { calls });
}

export const html = (body: string, headers: Record<string, string> = {}) =>
  new Response(body, { headers: { "Content-Type": "text/html; charset=utf-8", ...headers } });

export const redirect = (to: string, status = 302) => new Response(null, { status, headers: { Location: to } });
