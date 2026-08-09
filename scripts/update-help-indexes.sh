#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELP_RESOURCES="$REPOSITORY_ROOT/Pine/Pine.help/Contents/Resources"
LOCALES=(en de es fr ja ko pt-BR ru zh-Hans)

for locale in "${LOCALES[@]}"; do
    locale_directory="$HELP_RESOURCES/$locale.lproj"
    output="$locale_directory/Pine.cshelpindex"
    temporary_index="$(mktemp "${TMPDIR:-/tmp}/Pine-$locale.XXXXXX.cshelpindex")"

    /usr/bin/hiutil \
        -I corespotlight \
        -Caf \
        -a \
        -g \
        -m 2 \
        -l "$locale" \
        -f "$temporary_index" \
        "$locale_directory"
    mv "$temporary_index" "$output"
done
