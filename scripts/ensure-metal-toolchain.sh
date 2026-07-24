#!/bin/bash
# Install Xcode's separately distributed Metal toolchain when it is absent.
# `xcodebuild -showComponent` can exit successfully while reporting
# `{"status":"uninstalled"}`, so the JSON status is authoritative.
set -euo pipefail

MAX_ATTEMPTS="${METAL_TOOLCHAIN_MAX_ATTEMPTS:-3}"
RETRY_DELAY_SECONDS="${METAL_TOOLCHAIN_RETRY_DELAY_SECONDS:-10}"

case "$MAX_ATTEMPTS" in
    [1-9]|[1-9][0-9]*)
        ;;
    *)
        echo "::error::METAL_TOOLCHAIN_MAX_ATTEMPTS must be a positive integer"
        exit 2
        ;;
esac

case "$RETRY_DELAY_SECONDS" in
    0|[1-9]|[1-9][0-9]*)
        ;;
    *)
        echo "::error::METAL_TOOLCHAIN_RETRY_DELAY_SECONDS must be a non-negative integer"
        exit 2
        ;;
esac

if ! command -v jq >/dev/null 2>&1; then
    echo "::error::jq is required to inspect the Metal Toolchain status"
    exit 2
fi

metal_toolchain_status() {
    local component_json
    local component_status

    if ! component_json="$(xcodebuild -showComponent MetalToolchain -json 2>/dev/null)"; then
        echo "unknown"
        return
    fi

    if component_status="$(
        printf '%s\n' "$component_json" \
            | jq -er '.status | select(type == "string")' 2>/dev/null
    )" && [ -n "$component_status" ]; then
        echo "$component_status"
    else
        echo "unknown"
    fi
}

metal_toolchain_is_installed() {
    case "$1" in
        installed|installedUpdateAvailable)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

status="$(metal_toolchain_status)"
# IDEFoundation treats both statuses as usable installed components.
if metal_toolchain_is_installed "$status"; then
    echo "Metal Toolchain is already installed"
    exit 0
fi

for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
    echo "Downloading Metal Toolchain (attempt $attempt of $MAX_ATTEMPTS; current status: $status)"

    if xcodebuild -downloadComponent MetalToolchain; then
        download_succeeded=true
    else
        download_succeeded=false
    fi

    # The component may be installed even if xcodebuild reports a late error,
    # so query the authoritative status after every attempt, including the last.
    status="$(metal_toolchain_status)"
    if metal_toolchain_is_installed "$status"; then
        echo "Metal Toolchain installed successfully"
        exit 0
    fi

    if [ "$download_succeeded" = true ]; then
        echo "::warning::Metal Toolchain download completed but status is '$status'"
    else
        echo "::warning::Metal Toolchain download command failed; status is '$status'"
    fi

    if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
        echo "Retrying in $RETRY_DELAY_SECONDS seconds"
        sleep "$RETRY_DELAY_SECONDS"
        status="$(metal_toolchain_status)"
        if metal_toolchain_is_installed "$status"; then
            echo "Metal Toolchain installed successfully"
            exit 0
        fi
    fi
done

echo "::error::Metal Toolchain is not installed after $MAX_ATTEMPTS attempts (status: $status)"
exit 1
