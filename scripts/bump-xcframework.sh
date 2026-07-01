#!/usr/bin/env bash
#
# Point Packages/Flextunnel/Package.swift's binary target at a flextunnel release.
# Downloads the release's libflextunnel-ios.xcframework.zip, computes its SPM
# checksum (the plain sha256 of the zip), and rewrites the url + checksum lines.
#
# Usage:
#   scripts/bump-xcframework.sh v0.0.11
#   scripts/bump-xcframework.sh            # defaults to the latest release tag
set -euo pipefail

REPO="andrewtheguy/flextunnel"
ASSET="libflextunnel-ios.xcframework.zip"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$SCRIPT_DIR/../Packages/Flextunnel/Package.swift"

die() { echo "error: $*" >&2; exit 1; }

TAG="${1:-}"
if [[ -z "$TAG" ]]; then
  command -v gh >/dev/null || die "no tag given and gh not installed to resolve the latest"
  TAG="$(gh release view --repo "$REPO" --json tagName --jq .tagName)"
fi

URL="https://github.com/$REPO/releases/download/$TAG/$ASSET"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "Downloading $URL ..."
curl -fL --retry 3 -o "$TMP/$ASSET" "$URL" || die "download failed: $URL"
CHECKSUM="$(shasum -a 256 "$TMP/$ASSET" | cut -d' ' -f1)"

# BSD sed (macOS) needs the empty -i arg; portable form via a temp file.
sed -E \
  -e "s#releases/download/[^/]+/${ASSET}#releases/download/${TAG}/${ASSET}#" \
  -e "s/checksum: \"[a-f0-9]+\"/checksum: \"${CHECKSUM}\"/" \
  "$MANIFEST" > "$TMP/Package.swift"
mv "$TMP/Package.swift" "$MANIFEST"

echo "Updated $MANIFEST:"
echo "  tag:      $TAG"
echo "  checksum: $CHECKSUM"
