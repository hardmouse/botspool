#!/usr/bin/env bash
set -euo pipefail

# =========================
#  voice_to_json.sh (clean)
#  Mic -> SoX gain -> Whisper -> Ollama(JSON) -> sanitize -> validate -> (TTS ack) -> MQTT publish
#
# Usage:
#   ./voice_to_json.sh [seconds] [workdir]
# Example:
#   ./voice_to_json.sh 5 /home/futung/test
# =========================

# === Config ===
MQTT_HOST="localhost"
MQTT_TOPIC="bots/worker/command"

MIC_DEV="plughw:0,0"               # safer than hw:0,0
RATE="16000"
DUR="${1:-5}"                      # seconds (default 5)
WORKDIR="${2:-/home/futung/test}"

WHISPER_DIR="$HOME/whisper.cpp"
WHISPER_BIN="$WHISPER_DIR/build/bin/whisper-cli"
WHISPER_MODEL="$WHISPER_DIR/models/ggml-base.bin"

RAW="$WORKDIR/raw.wav"
CLEAN="$WORKDIR/clean.wav"
TEXTFILE="$WORKDIR/text.txt"

# Ollama (jetson-containers, reachable from host via host networking)
OLLAMA_BASE="http://127.0.0.1:11434"
OLLAMA_TAGS="$OLLAMA_BASE/api/tags"
OLLAMA_URL="$OLLAMA_BASE/api/generate"
MODEL="gemma3:latest"

# Set DEBUG=1 when running to print more info
DEBUG="${DEBUG:-0}"

PROMPT_PREFIX='You convert user text into ONE JSON object only.
Output MUST be raw JSON only: no markdown, no code fences, no backticks, no explanations.
Output must start with { and end with }.

JSON schema:
{"intent":"command|clarify|status","target":"worker|worker1|worker2|all|mother","action":"power_on|power_off|move|stop|say|ping","args":{},"confirm":false}

Rules:
- Use only the allowed enum values exactly.
- target must not contain spaces.
- If the user did not specify which worker, use intent="clarify", action="say", target="mother", confirm=true, and ask a short question in args.question.
- confirm=true ONLY when intent="clarify". Otherwise confirm MUST be false.
- For power_on/power_off, args must be {}.

User text: """'

PROMPT_SUFFIX='"""'

