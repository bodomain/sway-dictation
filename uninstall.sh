#!/usr/bin/env bash

set -euo pipefail

readonly BEGIN_MARKER="# BEGIN sway-openai-dictation"
readonly END_MARKER="# END sway-openai-dictation"

purge=false
reload_sway=true

while (($#)); do
    case "$1" in
        --purge)
            purge=true
            shift
            ;;
        --no-reload)
            reload_sway=false
            shift
            ;;
        -h|--help)
            printf 'Usage: ./uninstall.sh [--purge] [--no-reload]\n'
            printf '  --purge also removes the saved OpenAI credential.\n'
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            exit 2
            ;;
    esac
done

readonly CONFIG_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}"
readonly DATA_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}"
readonly BIN_HOME="${XDG_BIN_HOME:-${HOME}/.local/bin}"
readonly APP_CONFIG_DIR="${CONFIG_HOME}/sway-openai-dictation"
readonly APP_DATA_DIR="${DATA_HOME}/sway-openai-dictation"
readonly INSTALL_BIN="${BIN_HOME}/sway-openai-dictation"
readonly SWAY_CONFIG="${SWAY_CONFIG_FILE:-${CONFIG_HOME}/sway/config}"
readonly SWAY_SNIPPET="${CONFIG_HOME}/sway/openai-dictation.conf"

if [[ -f "$SWAY_CONFIG" ]] && grep -Fqx "$BEGIN_MARKER" "$SWAY_CONFIG"; then
    config_tmp="$(mktemp)"
    awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '
        $0 == begin { skipping = 1; next }
        $0 == end { skipping = 0; next }
        !skipping { print }
    ' "$SWAY_CONFIG" >"$config_tmp"
    cat "$config_tmp" >"$SWAY_CONFIG"
    rm -f "$config_tmp"
fi

rm -f "$INSTALL_BIN" "$SWAY_SNIPPET"
rm -f "${APP_DATA_DIR}/start.wav" "${APP_DATA_DIR}/stop.wav"
rmdir "$APP_DATA_DIR" 2>/dev/null || true
rm -f "${APP_CONFIG_DIR}/model" "${APP_CONFIG_DIR}/correction"

if [[ "$purge" == true ]]; then
    rm -f "${APP_CONFIG_DIR}/openai.env"
    rmdir "$APP_CONFIG_DIR" 2>/dev/null || true
else
    printf 'Preserved credential file: %s/openai.env\n' "$APP_CONFIG_DIR"
fi

if command -v sway >/dev/null 2>&1 && [[ -f "$SWAY_CONFIG" ]]; then
    sway -C -c "$SWAY_CONFIG"
fi
if [[ "$reload_sway" == true ]] && command -v swaymsg >/dev/null 2>&1 && swaymsg -t get_version >/dev/null 2>&1; then
    swaymsg reload >/dev/null
fi

printf 'Uninstalled sway-openai-dictation.\n'
