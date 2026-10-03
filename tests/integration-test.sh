#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly REPO_DIR
test_root="$(mktemp -d)"
recorder_pid=""

cleanup() {
    if [[ -n "$recorder_pid" ]]; then
        kill -TERM "$recorder_pid" 2>/dev/null || true
    fi
    rm -rf "$test_root"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

readonly TEST_HOME="${test_root}/home"
readonly TEST_CONFIG="${test_root}/config"
readonly TEST_DATA="${test_root}/data"
readonly TEST_RUNTIME="${test_root}/runtime"
readonly FAKE_BIN="${test_root}/fake-bin"
readonly EVENTS="${test_root}/events"

mkdir -p "${TEST_HOME}/dotfiles" "${TEST_CONFIG}/sway" "$TEST_DATA" "$TEST_RUNTIME" "$FAKE_BIN"
printf 'set %smod Mod4\n' '$' >"${TEST_HOME}/dotfiles/sway-config"
ln -s "${TEST_HOME}/dotfiles/sway-config" "${TEST_CONFIG}/sway/config"
printf 'OPENAI_API_KEY=test-only-key\n' >"${test_root}/source.env"

cat >"${FAKE_BIN}/sway" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"${FAKE_BIN}/swaymsg" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *get_tree* ]]; then
    printf '%s\n' '{"id":42,"focused":true,"app_id":"obsidian","nodes":[]}'
else
    printf '%s\n' '[{"success":true}]'
fi
EOF

cat >"${FAKE_BIN}/pw-play" <<EOF
#!/usr/bin/env bash
printf 'cue:%s\n' "\$(basename "\${*: -1}")" >>"$EVENTS"
EOF

cat >"${FAKE_BIN}/pw-record" <<EOF
#!/usr/bin/env bash
audio_file="\${*: -1}"
printf 'record\n' >>"$EVENTS"
dd if=/dev/zero of="\$audio_file" bs=256 count=1 status=none
exec sleep 60
EOF

cat >"${FAKE_BIN}/curl" <<'EOF'
#!/usr/bin/env bash
output_file=""
correction=false
while (($#)); do
    case "$1" in
        --output) output_file="$2"; shift 2 ;;
        https://api.openai.com/v1/responses) correction=true; shift ;;
        *) shift ;;
    esac
done
if [[ "$correction" == true ]]; then
    cat >"$TEST_REQUEST"
    case "${TEST_CORRECTION:-ok}" in
        ok) printf '%s' '{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"Portable integration test."}]}]}' >"$output_file" ;;
        error) printf '{}' >"$output_file"; printf '500'; exit 0 ;;
        timeout) exit 28 ;;
        incomplete) printf '%s' '{"status":"incomplete","output":[{"type":"message","content":[{"type":"output_text","text":"Partial"}]}]}' >"$output_file" ;;
        empty) printf '%s' '{"status":"completed","output":[]}' >"$output_file" ;;
        malformed) printf 'bad json' >"$output_file" ;;
    esac
else
    printf '%s\n' '{"text":"portable integration test"}' >"$output_file"
fi
printf '200'
EOF

cat >"${FAKE_BIN}/wtype" <<EOF
#!/usr/bin/env bash
cat >"${test_root}/typed"
EOF

cat >"${FAKE_BIN}/wl-copy" <<EOF
#!/usr/bin/env bash
cat >"${test_root}/clipboard"
EOF

