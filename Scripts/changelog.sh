#!/bin/bash
# Release notes from commit messages.
#
#   Scripts/changelog.sh <from-ref> <to-ref>   commits in from..to
#   Scripts/changelog.sh "" <to-ref>           everything up to to-ref (first release)
#
# Each commit's subject becomes a bullet. Body lines that start with "- " become
# indented sub-bullets. Subjects starting with chore:, ci:, docs: or test: are left out.
set -euo pipefail

FROM="${1:-}"
TO="${2:?usage: changelog.sh <from-ref|\"\"> <to-ref>}"
RANGE="$TO"
[[ -n "$FROM" ]] && RANGE="$FROM..$TO"

git log --no-merges --format='%x1e%s%x1f%b' "$RANGE" | awk '
BEGIN { RS = "\036"; FS = "\037" }
NR == 1 && $0 == "" { next }
{
  subject = $1
  gsub(/^[ \t\n]+|[ \t\n]+$/, "", subject)
  if (subject == "" || tolower(subject) ~ /^(chore|ci|docs|test)(\([^)]*\))?:/) next
  print "- " subject
  n = split($2, lines, "\n")
  for (i = 1; i <= n; i++) {
    if (lines[i] ~ /^[-*] /) print "  " lines[i]
  }
}'
