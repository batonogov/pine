#!/bin/bash

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
icon_path="${1:-$repository_root/Pine/AppIcon.icon}"
output_root="${2:-$repository_root/assets/app-icon-design/previews}"
icon_tool="${ICON_COMPOSER_TOOL:-/Applications/Icon Composer.app/Contents/Executables/ictool}"

if [[ ! -x "$icon_tool" ]]; then
    echo "error: Icon Composer 2 ictool not found at $icon_tool" >&2
    echo "Set ICON_COMPOSER_TOOL to the installed ictool path." >&2
    exit 1
fi

if [[ ! -d "$icon_path" ]]; then
    echo "error: Icon Composer document not found at $icon_path" >&2
    exit 1
fi

export_icon() {
    local generation="$1"
    local rendition="$2"
    local size="$3"
    local rendition_name
    local destination
    local arguments

    case "$rendition" in
        Default) rendition_name="default" ;;
        Dark) rendition_name="dark" ;;
        TintedLight) rendition_name="tinted-light" ;;
        TintedDark) rendition_name="tinted-dark" ;;
        ClearLight) rendition_name="clear-light" ;;
        ClearDark) rendition_name="clear-dark" ;;
        *)
            echo "error: unsupported rendition $rendition" >&2
            return 1
            ;;
    esac

    destination="$output_root/macos-${generation}/${rendition_name}-${size}.png"
    arguments=(
        "$icon_path"
        --export-image
        --output-file "$destination"
        --platform macOS
        --rendition "$rendition"
        --width "$size"
        --height "$size"
        --scale 1
        --design-generation "$generation"
    )

    if [[ "$rendition" == Tinted* ]]; then
        arguments+=(--tint-color 0.46 --tint-strength 0.72)
    fi

    "$icon_tool" "${arguments[@]}"
}

for generation in 26 27; do
    mkdir -p "$output_root/macos-${generation}"

    for rendition in Default Dark TintedLight TintedDark ClearLight ClearDark; do
        for size in 16 32 64 128 512; do
            export_icon "$generation" "$rendition" "$size"
        done
    done
done

echo "Exported Icon Composer previews to $output_root"
