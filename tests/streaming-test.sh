#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/bin" "$root/config" "$root/state"
printf 'on\n' >"$root/config/correction"
export STREAM_TEST_ROOT="$root"
export SWAY_OPENAI_DICTATION_CONFIG_DIR="$root/config"
export SWAY_OPENAI_DICTATION_STATE_DIR="$root/state"
export SWAY_OPENAI_DICTATION_WTYPE="$root/bin/wtype"
export OPENAI_API_KEY=test-only-key
export OPENAI_CORRECTION_STREAM=1
export PATH="$root/bin:$PATH"
cat >"$root/bin/curl" <<'MOCK'
#!/usr/bin/env bash
output=""
while (($#)); do
    if [[ "$1" == --output ]]; then output="$2"; shift 2; else shift; fi
done
if [[ -n "$output" ]]; then
    printf '%s' '{"text":"original transcript"}' >"$output"
    printf 200
    exit
fi
request=$(cat)
jq -e '.stream == true and .store == false' <<<"$request" >/dev/null || exit 90
case "$STREAM_CASE" in
    early_error) exit 22 ;;
    malformed) printf 'data: {bad json}\n\n'; exit ;;
    empty) printf 'data: {"type":"response.completed","response":{"status":"completed"}}\n\n'; exit ;;
esac
printf 'data: {"type":"response.output_text.delta","delta":"Corrected "}\n\n'
# A deterministic handshake: buffered implementations cannot pass this test.
for _ in {1..100}; do
    [[ -s "$STREAM_TEST_ROOT/typed" || "$STREAM_CASE" == focus_before ]] && break
    sleep 0.01
done
if [[ ! -s "$STREAM_TEST_ROOT/typed" && "$STREAM_CASE" != focus_before ]]; then exit 91; fi
case "$STREAM_CASE" in
    partial_error) exit 28 ;;
    incomplete) printf 'data: {"type":"response.incomplete"}\n\n'; exit ;;
    focus_after) touch "$STREAM_TEST_ROOT/moved" ;;
esac
printf 'data: {"type":"response.output_text.delta","delta":"text.\\n"}\r\n\r\n'
printf 'data: {"type":"response.completed","response":{"status":"completed"}}\n\n'
MOCK
cat >"$root/bin/swaymsg" <<'MOCK'
#!/usr/bin/env bash
id=42
[[ "$STREAM_CASE" != focus_before && ! -f "$STREAM_TEST_ROOT/moved" ]] || id=99
printf '{"id":%s,"focused":true}\n' "$id"
MOCK
cat >"$root/bin/wtype" <<'MOCK'
#!/usr/bin/env bash
cat >>"$STREAM_TEST_ROOT/typed"
[[ "$STREAM_CASE" != typing_error ]]
MOCK
cat >"$root/bin/wl-copy" <<'MOCK'
#!/usr/bin/env bash
cat >"$STREAM_TEST_ROOT/clipboard"
MOCK
cat >"$root/bin/notify-send" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$root/bin/"*
for scenario in success early_error malformed empty partial_error incomplete focus_before focus_after typing_error; do
    export STREAM_CASE="$scenario"
    rm -f "$root/typed" "$root/clipboard" "$root/moved"
    bash -c 'source <(sed '\''/^case "${1:-}" in/,$d'\'' "$1"); transcribe_audio "$STATE_DIR/test.wav" 42' _ "${DICTATION_TEST_BIN:-$REPO_DIR/bin/sway-openai-dictation}"
    typed=""; [[ ! -f "$root/typed" ]] || typed=$(cat "$root/typed")
    clipboard=$(cat "$root/clipboard")
    expected='Corrected text. '
    expected_clipboard="$expected"
    case "$scenario" in
        early_error|malformed|empty) expected='original transcript'; expected_clipboard="$expected" ;;
        partial_error|incomplete) expected='Corrected '; expected_clipboard='original transcript' ;;
        focus_before) expected='' ;;
        focus_after|typing_error) expected='Corrected ' ;;
    esac
    [[ "$typed" == "$expected" ]] || { printf 'FAIL %s: unexpected typed text <%s>\n' "$scenario" "$typed"; exit 1; }
    [[ "$clipboard" == "$expected_clipboard" ]] || { printf 'FAIL %s: unexpected clipboard\n' "$scenario"; exit 1; }
    printf 'PASS: streaming %s\n' "$scenario"
done
