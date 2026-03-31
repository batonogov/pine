#!/bin/bash
# check_actor_isolation.sh — CI lint: detect classes/structs that use background
# DispatchQueue or OperationQueue without `nonisolated` annotation.
#
# Context: SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor makes every type implicitly
# @MainActor. Dispatching to a background queue from such a type causes runtime
# crashes. The fix is to mark the type `nonisolated` (or explicitly @MainActor
# with proper Sendable handling).
#
# Usage: .github/scripts/check_actor_isolation.sh [directory]
#   directory — defaults to "Pine/"
#
# Exit codes: 0 = no violations, 1 = violations found

set -euo pipefail

SEARCH_DIR="${1:-Pine/}"
VIOLATIONS=()

# Patterns that indicate background queue usage (not DispatchQueue.main)
BG_PATTERNS=(
    'DispatchQueue(label:'
    'OperationQueue()'
    'DispatchQueue.global()'
)

# Find all Swift files in the target directory
while IFS= read -r file; do
    # For each background queue pattern, check if the file contains it
    for pattern in "${BG_PATTERNS[@]}"; do
        if grep -q "$pattern" "$file" 2>/dev/null; then
            # Skip if the match is on a line with DispatchQueue.main
            # (we only care about background queues)
            matches=$(grep -n "$pattern" "$file" | grep -v 'DispatchQueue\.main' || true)
            if [ -z "$matches" ]; then
                continue
            fi

            # Find the enclosing class/struct declaration.
            # Walk backwards from each match to find the nearest class/struct line.
            while IFS= read -r match_line; do
                line_num=$(echo "$match_line" | cut -d: -f1)

                # Search backwards from match line for class/struct declaration
                enclosing_type=""
                enclosing_line=0
                for ((i = line_num; i >= 1; i--)); do
                    decl=$(sed -n "${i}p" "$file")
                    if echo "$decl" | grep -qE '^\s*(public |private |internal |open |fileprivate )*(final )*(class|struct) [A-Za-z0-9_]+'; then
                        enclosing_type="$decl"
                        enclosing_line=$i
                        break
                    fi
                done

                if [ -z "$enclosing_type" ]; then
                    continue
                fi

                # Check: is the type already nonisolated?
                # Look at the declaration line and up to 3 lines before it
                is_nonisolated=false
                start=$((enclosing_line > 3 ? enclosing_line - 3 : 1))
                for ((i = start; i <= enclosing_line; i++)); do
                    check_line=$(sed -n "${i}p" "$file")
                    if echo "$check_line" | grep -qE '^\s*nonisolated\b'; then
                        is_nonisolated=true
                        break
                    fi
                done

                # Check: is the type explicitly @MainActor with proper handling?
                # If it's explicitly @MainActor, that's fine — the developer knows
                # what they're doing (they must use nonisolated methods or Sendable).
                # We only flag types with NO isolation annotation (implicit @MainActor).
                is_explicit_main_actor=false
                for ((i = start; i <= enclosing_line; i++)); do
                    check_line=$(sed -n "${i}p" "$file")
                    if echo "$check_line" | grep -qE '^\s*@MainActor\b'; then
                        is_explicit_main_actor=true
                        break
                    fi
                done

                # Also check if enclosing type is an enum (enums with static
                # methods using background queues are fine — no stored state)
                is_enum=false
                if echo "$enclosing_type" | grep -qE '^\s*(public |private |internal |open |fileprivate )*enum '; then
                    is_enum=true
                fi

                if ! $is_nonisolated && ! $is_explicit_main_actor && ! $is_enum; then
                    # Extract type name for readable output
                    type_name=$(echo "$enclosing_type" | sed -E 's/.*\b(class|struct) ([A-Za-z0-9_]+).*/\2/')
                    type_kind=$(echo "$enclosing_type" | sed -E 's/.*\b(class|struct) .*/\1/')
                    rel_path="${file#./}"
                    violation="$rel_path:$line_num: $type_kind '$type_name' uses background queue ($pattern) but is not marked 'nonisolated'"
                    # Deduplicate
                    already_reported=false
                    for v in "${VIOLATIONS[@]+"${VIOLATIONS[@]}"}"; do
                        if [ "$v" = "$violation" ]; then
                            already_reported=true
                            break
                        fi
                    done
                    if ! $already_reported; then
                        VIOLATIONS+=("$violation")
                    fi
                fi
            done <<< "$matches"
        fi
    done
done < <(find "$SEARCH_DIR" -name '*.swift' -type f | sort)

if [ ${#VIOLATIONS[@]} -gt 0 ]; then
    echo "::error::Actor isolation violations found!"
    echo ""
    echo "With SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, all types are implicitly"
    echo "@MainActor. Using a background DispatchQueue/OperationQueue in such a type"
    echo "causes runtime crashes. Fix: add 'nonisolated' before the type declaration."
    echo ""
    echo "Violations:"
    for v in "${VIOLATIONS[@]}"; do
        echo "  - $v"
    done
    echo ""
    echo "Total: ${#VIOLATIONS[@]} violation(s)"
    exit 1
else
    echo "Actor isolation check passed — no violations found."
    exit 0
fi
