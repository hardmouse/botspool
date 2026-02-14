#!/usr/bin/env bash
set -euo pipefail

# =========================
# base_bot_wake.sh
# Always listening for wake phrase, then records a command and runs:
# Mic -> SoX -> Whisper -> Ollama(JSON) -> validate -> Piper TTS -> MQTT publish
#
# Wake phrase: "base bot" (configurable)
# Flow:
#   - loop recording short chunks
#   - if wake phrase detected -> speak "Yes?" -> record up to 10s command (trim silence)
#   - run the same JSON/MQTT pipeline
# =========================

# ===== Config =====
MQTT_HOST="${MQTT_HOST:-localhost}"
MQTT_TOPIC="${MQTT_TOPIC:-bots/worker/command}"

MIC_DEV="${MIC_DEV:-plughw:0,0}"
RATE="${RATE:-16000}"

WORKDIR="${WORKDIR:-/home/futung/test}"

# Wake word settings
WAKE_PHRASE="${WAKE_PHRASE:-hey base}"     # what you say
WAKE_CHUNK_SEC="${WAKE_CHUNK_SEC:-3.0}"    # record chunk size while waiting
WAKE_GAIN_DB="${WAKE_GAIN_DB:-18}"         # boost wake chunks
WAKE_COOLDOWN_SEC="${WAKE_COOLDOWN_SEC:-1}" # prevent double-trigger

# Command capture settings
CMD_MAX_SEC="${CMD_MAX_SEC:-10}"           # record up to 10 seconds after wake
CMD_GAIN_DB="${CMD_GAIN_DB:-18}"           # boost command audio
# Silence trim: stop after ~0.7s of silence at end, remove leading silence too
SILENCE_STOP_SEC="${SILENCE_STOP_SEC:-0.7}"
SILENCE_THRESH="${SILENCE_THRESH:-1%}"

WHISPER_DIR="${WHISPER_DIR:-$HOME/whisper.cpp}"
WHISPER_BIN="${WHISPER_BIN:-$WHISPER_DIR/build/bin/whisper-cli}"
WHISPER_MODEL="${WHISPER_MODEL:-$WHISPER_DIR/models/ggml-base.bin}"

# Ollama
OLLAMA_BASE="${OLLAMA_BASE:-http://127.0.0.1:11434}"
OLLAMA_TAGS="$OLLAMA_BASE/api/tags"
OLLAMA_URL="$OLLAMA_BASE/api/generate"
MODEL="${MODEL:-gemma3:latest}"

# Piper (human voice)
PIPER_BIN="${PIPER_BIN:-/usr/local/bin/piper}"
TTS_VOICE="${TTS_VOICE:-/home/futung/piper/voices/en_US-amy-medium.onnx}"
AUDIO_DEV="${AUDIO_DEV:-default}"

# DEBUG=1 to show more logs
DEBUG="${DEBUG:-0}"

# Prompt for Ollama JSON
PROMPT_PREFIX='You convert user text into ONE JSON object only.
Output MUST be raw JSON only: no markdown, no code fences, no backticks, no explanations.
Output must start with { and end with }.

JSON schema:
{"intent":"command|clarify|status","target":"worker1|worker2|all|mother","action":"power_on|power_off|move|stop|say|ping","args":{},"confirm":false}

Rules:
- Use only the allowed enum values exactly.
- target must not contain spaces.
- If the user did not specify which worker, use intent="clarify", action="say", target="mother", confirm=true, and ask a short question in args.question.
- confirm=true ONLY when intent="clarify". Otherwise confirm MUST be false.
- For power_on/power_off, args must be {}.
- If user asks for status/check/test, prefer intent="status" and action="ping".

User text: """'
PROMPT_SUFFIX='"""'

