# sway-openai-dictation

Push-to-talk dictation for Sway using OpenAI speech-to-text. Hold one physical
key to record, release it to transcribe, and the result is typed at the active
caret in the focused application.

## Features

- Works in terminals, Obsidian, browsers, editors, and other Wayland apps.
- High start cue before microphone capture; lower stop cue after capture ends.
- Uses OpenAI's `gpt-4o-mini-transcribe` model by default.
- Never presses Enter or submits the resulting text.
- Records the focused Sway container on key-down. If focus changes while the
  API request is running, the transcription is copied instead of typed.
- Stores temporary audio in the private per-user runtime directory and removes
  it after processing.
- User-level, idempotent installer with no daemon or root service.

## Requirements

- Sway
- PipeWire tools (`pw-record` and `pw-play`)
- `wtype`
- `curl`, `jq`, `wl-copy`, `notify-send`, `flock`, and `setsid`
- An OpenAI API key with access to audio transcriptions

Package names vary by distribution. The installer can install them on Debian,
Fedora, or Arch:

```bash
./install.sh --install-deps
```

This option uses `sudo` and the system package manager. Without it, the
installer reports any missing commands and makes no package changes.

## Install

```bash
git clone <repository-url> sway-openai-dictation
cd sway-openai-dictation
./install.sh
```

The interactive installer prompts for the OpenAI key without echoing it. To
migrate a key from an existing env file:

```bash
./install.sh --api-key-source ~/.env
```

The source file must contain either `OPENAI_API_KEY=...` or
`export OPENAI_API_KEY=...`. It is parsed as data and never executed.

Useful options:

```bash
./install.sh --keycode 105
./install.sh --model gpt-4o-mini-transcribe
./install.sh --no-reload
./install.sh --help
```

The installer:

1. checks dependencies;
2. copies the command and sound assets under `~/.local`;
3. stores the API key in a mode-`600` file;
4. installs one Sway snippet;
5. adds one marked `include` block to the main Sway config;
6. validates the complete Sway config before reloading it.

It creates a timestamped Sway-config backup before adding the include block.
Running the installer again updates the installation without duplicating the
block.

## Use

Place the caret in a text field, hold physical keycode `105`, speak after the
high tone, then release the key. The low tone confirms capture has ended.
Transcription takes a moment and then appears as editable text.

Hold **Shift + Right Ctrl** (press Shift first) for raw dictation that skips the
correction API. Ordinary **Right Ctrl** uses your correction on/off preference.
The raw choice is saved when recording starts and does not change that preference.
Both modified and unmodified Right Ctrl releases stop the same recording.

The compositor cannot determine whether a caret is actually active. If no text
field is selected, simulated keys may trigger application shortcuts. Focus a
text field before recording.

Check the installation:

```bash
~/.local/bin/sway-openai-dictation check
```

## Installed files

```text
~/.local/bin/sway-openai-dictation
~/.local/share/sway-openai-dictation/start.wav
~/.local/share/sway-openai-dictation/stop.wav
~/.config/sway-openai-dictation/openai.env
~/.config/sway-openai-dictation/model
~/.config/sway/openai-dictation.conf
```

Runtime state and logs live under
`$XDG_RUNTIME_DIR/sway-openai-dictation/`. Audio and API response files are
deleted after each completed request.

## Configuration

- Re-run `install.sh --keycode NUMBER` to change the physical key.
- Re-run `install.sh --model MODEL` to change the transcription model.
- Set `OPENAI_TRANSCRIBE_MODEL` to override the installed model temporarily.
- Set `OPENAI_API_KEY` to override the credential file temporarily.
- Replace `start.wav` and `stop.wav` in the installed data directory to use
  custom cues.

The API request uses OpenAI's
[`POST /v1/audio/transcriptions`](https://developers.openai.com/api/reference/resources/audio/subresources/transcriptions/methods/create)
endpoint. API usage may incur charges on the associated OpenAI project.

## Optional transcript corrections

Use the same hold-to-talk key with an optional proofreading pass:

```bash
sway-openai-dictation correction on
sway-openai-dictation correction off
sway-openai-dictation correction status
```

The setting persists immediately; no Sway reload is needed. New installations
start with corrections off. When enabled, the transcript is sent to OpenAI's
Responses API using `gpt-5.4-nano` and the existing API key. It corrects spelling,
grammar and punctuation while being instructed to preserve language, meaning,
names and technical terms. Corrected words begin appearing as they arrive;
the full corrected text is copied when the response completes. Window focus is
checked before each chunk. If you switch windows, typing stops and the complete
result is kept in the clipboard.

This adds an API request and some latency per dictation. Requests use
`store: false`. Errors, timeouts (30 seconds), empty output or incomplete output
fall back to the original transcript if nothing has been typed. If a connection
fails after some corrected text has appeared, the original is copied to the
clipboard and a notification asks you to replace the partial text manually;
the program never appends a duplicate transcript. Temporary response files are
removed. Set `OPENAI_CORRECTION_STREAM=0` in the dictation process environment
to use the previous buffered behavior. Streaming reduces the wait for the first
words; it does not guarantee a faster full response.

Set `OPENAI_CORRECTION_MODEL` in the dictation process environment to override
the model (must support Responses with `reasoning.effort: none`). Model output
can still make mistakes; review important names and numbers.

## Troubleshooting

Run the setup check first:

```bash
~/.local/bin/sway-openai-dictation check
```

Then inspect the per-session log:

```bash
less "$XDG_RUNTIME_DIR/sway-openai-dictation/dictation.log"
```

Common issues:

- No tone: verify the default PipeWire output and run
  `pw-play ~/.local/share/sway-openai-dictation/start.wav`.
- No recording: inspect `wpctl status` and the default audio source.
- Text is copied instead of typed: focus changed during transcription or
  `wtype` could not connect to Sway's virtual-keyboard protocol.
- API failure: verify the key, project billing, model access, and network.

## Uninstall

```bash
./uninstall.sh
```

The credential is preserved by default. Remove it too with:

```bash
./uninstall.sh --purge
```

## Development

The integration test uses a temporary fake home and mocked Sway, PipeWire,
OpenAI, clipboard, and Wayland typing commands. It does not access a real
microphone, API key, or compositor.

```bash
./tests/integration-test.sh
bash ./tests/streaming-test.sh
shellcheck bin/sway-openai-dictation install.sh uninstall.sh tests/integration-test.sh tests/streaming-test.sh
```

## Security and privacy

- Never commit `openai.env` or an API key.
- The installed credential is readable only by its owner.
- Recordings are sent to OpenAI for transcription.
- Temporary recordings are private and deleted after processing.
- The installer never executes an env file supplied with
  `--api-key-source`.

## License

MIT
# sway-dictation
