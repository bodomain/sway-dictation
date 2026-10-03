#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly REPO_DIR
readonly BEGIN_MARKER="# BEGIN sway-openai-dictation"
readonly END_MARKER="# END sway-openai-dictation"

keycode=105
model="gpt-4o-mini-transcribe"
api_key_source=""
install_deps=false
reload_sway=true
prompt_for_key=true

usage() {
    cat <<'EOF'
Usage: ./install.sh [options]

Options:
  --keycode NUMBER        Physical Sway keycode to bind (default: 105)
  --model MODEL           OpenAI transcription model
  --api-key-source FILE   Read OPENAI_API_KEY from an existing env file
  --install-deps          Install missing packages using apt, dnf, or pacman
  --no-key-prompt         Do not prompt for a missing API key
  --no-reload             Do not reload a running Sway session
  -h, --help              Show this help
EOF
}

while (($#)); do
    case "$1" in
        --keycode)
            keycode="${2:?--keycode requires a value}"
            shift 2
            ;;
        --model)
            model="${2:?--model requires a value}"
            shift 2
            ;;
        --api-key-source)
            api_key_source="${2:?--api-key-source requires a file}"
            shift 2
            ;;
        --install-deps)
            install_deps=true
            shift
            ;;
        --no-key-prompt)
            prompt_for_key=false
            shift
            ;;
        --no-reload)
            reload_sway=false
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ ! "$keycode" =~ ^[0-9]+$ ]] || ((keycode < 1 || keycode > 767)); then
    printf 'Invalid keycode: %s\n' "$keycode" >&2
    exit 2
fi
if [[ -z "$model" || "$model" == *$'\n'* || "$model" == *$'\r'* ]]; then
    printf 'Invalid transcription model.\n' >&2
    exit 2
fi

readonly CONFIG_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}"
readonly DATA_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}"
readonly BIN_HOME="${XDG_BIN_HOME:-${HOME}/.local/bin}"
readonly APP_CONFIG_DIR="${CONFIG_HOME}/sway-openai-dictation"
readonly APP_DATA_DIR="${DATA_HOME}/sway-openai-dictation"
readonly INSTALL_BIN="${BIN_HOME}/sway-openai-dictation"
readonly KEY_FILE="${APP_CONFIG_DIR}/openai.env"
readonly MODEL_FILE="${APP_CONFIG_DIR}/model"
readonly SWAY_CONFIG="${SWAY_CONFIG_FILE:-${CONFIG_HOME}/sway/config}"
readonly SWAY_SNIPPET="${CONFIG_HOME}/sway/openai-dictation.conf"

missing_dependencies() {
    local dependency
    for dependency in sway swaymsg pw-record pw-play curl jq wl-copy notify-send flock setsid stat; do
        command -v "$dependency" >/dev/null 2>&1 || printf '%s\n' "$dependency"
    done
    if ! command -v wtype >/dev/null 2>&1 && [[ ! -x "${HOME}/.local/opt/wtype/usr/bin/wtype" ]]; then
        printf 'wtype\n'
    fi
}

install_dependencies() {
    local privilege=()
    if ((EUID != 0)); then
        if ! command -v sudo >/dev/null 2>&1; then
            printf 'sudo is required for --install-deps.\n' >&2
            return 1
        fi
        privilege=(sudo)
    fi

    if command -v apt-get >/dev/null 2>&1; then
        "${privilege[@]}" apt-get update
        "${privilege[@]}" apt-get install -y sway pipewire-bin curl jq wl-clipboard libnotify-bin wtype util-linux
    elif command -v dnf >/dev/null 2>&1; then
        "${privilege[@]}" dnf install -y sway pipewire-utils curl jq wl-clipboard libnotify wtype util-linux
    elif command -v pacman >/dev/null 2>&1; then
        "${privilege[@]}" pacman -S --needed sway pipewire curl jq wl-clipboard libnotify wtype util-linux
    else
        printf 'Unsupported package manager. Install the dependencies listed in README.md.\n' >&2
        return 1
    fi
}

