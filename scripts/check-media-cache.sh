#!/bin/bash
# Run from any directory. Requires Swift 6.2+ and Python 3; no Xcode or iOS SDK.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for tool in swiftc python3; do
    command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done
WORK="$(mktemp -d "${TMPDIR:-/tmp}/media-cache-check.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export MEDIA_CACHE_TEST_FILE="$WORK/media-details.json"

python3 - "$ROOT" "$WORK/MediaCacheChecks.swift" <<'PY'
from pathlib import Path
import sys

root, output = Path(sys.argv[1]), Path(sys.argv[2])
media = (root / "Armstrong-Smart-Hub-App/Features/Home/MediaViews.swift").read_text()
checks = (root / "tests/MediaCacheChecks.swift").read_text()


def replace_once(text, marker, replacement):
    if text.count(marker) != 1:
        sys.exit(f"Expected exactly one marker: {marker!r}; update harness extraction.")
    return text.replace(marker, replacement, 1)


def between(text, start, end):
    for marker in (start, end):
        if text.count(marker) != 1:
            sys.exit(f"Expected exactly one marker: {marker!r}; update harness extraction.")
    first, last = text.index(start), text.index(end)
    if first >= last:
        sys.exit(f"Extraction markers out of order: {start!r}, {end!r}")
    return text[first:last]


cache = between(media, "private actor MediaDetailCacheFile {", "/// A cinematic title card")
# The only production substitution: redirect disk access, never the persistence logic.
cache = replace_once(cache, 'URL.cachesDirectory.appending(path: "media-details.json")',
                     'URL(fileURLWithPath: ProcessInfo.processInfo.environment["MEDIA_CACHE_TEST_FILE"]!)')
load = between(media, "    private func load() async {", "    private func request() async {")
checks = replace_once(checks, "// EXTRACTED_MEDIA_CACHE", cache)
checks = replace_once(checks, "    // EXTRACTED_MEDIA_DETAIL_LOAD_METHODS", load)
output.write_text(checks)
PY

# Compile the actual models, not a second set of Codable definitions. Exercise stricter
# concurrency checking than the app, with its default MainActor isolation enabled.
swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete \
    -default-isolation MainActor \
    -enable-upcoming-feature NonisolatedNonsendingByDefault \
    "$ROOT/Armstrong-Smart-Hub-App/Models/HomeModels.swift" \
    "$WORK/MediaCacheChecks.swift" -o "$WORK/media-cache-checks"
"$WORK/media-cache-checks"