cat >"${FAKE_BIN}/notify-send" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod 755 "${FAKE_BIN}"/*

export OPENAI_CORRECTION_STREAM=0
export TEST_REQUEST="${test_root}/correction-request.json"
export HOME="$TEST_HOME"
export XDG_CONFIG_HOME="$TEST_CONFIG"
export XDG_DATA_HOME="$TEST_DATA"
export XDG_RUNTIME_DIR="$TEST_RUNTIME"
export PATH="${FAKE_BIN}:/usr/bin:/bin"

"${REPO_DIR}/install.sh" --keycode 105 --api-key-source "${test_root}/source.env" --no-reload

readonly INSTALLED_BIN="${TEST_HOME}/.local/bin/sway-openai-dictation"
readonly KEY_FILE="${TEST_CONFIG}/sway-openai-dictation/openai.env"
readonly SNIPPET="${TEST_CONFIG}/sway/openai-dictation.conf"

[[ -x "$INSTALLED_BIN" ]] || fail "binary was not installed"
[[ -f "$SNIPPET" ]] || fail "Sway snippet was not installed"
[[ -L "${TEST_CONFIG}/sway/config" ]] || fail "installer replaced the Sway config symlink"
[[ "$(stat -c %a "$KEY_FILE")" == 600 ]] || fail "credential mode is not 600"
grep -Fq 'bindcode --no-repeat 105' "$SNIPPET" || fail "press binding is missing"
grep -Fq 'bindcode --release --no-repeat 105' "$SNIPPET" || fail "release binding is missing"
[[ "$(grep -Fc '# BEGIN sway-openai-dictation' "${TEST_CONFIG}/sway/config")" == 1 ]] || fail "managed include count is wrong"

# A second install must update in place without duplicating the include block.
"${REPO_DIR}/install.sh" --keycode 105 --api-key-source "${test_root}/source.env" --no-reload >/dev/null
[[ "$(grep -Fc '# BEGIN sway-openai-dictation' "${TEST_CONFIG}/sway/config")" == 1 ]] || fail "installer is not idempotent"

"$INSTALLED_BIN" check >/dev/null
"$INSTALLED_BIN" start
IFS=$'\t' read -r recorder_pid _ <"${TEST_RUNTIME}/sway-openai-dictation/current"
kill -TERM "$recorder_pid"
for _ in {1..100}; do
    kill -0 "$recorder_pid" 2>/dev/null || break
    sleep 0.01
done
"$INSTALLED_BIN" stop
recorder_pid=""

[[ "$(<"${test_root}/typed")" == 'portable integration test' ]] || fail "transcription was not typed"
[[ "$(<"${test_root}/clipboard")" == 'portable integration test' ]] || fail "clipboard fallback was not populated"
[[ "$(sed -n '1p' "$EVENTS")" == 'cue:start.wav' ]] || fail "start cue did not play first"
[[ "$(sed -n '2p' "$EVENTS")" == 'record' ]] || fail "recording did not start after the cue"
[[ "$(sed -n '3p' "$EVENTS")" == 'cue:stop.wav' ]] || fail "stop cue did not follow recording"
[[ ! -e "${TEST_RUNTIME}/sway-openai-dictation/current" ]] || fail "active state was not removed"

[[ ! -e "$TEST_REQUEST" ]] || fail "correction ran while disabled"
"$INSTALLED_BIN" correction on
[[ "$("$INSTALLED_BIN" correction status)" == 'Corrections: on'* ]] || fail "correction setting not persisted"
for outcome in ok error timeout incomplete empty malformed; do
    export TEST_CORRECTION="$outcome"
    "$INSTALLED_BIN" start
    IFS=$'\t' read -r recorder_pid _ <"${TEST_RUNTIME}/sway-openai-dictation/current"
    kill -TERM "$recorder_pid"
    for _ in {1..100}; do
        kill -0 "$recorder_pid" 2>/dev/null || break
        sleep 0.01
    done
    "$INSTALLED_BIN" stop
    recorder_pid=""
    expected='portable integration test'
    [[ "$outcome" != ok ]] || expected='Portable integration test.'
    [[ "$(<"${test_root}/typed")" == "$expected" ]] || fail "wrong correction result for $outcome"
    [[ "$(<"${test_root}/clipboard")" == "$expected" ]] || fail "wrong clipboard for $outcome"
    compgen -G "${TEST_RUNTIME}/sway-openai-dictation/*.json" >/dev/null && fail "response files were not removed"
    jq -e '.input == "portable integration test" and .store == false and .model == "gpt-5.4-nano"' "$TEST_REQUEST" >/dev/null || fail "invalid correction request"
done
# The mode is captured at key-down, so modifier release order cannot change it.
rm -f "$TEST_REQUEST"
"$INSTALLED_BIN" start raw
IFS=$'\t' read -r recorder_pid _ <"${TEST_RUNTIME}/sway-openai-dictation/current"
[[ "$(cut -f6 "${TEST_RUNTIME}/sway-openai-dictation/current")" == off ]] || fail "raw mode was not saved"
kill -TERM "$recorder_pid"
for _ in {1..100}; do
    kill -0 "$recorder_pid" 2>/dev/null || break
    sleep 0.01
done
"$INSTALLED_BIN" stop
recorder_pid=""
[[ ! -e "$TEST_REQUEST" ]] || fail "raw dictation called correction API"
[[ "$(<"${test_root}/typed")" == 'portable integration test' ]] || fail "raw transcript was not typed"
[[ "$("$INSTALLED_BIN" correction status)" == 'Corrections: on'* ]] || fail "raw mode changed global preference"
grep -Fq 'bindcode --no-repeat Shift+105' "$SNIPPET" || fail "raw press binding is missing"
grep -Fq 'bindcode --release --no-repeat Shift+105' "$SNIPPET" || fail "raw release binding is missing"

"$INSTALLED_BIN" correction off
[[ "$("$INSTALLED_BIN" correction status)" == 'Corrections: off'* ]] || fail "corrections did not disable"

"${REPO_DIR}/uninstall.sh" --no-reload >/dev/null
[[ ! -e "$INSTALLED_BIN" ]] || fail "binary was not uninstalled"
[[ -f "$KEY_FILE" ]] || fail "credential was not preserved"
[[ -L "${TEST_CONFIG}/sway/config" ]] || fail "uninstaller replaced the Sway config symlink"
! grep -Fq '# BEGIN sway-openai-dictation' "${TEST_CONFIG}/sway/config" || fail "managed include was not removed"

"${REPO_DIR}/uninstall.sh" --purge --no-reload >/dev/null
[[ ! -e "$KEY_FILE" ]] || fail "credential was not purged"

printf 'PASS: isolated install, idempotency, dictation flow, cue order, and uninstall\n'
