# Mother Base Bot – Voice → JSON → MQTT (Jetson)

This document captures the **end‑to‑end build**, commands, configs, and real issues encountered while building a **voice‑only mother base bot** on NVIDIA Jetson.

The goal is to preserve *what worked*, *what broke*, and *why certain decisions were made*, so future‑you (or another engineer) can resume instantly.

---

## 0. System Overview

**Platform**
- NVIDIA Jetson (Orin Nano)
- Ubuntu (JetPack 6.x)

**Architecture**

```
Microphone
  ↓
Whisper.cpp (STT, local)
  ↓
Ollama (Gemma3, local GPU)
  ↓
Strict JSON command
  ↓
MQTT publish (Mosquitto)
  ↓
Worker bots (ESP32 / Pi / Jetson)
```

**Design constraints**
- Voice‑only (no screen)
- Fully local (no cloud)
- Deterministic JSON output
- One clean step at a time

---

## 1. Task #1 – Audio Input & STT (Whisper)

### 1.1 Hardware
- **Microphone**: EMEET SmartCam C960 (USB webcam mic)
- No USB speakers required for STT testing

### 1.2 Mic detection
```bash
lsusb
arecord -l
```
Expected:
```
card 0: C960 [EMEET SmartCam C960], device 0: USB Audio
```

### 1.3 Recording test
```bash
arecord -D hw:0,0 -f S16_LE -r 16000 -c 1 -d 5 raw.wav
```

### 1.4 Low mic volume (important issue)
**Problem**
- Webcam mic volume extremely low
- ALSA mixer shows *no capture gain controls*

**Resolution**
- Use **software gain** with SoX

```bash
sox raw.wav clean.wav gain 12
# sometimes gain 18 worked, but 12 is safer
```

---

## 1.5 Whisper.cpp Installation

```bash
sudo apt update
sudo apt install -y git build-essential cmake ffmpeg

git clone https://github.com/ggerganov/whisper.cpp.git
cd whisper.cpp
cmake -B build
cmake --build build -j
```

### Models
```bash
bash models/download-ggml-model.sh base
```

Model used:
```
models/ggml-base.bin
```

### STT Command
```bash
./build/bin/whisper-cli \
  -m models/ggml-base.bin \
  -f clean.wav \
  -nt
```

### Language notes
- Mixed EN / ZH / JP is unreliable in one clip
- Forcing language works:
  - `-l en`
  - `-l zh`
  - `-l ja`
- For robot commands, **auto language** or **single language** is recommended

---

## 2. Task #2 – LLM Reasoning (Ollama + Gemma3)

### 2.1 Why Ollama in container
- Jetson‑containers provides CUDA‑enabled builds
- Ollama runs **inside container**, accessed via host network

### 2.2 Start Ollama server

```bash
jetson-containers run \
  --name ollama \
  $(autotag ollama) \
  ollama serve
```

⚠️ Leave this terminal running

### 2.3 Verify Ollama from host

```bash
curl http://localhost:11434/api/tags
```

Expected:
```json
{"models":[{"name":"gemma3:latest"}]}
```

### 2.4 First text → JSON test

```bash
curl http://localhost:11434/api/generate \
  -H "Content-Type: application/json" \
  -d '{
    "model":"gemma3",
    "prompt":"turn on worker one",
    "stream":false
  }'
```

---

## 2.5 Major LLM Problems Encountered

### ❌ Markdown output
- Model often returned:
```
```json
{ ... }
```
```

**Fix**: strip markdown fences before publishing

### ❌ confirm randomly true
- Even clear commands returned `"confirm": true`

**Fix**: enforce confirm logic using `jq`

```bash
jq 'if .intent=="clarify" then .confirm=true else .confirm=false end'
```

### ❌ Occasional HTTP 500
- Ollama returns 500 while model is loading

**Fix**: retry once in script

---

## 3. Task #3 – MQTT Publish (Mosquitto)

### 3.1 Broker
- Mosquitto running locally on Jetson

### 3.2 Topic
```
bots/worker/command
```

### 3.3 Subscribe (debug)

```bash
mosquitto_sub -h localhost -t 'bots/worker/command' -v
```

### 3.4 Publish (manual test)

```bash
mosquitto_pub -h localhost -t 'bots/worker/command' -m \
'{"intent":"command","target":"worker1","action":"power_on","args":{},"confirm":false}'
```

---

## 4. Final Integrated Script

Location:
```
~/voicebot/voice_to_json.sh
```

Responsibilities:
1. Record mic audio
2. Boost volume (SoX)
3. Whisper STT
4. Normalize text (Walker → worker)
5. Send to Ollama
6. Sanitize JSON
7. Enforce confirm logic
8. Publish to MQTT

This script represents the **final stable interface** of the mother base bot.

---

## 5. Known Non‑Issues (Expected Behavior)

- Worker not reacting → worker subscriber not running
- `(null)` MQTT messages → retained or reconnect artifacts
- Ollama WARN logs → normal ggml metadata warnings
- Whisper timing logs → suppressed in final script

---

## 6. Next Steps (Not Implemented Yet)

- Worker‑side MQTT subscriber (ESP32 / Pi / Jetson)
- TTS voice feedback (Piper)
- Wake‑word detection
- Confirmation dialog loop

---

## 7. Key Lessons Learned

- Webcam mics require software gain
- LLM output must be **sanitized** before automation
- Containers + host networking need mental separation
- One‑directional pipelines reduce debugging pain

---

## 8. Status

✅ Voice → JSON → MQTT pipeline complete

🚧 Worker execution pending

🛌 Calling it a day — system is in a good state

