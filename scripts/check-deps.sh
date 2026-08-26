#!/usr/bin/env bash
# scripts/check-deps.sh
#
# Dependency audit for Pine. Prints pinned-vs-latest for every pinned
# component so a dependency pass can see, at a glance, what has fallen behind
# upstream. Read-only: makes no changes.
#
# Policy (see CLAUDE.md -> "Dependency maintenance"):
#   - keep every pin within N-1 of upstream;
#   - never downgrade an already-current pin;
#   - the new version/SHA must be a strict descendant of the one it replaces.
#
# Requires: bash 4+, gh (authenticated), jq, curl. Run from anywhere in the repo.

set -euo pipefail

cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

for cmd in gh jq; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "error: $cmd is required (install via Homebrew: brew install $cmd)" >&2
        exit 1
    }
done

say() { printf '\n=== %s ===\n' "$1"; }

# repo tag -> commit SHA, dereferencing annotated tag objects.
resolve_tag_sha() {
    local repo="$1" tag="$2"
    local ref sha type
    ref=$(gh api "repos/$repo/git/refs/tags/$tag" --jq '.object' 2>/dev/null || true)
    sha=$(printf '%s' "$ref" | jq -r '.sha // empty')
    type=$(printf '%s' "$ref" | jq -r '.type // empty')
    if [[ "$type" == "tag" && -n "$sha" ]]; then
        gh api "repos/$repo/git/tags/$sha" --jq '.object.sha' 2>/dev/null || printf '%s\n' "$sha"
    else
        printf '%s\n' "$sha"
    fi
}

say "GitHub Actions (SHA-pinned across .github/workflows/*.yml)"
printf '%-38s %-14s %-12s %s\n' "ACTION" "PINNED" "LATEST" "STATUS"
# Unique "<repo> <40-hex-sha>" pairs from `uses:` lines.
while IFS=' ' read -r repo pin; do
    [[ -n "$repo" ]] || continue
    latest=$(gh api "repos/$repo/releases/latest" --jq '.tag_name' 2>/dev/null || echo "?")
    latest_sha=$(resolve_tag_sha "$repo" "$latest")
    if [[ "$pin" == "$latest_sha" ]]; then
        status="current"
    elif [[ "$latest_sha" == "" || "$latest" == "?" ]]; then
        status="(lookup failed)"
    else
        status="OUTDATED"
    fi
    printf '%-38s %-14s %-12s %s\n' "$repo" "${pin:0:12}" "$latest" "$status"
done < <(grep -rhoE 'uses: [^[:space:]]+@[0-9a-f]{40}' .github/workflows/*.yml \
    | sed -E 's/uses: ([^[:space:]]+)@([0-9a-f]{40})/\1 \2/' | sort -u)

say "SwiftLint (.github/workflows/ci.yml)"
grep -E 'SWIFTLINT_VERSION|SWIFTLINT_SHA256' .github/workflows/ci.yml || true

say "SPM packages (Package.resolved)"
resolved="Pine.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
if [[ -f "$resolved" ]]; then
    jq -r '.pins[] | "\(.identity)\t\(.state.version)"' "$resolved" | column -t -s$'\t'
else
    echo "(Package.resolved not found at $resolved)"
fi

echo
echo "Re-run before every dependency pass. See CLAUDE.md -> \"Dependency maintenance\"."