# ===== Helpers =====
die() { echo "ERROR: $*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

normalize_text() {
  # trim, remove trailing punctuation, normalize "Walker"->"worker"
  tr -d '\r' | sed 's/^[ \t]*//;s/[ \t]*$//' | sed 's/\bWalker\b/worker/Ig; s/[.。!?！？]$//'
}

# Force Piper-only TTS (human playback)
speak() {
  local msg="$1"
  [[ -z "${msg// }" ]] && return 0

  [[ -x "$PIPER_BIN" ]] || die "piper not found/executable at: $PIPER_BIN"
  [[ -f "$TTS_VOICE" ]] || die "TTS model not found: $TTS_VOICE"

  local outwav="$WORKDIR/tts.wav"
  printf "%s" "$msg" | "$PIPER_BIN" --model "$TTS_VOICE" --output_file "$outwav" >/dev/null 2>&1 \
    || die "piper failed to generate audio"

  aplay -D "$AUDIO_DEV" -q "$outwav" >/dev/null 2>&1 || die "aplay failed (check AUDIO_DEV=$AUDIO_DEV)"
}

say_from_json() {
  local json="$1"
  local intent target action
  intent="$(jq -r '.intent // ""' <<<"$json")"
  target="$(jq -r '.target // ""' <<<"$json")"
  action="$(jq -r '.action // ""' <<<"$json")"

  if [[ "$intent" == "clarify" ]]; then
    local q
    q="$(jq -r '.args.question // "Which worker bot? worker1 or worker2?"' <<<"$json")"
    speak "$q"
    return 0
  fi

  if [[ "$target" == "mother" && "$action" == "say" ]]; then
    local msg
    msg="$(jq -r '.args.message // .args.text // .args.question // ""' <<<"$json")"
    [[ -n "${msg// }" ]] && speak "$msg"
    return 0
  fi

  if [[ "$target" == worker* || "$target" == "all" ]]; then
    local spoken=""
    case "$action" in
      power_on)  spoken="Okay. Powering on ${target}." ;;
      power_off) spoken="Okay. Powering off ${target}." ;;
      move)
        local dir spd
        dir="$(jq -r '.args.dir // .args.direction // ""' <<<"$json")"
        spd="$(jq -r '.args.speed // ""' <<<"$json")"
        if [[ -n "${dir// }" && -n "${spd// }" ]]; then
          spoken="Okay. Sending ${target} to move ${dir} at speed ${spd}."
        elif [[ -n "${dir// }" ]]; then
          spoken="Okay. Sending ${target} to move ${dir}."
        else
          spoken="Okay. Sending move command to ${target}."
        fi
        ;;
      stop) spoken="Okay. Stopping ${target}." ;;
      ping) spoken="Okay. Checking status of ${target}." ;;
      say)
        local msg
        msg="$(jq -r '.args.message // .args.text // ""' <<<"$json")"
        if [[ -n "${msg// }" ]]; then
          spoken="Okay. I will tell ${target}: ${msg}"
        else
          spoken="Okay. Sending message to ${target}."
        fi
        ;;
      *) spoken="Okay. Sending command to ${target}." ;;
    esac
    speak "$spoken"
    return 0
  fi

  speak "Okay."
}

whisper_transcribe_file() {
  local wav="$1"
  local outtxt="$2"

  ( cd "$WHISPER_DIR" && "$WHISPER_BIN" -m "$WHISPER_MODEL" -f "$wav" -nt 2>/dev/null > "$outtxt" ) \
    || return 1
  return 0
}

ollama_to_json() {
  local text="$1"

  local prompt="${PROMPT_PREFIX}${text}${PROMPT_SUFFIX}"
  local resp http_code resp_body

  resp="$(curl -sS --max-time 30 --connect-timeout 2 \
    -w "\nHTTP_CODE:%{http_code}\n" \
    "$OLLAMA_URL" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg model "$MODEL" --arg prompt "$prompt" \
      '{model:$model, prompt:$prompt, stream:false, format:"json"}')"
  )" || return 1

  http_code="$(echo "$resp" | awk -F: '/HTTP_CODE:/ {print $2}' | tail -n 1 | tr -d '\r')"
  resp_body="$(echo "$resp" | sed '/HTTP_CODE:/d')"

  if [[ "$DEBUG" == "1" ]]; then
    echo "DEBUG: Ollama HTTP_CODE=$http_code"
    echo "DEBUG: Ollama body (first 800 chars):"
    echo "$resp_body" | head -c 800
    echo
  fi

  [[ "$http_code" == "200" ]] || return 1
  echo "$resp_body" | jq -e '.response? and (.response|length>0)' >/dev/null 2>&1 || return 1

  local json_raw json
  json_raw="$(echo "$resp_body" | jq -r '.response')" || return 1
  json="$(printf '%s' "$json_raw" | jq -c .)" || return 1

  # Normalize nested args
  json="$(echo "$json" | jq -c 'if (.args|type)=="object" and (.args.args? != null) then .args = .args.args else . end')"
  # Enforce confirm rule
  json="$(echo "$json" | jq -c 'if .intent=="clarify" then .confirm=true else .confirm=false end')"

  echo "$json"
}

# ===== Preflight =====
need_cmd arecord
need_cmd sox
need_cmd jq
need_cmd curl
need_cmd mosquitto_pub
need_cmd aplay
need_cmd grep

[[ -d "$WHISPER_DIR" ]] || die "WHISPER_DIR not found: $WHISPER_DIR"
[[ -x "$WHISPER_BIN" ]] || die "Whisper binary not found: $WHISPER_BIN"
[[ -f "$WHISPER_MODEL" ]] || die "Whisper model not found: $WHISPER_MODEL"

[[ -x "$PIPER_BIN" ]] || die "piper not found/executable at: $PIPER_BIN"
[[ -f "$TTS_VOICE" ]] || die "TTS model not found: $TTS_VOICE"

mkdir -p "$WORKDIR"

curl -s --max-time 2 "$OLLAMA_TAGS" >/dev/null 2>&1 || die \
"Ollama not reachable at $OLLAMA_BASE. Start it and warm model."

# ===== Files =====
WAKE_RAW="$WORKDIR/wake_raw.wav"
WAKE_CLEAN="$WORKDIR/wake_clean.wav"
WAKE_TXT="$WORKDIR/wake_text.txt"