mapfile -t missing < <(missing_dependencies)
if ((${#missing[@]})); then
    if [[ "$install_deps" == true ]]; then
        install_dependencies
        mapfile -t missing < <(missing_dependencies)
    fi
    if ((${#missing[@]})); then
        printf 'Missing dependencies: %s\n' "${missing[*]}" >&2
        printf 'Re-run with --install-deps or install them using your package manager.\n' >&2
        exit 1
    fi
fi

if [[ ! -f "$SWAY_CONFIG" ]]; then
    printf 'Sway config not found: %s\n' "$SWAY_CONFIG" >&2
    exit 1
fi

extract_api_key() {
    local source_file="$1" line value
    [[ -r "$source_file" ]] || return 1

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        case "$line" in
            OPENAI_API_KEY=*) value="${line#OPENAI_API_KEY=}" ;;
            export\ OPENAI_API_KEY=*) value="${line#export OPENAI_API_KEY=}" ;;
            *) continue ;;
        esac
        if [[ "$value" == \"*\" && "$value" == *\" ]]; then
            value="${value:1:${#value}-2}"
        elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
            value="${value:1:${#value}-2}"
        fi
        [[ -n "$value" ]] || continue
        printf '%s' "$value"
        return 0
    done <"$source_file"
    return 1
}

write_api_key() {
    local api_key="$1" key_tmp
    [[ -n "$api_key" ]] || return 1
    key_tmp="$(mktemp "${APP_CONFIG_DIR}/.openai.env.XXXXXX")"
    chmod 600 "$key_tmp"
    printf 'OPENAI_API_KEY=%s\n' "$api_key" >"$key_tmp"
    mv "$key_tmp" "$KEY_FILE"
    chmod 600 "$KEY_FILE"
}

install -d -m 755 "$BIN_HOME" "$APP_DATA_DIR" "${CONFIG_HOME}/sway"
install -d -m 700 "$APP_CONFIG_DIR"
install -m 755 "${REPO_DIR}/bin/sway-openai-dictation" "$INSTALL_BIN"
install -m 644 "${REPO_DIR}/assets/start.wav" "${APP_DATA_DIR}/start.wav"
install -m 644 "${REPO_DIR}/assets/stop.wav" "${APP_DATA_DIR}/stop.wav"
printf '%s\n' "$model" >"$MODEL_FILE"
chmod 644 "$MODEL_FILE"

api_key=""
if [[ -n "$api_key_source" ]]; then
    if ! api_key="$(extract_api_key "$api_key_source")"; then
        printf 'No OPENAI_API_KEY found in %s\n' "$api_key_source" >&2
        exit 1
    fi
elif [[ -n "${OPENAI_API_KEY:-}" ]]; then
    api_key="$OPENAI_API_KEY"
elif [[ ! -f "$KEY_FILE" && "$prompt_for_key" == true && -t 0 ]]; then
    read -r -s -p 'OpenAI API key: ' api_key
    printf '\n'
fi

if [[ -n "$api_key" ]]; then
    write_api_key "$api_key"
elif [[ ! -s "$KEY_FILE" ]]; then
    printf 'Warning: no API key installed. Re-run with --api-key-source or set OPENAI_API_KEY.\n' >&2
fi
unset api_key

escaped_binary="${INSTALL_BIN//\\/\\\\}"
escaped_binary="${escaped_binary//&/\\&}"
escaped_binary="${escaped_binary//|/\\|}"
snippet_tmp="$(mktemp "${CONFIG_HOME}/sway/.openai-dictation.conf.XXXXXX")"
sed -e "s|@KEYCODE@|${keycode}|g" -e "s|@BINARY@|${escaped_binary}|g" \
    "${REPO_DIR}/sway/openai-dictation.conf.in" >"$snippet_tmp"
chmod 644 "$snippet_tmp"
mv "$snippet_tmp" "$SWAY_SNIPPET"

backup_file=""
if ! grep -Fqx "$BEGIN_MARKER" "$SWAY_CONFIG"; then
    backup_file="${SWAY_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
    cp -L -p "$SWAY_CONFIG" "$backup_file"
    {
        printf '\n%s\n' "$BEGIN_MARKER"
        printf 'include "%s"\n' "$SWAY_SNIPPET"
        printf '%s\n' "$END_MARKER"
    } >>"$SWAY_CONFIG"
fi

if ! sway -C -c "$SWAY_CONFIG"; then
    printf 'Sway validation failed. The previous config is available at %s\n' "${backup_file:-no new backup}" >&2
    exit 1
fi

if [[ "$reload_sway" == true ]]; then
    if swaymsg -t get_version >/dev/null 2>&1; then
        swaymsg reload >/dev/null
        printf 'Reloaded Sway.\n'
    else
        printf 'No running Sway IPC session found; reload Sway later.\n'
    fi
fi

printf 'Installed sway-openai-dictation.\n'
printf '  command: %s\n' "$INSTALL_BIN"
printf '  Sway binding: physical keycode %s\n' "$keycode"
printf '  model: %s\n' "$model"
printf 'Run "%s check" to verify the setup.\n' "$INSTALL_BIN"
