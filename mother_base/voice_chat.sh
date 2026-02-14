#!/usr/bin/env bash
set -euo pipefail

# =========================
# voice_chat.sh
# Simple voice conversation loop:
# Mic -> Whisper -> Ollama (chat) -> Piper TTS -> Speaker
#
# Ctrl+C to exit
# =========================

# ---- Config ----
MIC_DEV="${MIC_DEV:-plughw:0,0}"
RATE=16000
RECORD_SEC="${RECORD_SEC:-6}"
GAIN_DB="${GAIN_DB:-15}"

WORKDIR="${WORKDIR:-/tmp/voice_chat}"
mkdir -p "$WORKDIR"

RAW="$WORKDIR/raw.wav"
CLEAN="$WORKDIR/clean.wav"

# Whisper
WHISPER_DIR="$HOME/whisper.cpp"
WHISPER_BIN="$WHISPER_DIR/build/bin/whisper-cli"
WHISPER_MODEL="$WHISPER_DIR/models/ggml-base.bin"

# Ollama
OLLAMA_URL="http://127.0.0.1:11434/api/generate"
MODEL="gemma3:latest"

# Piper (human voice)
PIPER_BIN="/usr/local/bin/piper"
TTS_VOICE="/home/futung/piper/voices/en_US-amy-medium.onnx"
AUDIO_DEV="default"

# ---- Checks ----
command -v arecord >/dev/null || exit 1
command -v sox >/dev/null || exit 1
command -v jq >/dev/null || exit 1
command -v curl >/dev/null || exit 1
command -v aplay >/dev/null || exit 1

[[ -x "$WHISPER_BIN" ]] || { echo "Whisper not found"; exit 1; }
[[ -f "$WHISPER_MODEL" ]] || { echo "Whisper model missing"; exit 1; }
[[ -x "$PIPER_BIN" ]] || { echo "Piper missing"; exit 1; }
[[ -f "$TTS_VOICE" ]] || { echo "TTS voice missing"; exit 1; }

echo "🎙 Voice chat started"
echo "Speak naturally. Ctrl+C to exit."
echo

# ---- Loop ----
while true; do
  echo "Listening..."
  arecord -D "$MIC_DEV" -f S16_LE -r "$RATE" -c 1 -d "$RECORD_SEC" "$RAW" >/dev/null 2>&1 || continue
  sox "$RAW" "$CLEAN" gain "$GAIN_DB" >/dev/null 2>&1 || continue

  echo "Transcribing..."
  TEXT="$(
    cd "$WHISPER_DIR"
    "$WHISPER_BIN" -m "$WHISPER_MODEL" -f "$CLEAN" -nt 2>/dev/null
  )"

  TEXT="$(echo "$TEXT" | sed 's/^[ \t]*//;s/[ \t]*$//')"
  [[ -z "$TEXT" ]] && continue

  echo "You: $TEXT"

  echo "Thinking..."
  RESP="$(
    curl -s "$OLLAMA_URL" \
      -H "Content-Type: application/json" \
      -d "$(jq -n \
        --arg model "$MODEL" \
        --arg prompt "$TEXT" \
        '{model:$model, prompt:$prompt, stream:false}')"
  )"

  ANSWER="$(echo "$RESP" | jq -r '.response // empty')"
  [[ -z "$ANSWER" ]] && continue

  echo "Bot: $ANSWER"

  echo "Speaking..."
  printf "%s" "$ANSWER" | "$PIPER_BIN" --model "$TTS_VOICE" --output_file "$WORKDIR/tts.wav" >/dev/null 2>&1
  aplay -D "$AUDIO_DEV" -q "$WORKDIR/tts.wav" >/dev/null 2>&1
  echo
done
