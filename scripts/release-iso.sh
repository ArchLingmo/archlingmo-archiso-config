#!/bin/bash
# Publishes an ArchLingmo ISO as a GitHub release of archlingmo-archiso-config
# (the site, archlingmo-site/app.js, reads the latest release: the .iso asset,
# the SHA-256 in the notes and the date in the file name).
#
#   scripts/release-iso.sh [--dry-run] <iso> [tag]
#
#   1. the tag is the ISO date (archlingmo-YYYY.MM.DD-x86_64.iso -> YYYY.MM.DD);
#      a tag given explicitly must match it
#   2. size gate: GitHub release files must be under 2 GiB
#   3. <iso>.sha256 (sha256sum format)
#   4. <name>.pkglist.txt, read from the ISO (arch/pkglist.x86_64.txt), and its
#      diff against the previous release's list
#   5. creates the release (or replaces its files and notes when it exists)
#
# --dry-run does 1-4 and prints the notes and the gh commands, uploading nothing.
# Used by .github/workflows/release-iso.yml and by the workspace's
# `make upload-iso` (scripts/upload-iso.sh). Needs gh (GH_TOKEN or gh auth login).
set -euo pipefail

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && { DRY_RUN=1; shift; }
iso=${1:?usage: release-iso.sh [--dry-run] <iso> [tag]}
[ -f "$iso" ] || { echo "no such ISO: $iso"; exit 1; }
REPO="${GH_RELEASE_REPO:-ArchLingmo/archlingmo-archiso-config}"
MAX_BYTES=2147483648   # 2 GiB: GitHub refuses release files of this size or more

name=$(basename "$iso")
[[ "$name" =~ -([0-9]{4}\.[0-9]{2}\.[0-9]{2})-x86_64\.iso$ ]] \
    || { echo "unexpected ISO name: $name (want archlingmo-YYYY.MM.DD-x86_64.iso)"; exit 1; }
version=${BASH_REMATCH[1]}
tag=${2:-$version}
[ "$tag" = "$version" ] || { echo "tag $tag does not match the ISO date $version ($name)"; exit 1; }

summary() { [ -n "${GITHUB_STEP_SUMMARY:-}" ] && printf '%s\n' "$@" >> "$GITHUB_STEP_SUMMARY"; return 0; }
gh_ok() { command -v gh >/dev/null && gh auth status >/dev/null 2>&1; }

echo "==> size"
bytes=$(stat -L -c %s "$iso")
mib=$((bytes / 1024 / 1024))
echo "$name: $bytes bytes ($mib MiB); limit $MAX_BYTES bytes, margin $(((MAX_BYTES - bytes) / 1024 / 1024)) MiB"
summary "### $name" "" "- size: $bytes bytes ($mib MiB), limit 2048 MiB"
if [ "$bytes" -ge "$MAX_BYTES" ]; then
    echo "::error::$name has $mib MiB: GitHub releases take files under 2048 MiB"
    exit 1
fi

echo "==> checksum"
sha=$(sha256sum "$iso" | cut -d' ' -f1)
echo "$sha  $name" > "$iso.sha256"
echo "$sha"
summary "- sha256: \`$sha\`"

echo "==> package list"
pkglist="${iso%.iso}.pkglist.txt"
if command -v bsdtar >/dev/null; then
    bsdtar -xOf "$iso" arch/pkglist.x86_64.txt > "$pkglist"
else
    7z e -so "$iso" arch/pkglist.x86_64.txt > "$pkglist"
fi
echo "$(wc -l < "$pkglist") packages"
summary "- packages: $(wc -l < "$pkglist")"

# Newest other release, by tag (the tags are dates)
prev=""
if gh_ok; then
    prev=$(gh release list -R "$REPO" --exclude-drafts --limit 50 --json tagName --jq '.[].tagName' \
        | grep -vxF "$tag" | sort -V | tail -1 || true)