CMD_RAW="$WORKDIR/cmd_raw.wav"
CMD_CLEAN="$WORKDIR/cmd_clean.wav"
CMD_TRIM="$WORKDIR/cmd_trim.wav"
CMD_TXT="$WORKDIR/cmd_text.txt"

echo "Base bot wake loop started."
echo "Say: \"$WAKE_PHRASE\""
echo "Press Ctrl+C to stop."

while true; do
  # Show the loop is alive (only when DEBUG=1 to avoid spam)
  [[ "$DEBUG" == "1" ]] && echo "…listening for wake word (chunk ${WAKE_CHUNK_SEC}s)"

  # --- Wake listen chunk ---
  arecord -D "$MIC_DEV" -f S16_LE -r "$RATE" -c 1 -d "$WAKE_CHUNK_SEC" "$WAKE_RAW" >/dev/null 2>&1 || true
  sox "$WAKE_RAW" "$WAKE_CLEAN" gain "$WAKE_GAIN_DB" >/dev/null 2>&1 || true

  if ! whisper_transcribe_file "$WAKE_CLEAN" "$WAKE_TXT"; then
    continue
  fi

  WAKE_TEXT="$(cat "$WAKE_TXT" | normalize_text)"
  [[ "$DEBUG" == "1" ]] && echo "DEBUG: wake heard: $WAKE_TEXT"

  # --- Fuzzy wake match ---
  wake_hit=0
  w="$(echo "$WAKE_TEXT" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9 \n\t')"

  # Accept variations
  if echo "$w" | grep -Eq '\bbase\b.*\bbot\b'; then wake_hit=1; fi
  if echo "$w" | grep -Eq '\bbasebot\b'; then wake_hit=1; fi
  if echo "$w" | grep -Eq '\bhey\b.*\bbase\b'; then wake_hit=1; fi
  if echo "$w" | grep -Eq '\bokay\b.*\bbase\b|\bok\b.*\bbase\b'; then wake_hit=1; fi

  if echo "$w" | grep -Eq '\bbass\b.*\bbot\b'; then wake_hit=1; fi
  if echo "$w" | grep -Eq '\bbase\b.*\bbut\b'; then wake_hit=1; fi
  if echo "$w" | grep -Eq '\bbaseball\b'; then wake_hit=1; fi

  if echo "$w" | grep -Eq '\bhey\b.*\bbass\b'; then wake_hit=1; fi

  [[ "$DEBUG" == "1" ]] && echo "DEBUG: normalized wake text: $w (wake_hit=$wake_hit)"

  # Only print wake detected when it's TRUE
  if [[ "$wake_hit" == "1" ]]; then
    echo "🔔 Wake phrase detected: \"$WAKE_TEXT\""
    speak "Yes?"
    sleep "$WAKE_COOLDOWN_SEC"

    # --- Record command up to CMD_MAX_SEC ---
    echo "Listening for command..."
    arecord -D "$MIC_DEV" -f S16_LE -r "$RATE" -c 1 -d "$CMD_MAX_SEC" "$CMD_RAW" >/dev/null 2>&1 || true
    sox "$CMD_RAW" "$CMD_CLEAN" gain "$CMD_GAIN_DB" >/dev/null 2>&1 || true

    # Trim silence (leading + trailing). If trimming fails, fall back to clean.
    if sox "$CMD_CLEAN" "$CMD_TRIM" silence 1 0.1 "$SILENCE_THRESH" 1 "$SILENCE_STOP_SEC" "$SILENCE_THRESH" >/dev/null 2>&1; then
      :
    else
      cp -f "$CMD_CLEAN" "$CMD_TRIM"
    fi

    if ! whisper_transcribe_file "$CMD_TRIM" "$CMD_TXT"; then
      speak "Sorry, I didn't catch that."
      continue
    fi

    CMD_TEXT="$(cat "$CMD_TXT" | normalize_text)"
    CMD_TEXT="$(echo "$CMD_TEXT" | sed 's/\bWalker\b/worker/Ig')"

    if [[ -z "${CMD_TEXT// }" ]]; then
      speak "I didn't hear a command."
      continue
    fi

    echo "Heard command: $CMD_TEXT"

    # --- Ollama -> JSON ---
    JSON="$(ollama_to_json "$CMD_TEXT")" || {
      speak "Sorry. My brain glitched."
      continue
    }

    echo "JSON: $JSON"

    # --- Speak acknowledgement ---
    say_from_json "$JSON"

    INTENT="$(jq -r '.intent // ""' <<<"$JSON")"
    TARGET="$(jq -r '.target // ""' <<<"$JSON")"
    ACTION="$(jq -r '.action // ""' <<<"$JSON")"

    # If clarify or mother-say, do NOT publish
    if [[ "$INTENT" == "clarify" ]]; then
      echo "Not publishing (clarify intent)."
      continue
    fi
    if [[ "$TARGET" == "mother" && "$ACTION" == "say" ]]; then
      echo "Not publishing (mother say)."
      continue
    fi

    # --- Publish ---
    echo "Publishing to MQTT: $MQTT_TOPIC"
    mosquitto_pub -h "$MQTT_HOST" -t "$MQTT_TOPIC" -m "$JSON" || true
  fi
done
