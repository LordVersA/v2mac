#!/bin/bash
# Starts a release: tags the current commit and pushes the tag. CI then builds the DMG and
# publishes a GitHub Release whose notes are the commit messages since the previous tag.
#
#   Scripts/release.sh 0.2.0        shows the notes, asks, then tags v0.2.0 and pushes it
#   Scripts/release.sh 0.2.0 -y     same without the question
set -euo pipefail

VERSION="${1:?usage: release.sh <X.Y.Z> [-y]}"
VERSION="${VERSION#v}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: version must look like 1.2.3" >&2; exit 1; }
TAG="v$VERSION"

cd "$(dirname "$0")/.."
[[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || { echo "error: releases are made from main" >&2; exit 1; }
git diff --quiet && git diff --cached --quiet || { echo "error: uncommitted changes. Commit them first." >&2; exit 1; }
git fetch -q origin main --tags
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { echo "error: main is not pushed (or is behind origin). Push first." >&2; exit 1; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "error: $TAG already exists" >&2; exit 1; }

PREVIOUS="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
echo "Release $TAG (previous: ${PREVIOUS:-none})"
echo "---- release notes ----"
Scripts/changelog.sh "$PREVIOUS" HEAD
echo "-----------------------"

if [[ "${2:-}" != "-y" ]]; then
  read -r -p "Tag and push $TAG? [y/N] " answer
  [[ "$answer" == "y" || "$answer" == "Y" ]] || { echo "Cancelled."; exit 1; }
fi

git tag -a "$TAG" -m "V2Mac $VERSION"
git push origin "$TAG"
echo "Pushed $TAG. Watch it with: gh run watch"
