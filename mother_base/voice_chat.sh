#!/usr/bin/env bash
set -euo pipefail

# =========================
# voice_chat.sh (memory + clear w/ confirmation + auto-summary)
# Mic -> Whisper -> Ollama Chat (history+summary) -> Piper TTS
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

# Ollama (chat endpoint)
OLLAMA_CHAT_URL="http://127.0.0.1:11434/api/chat"
MODEL="gemma3:latest"

# Piper
PIPER_BIN="/usr/local/bin/piper"
TTS_VOICE="/home/futung/piper/voices/en_US-amy-medium.onnx"
AUDIO_DEV="default"

# Memory files
HIST="$WORKDIR/history.jsonl"        # recent messages (json lines)
SUMMARY="$WORKDIR/summary.txt"       # running summary text
CONFIRM_CLEAR="$WORKDIR/confirm_clear.flag"  # confirmation state for memory wipe

# ---- Memory knobs ----
MAX_TURNS="${MAX_TURNS:-12}"                 # keep last 12 user+assistant turns (24 messages)
SUMMARIZE_AFTER_TURNS="${SUMMARIZE_AFTER_TURNS:-18}"  # when turns exceed this, summarize older ones
CONFIRM_TIMEOUT_SEC="${CONFIRM_TIMEOUT_SEC:-12}"      # seconds to accept "yes/no" after asking
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
touch "$SUMMARY"

# ---- Helpers ----
append_msg() {
  local role="$1"
  local content="$2"
  jq -c -n --arg role "$role" --arg content "$content" '{role:$role, content:$content}' >> "$HIST"
}

count_turns() {
  grep -c '"role":"user"' "$HIST" 2>/dev/null || echo 0
}

trim_history_to_last_turns() {
  local max_lines=$((MAX_TURNS * 2))
  local tmp="$WORKDIR/history.tmp"
  tail -n "$max_lines" "$HIST" > "$tmp" 2>/dev/null || true
  mv "$tmp" "$HIST"
}

clear_memory() {
  : > "$HIST"
  : > "$SUMMARY"
  rm -f "$CONFIRM_CLEAR" 2>/dev/null || true
}

speak() {
  local text="$1"
  printf "%s" "$text" | "$PIPER_BIN" --model "$TTS_VOICE" --output_file "$WORKDIR/tts.wav" >/dev/null 2>&1
  aplay -D "$AUDIO_DEV" -q "$WORKDIR/tts.wav" >/dev/null 2>&1
}

build_messages_json() {
  local summary_text
  summary_text="$(cat "$SUMMARY" 2>/dev/null || true)"

  if [[ -n "${summary_text// }" ]]; then
    jq -cs --arg sys "$SYSTEM_PROMPT" --arg sum "$summary_text" \
      '([{role:"system", content:$sys},
         {role:"system", content:("Conversation memory (summary): " + $sum)}] + .)' \
      "$HIST"
  else
    jq -cs --arg sys "$SYSTEM_PROMPT" \
      '([{role:"system", content:$sys}] + .)' \
      "$HIST"
  fi
}

ollama_chat() {
  local messages_json="$1"
  curl -s "$OLLAMA_CHAT_URL" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
      --arg model "$MODEL" \
      --argjson messages "$messages_json" \
      '{model:$model, messages:$messages, stream:false}')"
}