# === Helpers ===
die() { echo "ERROR: $*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

# === Preflight ===
need_cmd arecord
need_cmd sox
need_cmd jq
need_cmd curl
need_cmd mosquitto_pub
need_cmd python3
need_cmd aplay

[[ -x "$WHISPER_BIN" ]]   || die "Whisper binary not found: $WHISPER_BIN"
[[ -f "$WHISPER_MODEL" ]] || die "Whisper model not found: $WHISPER_MODEL"

mkdir -p "$WORKDIR"

# Speak (TTS)
TTS_VOICE="${TTS_VOICE:-/home/futung/piper/voices/en_US-amy-medium.onnx}"  # change if yours differs
PIPER_BIN="${PIPER_BIN:-piper}"                                       # or /usr/local/bin/piper
AUDIO_DEV="${AUDIO_DEV:-default}" 

speak() {
  local msg="$1"
  [[ -z "${msg// }" ]] && return 0

  [[ -f "$TTS_VOICE" ]] || die "TTS model not found: $TTS_VOICE"
  command -v "$PIPER_BIN" >/dev/null 2>&1 || die "piper not found. Install piper or set PIPER_BIN to full path."

  local outwav="$WORKDIR/tts.wav"

  # Generate wav with Piper
  printf "%s" "$msg" | "$PIPER_BIN" --model "$TTS_VOICE" --output_file "$outwav" \
    >/dev/null 2>&1 || die "piper failed to generate audio"

  # Play wav
  aplay -D "$AUDIO_DEV" -q "$outwav" >/dev/null 2>&1 || die "aplay failed (check AUDIO_DEV=$AUDIO_DEV)"
}

# Turn command JSON into a natural spoken reply
say_from_json() {
  local json="$1"

  local intent target action
  intent="$(jq -r '.intent // ""' <<<"$json")"
  target="$(jq -r '.target // ""' <<<"$json")"
  action="$(jq -r '.action // ""' <<<"$json")"

  # If model needs clarification, speak the question
  if [[ "$intent" == "clarify" ]]; then
    local q
    q="$(jq -r '.args.question // "Which worker bot? worker1 or worker2?"' <<<"$json")"
    speak "$q"
    return 0
  fi

  # If the command is for mother saying something
  if [[ "$target" == "mother" && "$action" == "say" ]]; then
    local msg
    msg="$(jq -r '.args.message // .args.text // .args.question // ""' <<<"$json")"
    [[ -n "${msg// }" ]] && speak "$msg"
    return 0
  fi

  # If the command targets worker bot(s), speak an acknowledgement
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

  # Default: say something light
  speak "Okay."
}

# Ensure Ollama is reachable
curl -s --max-time 2 "$OLLAMA_TAGS" >/dev/null 2>&1 || die \
"Ollama not reachable at $OLLAMA_BASE.
Start it in another terminal:
  jetson-containers run --name ollama \$(autotag ollama)
Then warm the model once:
  ollama run gemma3"

# === Record ===
echo "[1/3] Recording ${DUR}s from $MIC_DEV -> $RAW"
arecord -D "$MIC_DEV" -f S16_LE -r "$RATE" -c 1 -d "$DUR" "$RAW" >/dev/null 2>&1 \
  || die "arecord failed (check MIC_DEV=$MIC_DEV)"

# === Clean/Boost ===
echo "[2/3] Boosting -> $CLEAN"
sox "$RAW" "$CLEAN" gain 12 || die "sox failed"

# === STT ===
echo "[3/3] Whisper transcribe..."
cd "$WHISPER_DIR"
"$WHISPER_BIN" -m "$WHISPER_MODEL" -f "$CLEAN" -nt 2>/dev/null > "$TEXTFILE" \
  || die "whisper-cli failed"

TEXT="$(tr -d '\r' < "$TEXTFILE" | sed 's/^[ \t]*//;s/[ \t]*$//')"
TEXT="$(echo "$TEXT" | sed 's/\bWalker\b/worker/Ig; s/[.。!?！？]$//')"

if [[ -z "${TEXT// }" ]]; then
  die "Heard nothing (empty transcript). Try again or increase gain."
fi

echo "Heard: $TEXT"

# === LLM to JSON ===
echo "Calling Ollama..."
PROMPT="${PROMPT_PREFIX}${TEXT}${PROMPT_SUFFIX}"

RESP=""
HTTP_CODE=""

for i in 1 2; do
  RESP="$(curl -sS --max-time 30 --connect-timeout 2 \
    -w "\nHTTP_CODE:%{http_code}\n" \
    "$OLLAMA_URL" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg model "$MODEL" --arg prompt "$PROMPT" \
     '{model:$model, prompt:$prompt, stream:false, format:"json"}')"
  )" || true

  HTTP_CODE="$(echo "$RESP" | awk -F: '/HTTP_CODE:/ {print $2}' | tail -n 1 | tr -d '\r')"
  RESP_BODY="$(echo "$RESP" | sed '/HTTP_CODE:/d')"

  if [[ "$DEBUG" == "1" ]]; then
    echo "DEBUG: HTTP_CODE=$HTTP_CODE"
    echo "DEBUG: raw Ollama body (first 1200 chars):"
    echo "$RESP_BODY" | head -c 1200
    echo
  fi

  if [[ "$HTTP_CODE" == "200" ]] && echo "$RESP_BODY" | jq -e '.response? and (.response|length>0)' >/dev/null 2>&1; then
    RESP="$RESP_BODY"
    break
  fi

  sleep 1
done

if ! echo "$RESP" | jq -e '.response? and (.response|length>0)' >/dev/null 2>&1; then
  echo "Ollama call failed."
  echo "HTTP_CODE=${HTTP_CODE:-unknown}"
  echo "Raw response body:"
  echo "${RESP:-<empty>}" | head -c 2000
  echo
  die "No usable .response from Ollama"
fi

JSON_RAW="$(echo "$RESP" | jq -r '.response')"
JSON="$(printf '%s' "$JSON_RAW" | jq -c .)"

# Validate JSON returned by the model
echo "$JSON" | jq -e . >/dev/null 2>&1 || {
  echo "Model output is not valid JSON:"
  echo "$JSON" | head -c 2000
  echo
  die "Invalid JSON from model"
}

# Normalize accidental nested args like {"args":{"args":{}}} -> {"args":{}}
JSON="$(echo "$JSON" | jq -c 'if (.args|type)=="object" and (.args.args? != null) then .args = .args.args else . end')"

# Enforce confirm rule deterministically
JSON="$(echo "$JSON" | jq -c 'if .intent=="clarify" then .confirm=true else .confirm=false end')"

# Refuse to publish empty
[[ -n "${JSON// }" ]] || die "Refusing to publish empty JSON"

echo "JSON: $JSON"

# === Mother base speaks naturally (and decides whether to publish) ===
INTENT="$(jq -r '.intent // ""' <<<"$JSON")"
TARGET="$(jq -r '.target // ""' <<<"$JSON")"
ACTION="$(jq -r '.action // ""' <<<"$JSON")"

# Always speak something appropriate
say_from_json "$JSON"

# If we are clarifying, don't publish to worker bots
if [[ "$INTENT" == "clarify" ]]; then
  echo "Not publishing (clarify intent)."
  exit 0
fi

# If command is purely for mother to speak, don't publish
if [[ "$TARGET" == "mother" && "$ACTION" == "say" ]]; then
  echo "Not publishing (mother say)."
  exit 0
fi

# === Publish to MQTT ===
echo "Publishing to MQTT: $MQTT_TOPIC"
mosquitto_pub -h "$MQTT_HOST" -t "$MQTT_TOPIC" -m "$JSON"
