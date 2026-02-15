#!/usr/bin/env bash
set -euo pipefail

# =========================
# voice_chat.sh (with memory)
# Mic -> Whisper -> Ollama Chat (with history) -> Piper TTS
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

# Ollama (chat endpoint)
OLLAMA_CHAT_URL="http://127.0.0.1:11434/api/chat"
MODEL="gemma3:latest"

# Piper
PIPER_BIN="/usr/local/bin/piper"
TTS_VOICE="/home/futung/piper/voices/en_US-amy-medium.onnx"
AUDIO_DEV="default"

# Memory settings
HIST="$WORKDIR/history.jsonl"
MAX_TURNS="${MAX_TURNS:-12}"   # keep last 12 user+assistant turns (24 messages)
SYSTEM_PROMPT="${SYSTEM_PROMPT:-You are a friendly voice assistant. Keep replies short (1 sentence), conversational, and consistent with prior context.}"

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

touch "$HIST"

# ---- Helpers ----
trim_history() {
  # Keep only the last (MAX_TURNS*2) lines (user+assistant pairs).
  # If you also store system messages, they’re re-added separately below.
  local max_lines=$((MAX_TURNS * 2))
  local tmp="$WORKDIR/history.tmp"
  tail -n "$max_lines" "$HIST" > "$tmp" 2>/dev/null || true
  mv "$tmp" "$HIST"
}

append_msg() {
  local role="$1"
  local content="$2"
  jq -c -n --arg role "$role" --arg content "$content" '{role:$role, content:$content}' >> "$HIST"
}

build_messages_json() {
  # Build: [ {system}, ...history... ]
  # history.jsonl is already one JSON object per line.
  jq -cs \
    --arg sys "$SYSTEM_PROMPT" \
    '([{role:"system", content:$sys}] + .)' \
    "$HIST"
}

speak() {
  local text="$1"
  printf "%s" "$text" | "$PIPER_BIN" --model "$TTS_VOICE" --output_file "$WORKDIR/tts.wav" >/dev/null 2>&1
  aplay -D "$AUDIO_DEV" -q "$WORKDIR/tts.wav" >/dev/null 2>&1
}

# ---- Start ----
echo "🎙 Voice chat started (with memory)"
echo "Speak naturally. Ctrl+C to exit."
echo

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

  # Voice exit commands
  if echo "$TEXT" | tr '[:upper:]' '[:lower:]' | grep -Eq '\b(exit|quit|stop talking|goodbye|bye)\b'; then
    echo "Exiting voice chat."
    speak "Goodbye."
    exit 0
  fi

  # Add user message to history
  append_msg "user" "$TEXT"
  trim_history

  echo "Thinking..."
  MESSAGES_JSON="$(build_messages_json)"

  RESP="$(
    curl -s "$OLLAMA_CHAT_URL" \
      -H "Content-Type: application/json" \
      -d "$(jq -n \
        --arg model "$MODEL" \
        --argjson messages "$MESSAGES_JSON" \
        '{model:$model, messages:$messages, stream:false}')"
  )"

  # /api/chat returns message.content
  ANSWER="$(echo "$RESP" | jq -r '.message.content // empty')"
  [[ -z "$ANSWER" ]] && continue

  echo "Bot: $ANSWER"

  # Add assistant message to history
  append_msg "assistant" "$ANSWER"
  trim_history

  echo "Speaking..."
  speak "$ANSWER"
  echo
done