summarize_if_needed() {
  local turns
  turns="$(count_turns)"

  if (( turns <= SUMMARIZE_AFTER_TURNS )); then
    return 0
  fi

  local keep_lines=$((MAX_TURNS * 2))
  local total_lines old_lines
  total_lines=$(wc -l < "$HIST" 2>/dev/null || echo 0)
  old_lines=$(( total_lines - keep_lines ))
  (( old_lines <= 0 )) && return 0

  local oldfile="$WORKDIR/old.jsonl"
  local recentfile="$WORKDIR/recent.jsonl"
  head -n "$old_lines" "$HIST" > "$oldfile" 2>/dev/null || true
  tail -n "$keep_lines" "$HIST" > "$recentfile" 2>/dev/null || true

  local oldtext
  oldtext="$(jq -r '("\(.role): " + .content)' "$oldfile" 2>/dev/null | sed '/^$/d' || true)"
  [[ -z "${oldtext// }" ]] && { mv "$recentfile" "$HIST"; return 0; }

  local prior_sum
  prior_sum="$(cat "$SUMMARY" 2>/dev/null || true)"

  local sum_messages
  sum_messages="$(jq -n --arg ps "$prior_sum" --arg ot "$oldtext" '
    [
      {role:"system", content:"You compress conversation into a short memory summary. Keep names, preferences, goals, decisions, and open tasks. Max 8 bullet points. No filler."},
      {role:"user", content:("Prior summary (may be empty):\n" + $ps + "\n\nNew dialog to fold in:\n" + $ot)}
    ]')"

  local resp answer
  resp="$(ollama_chat "$sum_messages")"
  answer="$(echo "$resp" | jq -r '.message.content // empty')"

  if [[ -n "${answer// }" ]]; then
    printf "%s\n" "$answer" > "$SUMMARY"
  fi

  mv "$recentfile" "$HIST"
}

# Confirmation timeout cleanup (so it won't stay "armed" forever)
clear_confirm_if_expired() {
  [[ -f "$CONFIRM_CLEAR" ]] || return 0
  local ts now
  ts="$(cat "$CONFIRM_CLEAR" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  if (( now - ts > CONFIRM_TIMEOUT_SEC )); then
    rm -f "$CONFIRM_CLEAR" 2>/dev/null || true
  fi
}

has_phrase() {
  # Usage: has_phrase "$text" "yes|yeah|yep"
  # Matches tokens separated by non-alnum characters (spaces, punctuation, etc.)
  local text="$1"
  local alts="$2"
  [[ "$text" =~ (^|[^[:alnum:]])($alts)($|[^[:alnum:]]) ]]
}

# ---- Start ----
echo "🎙 Voice chat started (memory + clear-confirm + auto-summary)"
echo "Say: 'clear memory' to reset (requires yes/no). Ctrl+C to exit."
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
  LOWER="$(echo "$TEXT" | tr '[:upper:]' '[:lower:]')"

  # expire confirmation state if too old
  clear_confirm_if_expired

  # Exit commands
  if echo "$LOWER" | grep -Eq '\b(exit|quit|stop talking|goodbye|bye)\b'; then
    echo "Exiting voice chat."
    speak "Goodbye."
    exit 0
  fi

  # ---- Clear memory (with confirmation) ----

  # Step 1: request confirmation (intentionally ONLY these phrases)
  if echo "$LOWER" | grep -Eq '\b(clear memory|reset memory|wipe memory|forget everything)\b'; then
    echo "Confirm memory reset? (yes/no)"
    date +%s > "$CONFIRM_CLEAR"
    speak "Do you want me to clear our conversation memory? Please say yes or no."
    echo
    continue
  fi
  
  # Step 2: if we're waiting for yes/no, handle it first
  if [[ -f "$CONFIRM_CLEAR" ]]; then
    if has_phrase "$LOWER" "yes|yes!|yes.|yeah|yep|yup|sure|ok|okay|confirm|do it|go ahead"; then
      rm -f "$CONFIRM_CLEAR" 2>/dev/null || true
      clear_memory
      echo "Memory cleared."
      speak "Okay. I have cleared our conversation memory."
      echo
      continue
    fi

    if has_phrase "$LOWER" "no|nah|nope|cancel|never mind|stop"; then
      rm -f "$CONFIRM_CLEAR" 2>/dev/null || true
      speak "Okay. I will keep our conversation memory."
      echo
      continue
    fi
  fi

  # Add user message, then maybe summarize older stuff
  append_msg "user" "$TEXT"
  summarize_if_needed
  trim_history_to_last_turns

  echo "Thinking..."
  MESSAGES_JSON="$(build_messages_json)"
  RESP="$(ollama_chat "$MESSAGES_JSON")"

  ANSWER="$(echo "$RESP" | jq -r '.message.content // empty')"
  [[ -z "$ANSWER" ]] && continue

  echo "Bot: $ANSWER"

  # Add assistant message, summarize/trim again
  append_msg "assistant" "$ANSWER"
  summarize_if_needed
  trim_history_to_last_turns

  echo "Speaking..."
  speak "$ANSWER"
  echo
done
