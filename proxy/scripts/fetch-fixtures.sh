#!/bin/sh
# Downloads the committed page fixtures. Only permissively licensed pages are
# committed (spec 7.1); see test/fixtures/pages/SOURCES.md.
set -eu
dir="$(dirname "$0")/../test/fixtures/pages"
mkdir -p "$dir"
cd "$dir"
UA="PicoSurfProxy/1 (+https://github.com/PicoDeck/picosurf)"
curl -fsSL -A "$UA" -o wikipedia-gemini.html "https://en.wikipedia.org/wiki/Gemini_(protocol)"
curl -fsSL -A "$UA" -o mdn-http-status.html "https://developer.mozilla.org/en-US/docs/Web/HTTP/Status"
curl -fsSL -A "$UA" -o picodeck-api-tcp.html "https://picodeck.net/docs/api-tcp/"
ls -l