fi
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
# PREV_PKGLIST=<file> compares with a local list instead (e.g. from an older ISO:
# bsdtar -xOf old.iso arch/pkglist.x86_64.txt > old.txt)
against=""
if [ -n "${PREV_PKGLIST:-}" ]; then
    cp "$PREV_PKGLIST" "$tmp/prev.pkglist.txt"; against=$(basename "$PREV_PKGLIST")
    [ -s "$tmp/prev.pkglist.txt" ] || { echo "$PREV_PKGLIST is empty: no diff"; against=""; }
elif [ -n "$prev" ]; then
    if gh release download "$prev" -R "$REPO" -p '*.pkglist.txt' -D "$tmp" >/dev/null 2>&1; then
        against="release $prev"
    else
        echo "release $prev has no package list asset: no diff this time"
    fi
else
    echo "no previous release to compare with (or gh not authenticated)"
fi
if [ -n "$against" ]; then
    # name version per line: + added, - removed, ~ changed version
    diff_out=$(awk 'FILENAME==ARGV[1]{old[$1]=$2; next}
        !($1 in old){print "+ " $1 " " $2; next}
        old[$1]!=$2{print "~ " $1 " " old[$1] " -> " $2}
        {seen[$1]=1}
        END{for (p in old) if (!(p in seen)) print "- " p " " old[p]}' \
        "$tmp"/*.pkglist.txt "$pkglist" | sort -k2)
    echo "package changes since $against: $(grep -c . <<<"$diff_out" || true)"
    echo "${diff_out:-(none)}"
    summary "" "<details><summary>Package changes since $against</summary>" "" '```' "${diff_out:-(none)}" '```' "</details>"
fi

# Same text as before the CI existed; the site takes the SHA-256 from here.
# What changed in this ISO: release-notes/<version>.md (or RELEASE_NOTES_FILE), when present
notes_file="${RELEASE_NOTES_FILE:-$(dirname "$0")/../release-notes/$version.md}"
release_notes() {
    # shellcheck disable=SC2016 # literal backticks: markdown code span
    printf 'Imagem live do ArchLingmo %s (x86-64): o desktop Lingmo em Qt 6, sobre o Arch Linux.\n\nSHA-256: `%s`\n\nSite: https://archlingmo.github.io/\n' "$version" "$sha"
    if [ -f "$notes_file" ]; then printf '\n'; cat "$notes_file"; fi
}

files=("$iso" "$iso.sha256" "$pkglist")
run() { if [ "$DRY_RUN" = 1 ]; then echo "[dry-run] $*"; else "$@"; fi; }

echo "==> release $tag in $REPO"
if [ "$DRY_RUN" = 1 ]; then echo "--- notes ---"; release_notes; echo "-------------"; fi
if [ "$DRY_RUN" = 1 ] && ! gh_ok; then
    echo "[dry-run] gh not authenticated: would create or update release $tag with ${files[*]}"
elif gh release view "$tag" -R "$REPO" >/dev/null 2>&1; then
    echo "replacing the files of release $tag"
    run gh release upload "$tag" "${files[@]}" -R "$REPO" --clobber
    run gh release edit "$tag" -R "$REPO" --notes "$(release_notes)"
else
    echo "creating release $tag"
    latest=(--latest)
    # An older date published later does not take "latest" from a newer release
    if [ -n "$prev" ] && [ "$(printf '%s\n' "$prev" "$tag" | sort -V | tail -1)" != "$tag" ]; then latest=(--latest=false); fi
    target=(); [ -n "${RELEASE_TARGET:-}" ] && target=(--target "$RELEASE_TARGET")
    run gh release create "$tag" "${files[@]}" -R "$REPO" "${latest[@]}" "${target[@]}" \
        --title "ArchLingmo $version" --notes "$(release_notes)"
fi
echo "download: https://github.com/$REPO/releases/download/$tag/$name"
