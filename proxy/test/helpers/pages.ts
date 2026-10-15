const LOREM =
  "PicoSurf renders the readable part of a web page on a 320 pixel screen. " +
  "This paragraph is long enough that Readability treats the article as real content rather than boilerplate, " +
  "and it repeats a little so that the total comfortably passes the five hundred character threshold. ";

/** An article page with navigation, a footer, metadata and a feed link. */
export function articleHtml(): string {
  return `<!doctype html><html><head><title>Test Article</title>
<meta property="og:site_name" content="Example Site">
<meta name="author" content="Jane Doe">
<meta property="article:published_time" content="2026-10-12T08:00:00Z">
<link rel="alternate" type="application/rss+xml" href="/feed.xml">
</head><body>
<nav><ul><li><a href="/">Home</a></li><li><a href="/about">About</a></li></ul></nav>
<article><h1>Test Article</h1>
<p>${LOREM}</p>
<p>${LOREM} See the <a href="/ref">reference</a> for details.</p>
<p>${LOREM}</p>
</article>
<footer><p>Copyright footer text</p></footer>
</body></html>`;
}
