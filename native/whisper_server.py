#!/usr/bin/env python3
"""Real-time Whisper transcription server.

Protocol (line-based JSON over stdin/stdout):
  - Input  (stdin):  {"type":"audio","samples":[...],"sample_rate":48000}
  - Output (stdout): {"type":"ready"}
                      {"type":"final","text":"..."}
  - Input:  {"type":"stop"} → flush and exit
"""

import sys
import json
import time
import threading
import numpy as np
from faster_whisper import WhisperModel

MODEL_SIZE = "tiny"
COMPUTE_TYPE = "int8"
DEVICE = "cpu"
LANGUAGE = None
VAD_THRESHOLD = 0.003
SILENCE_FLUSH_SECONDS = 1.5
MIN_AUDIO_SECONDS = 0.5

def log(msg):
    sys.stderr.write(f"[whisper] {msg}\n")
    sys.stderr.flush()

def send_output(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()

def main():
    log(f"Loading model '{MODEL_SIZE}' ({COMPUTE_TYPE})...")
    model = WhisperModel(MODEL_SIZE, device=DEVICE, compute_type=COMPUTE_TYPE)
    log("Model loaded")

    audio_buffer = []
    buffer_sample_rate = 48000
    silence_start = None

    def transcribe_sync(samples, sample_rate):
        """Transcribe and send result directly."""
        try:
            if len(samples) < int(sample_rate * MIN_AUDIO_SECONDS):
                log(f"Skip short: {len(samples)} samples")
                return
            audio_np = np.array(samples, dtype=np.float32) / 32768.0
            segments, info = model.transcribe(
                audio_np,
                language=LANGUAGE,
                vad_filter=False,
                beam_size=1,
                best_of=1,
                without_timestamps=True,
            )
            text = " ".join(seg.text.strip() for seg in segments).strip()
            log(f"Transcribed: \"{text[:80]}\" (lang={info.language})")
            if text:
                send_output({"type": "final", "text": text})
        except Exception as e:
            log(f"Transcribe error: {e}")
            send_output({"type": "error", "text": str(e)})

    send_output({"type": "ready"})

    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            log("stdin EOF")
            break
        line = line.strip()
        if not line:
            continue

        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            log(f"JSON error: {line[:50]}")
            continue

        if msg.get("type") == "stop":
            if audio_buffer:
                buf = audio_buffer[:]
                audio_buffer = []
                log(f"Stop: transcribing {len(buf)} samples")
                transcribe_sync(buf, buffer_sample_rate)
            break

        if msg.get("type") != "audio":
            continue

        samples = msg.get("samples", [])
        buffer_sample_rate = msg.get("sample_rate", 48000)
        if not samples:
            continue

        # Compute RMS
        arr = np.array(samples, dtype=np.float32) / 32768.0
        rms = float(np.sqrt(np.mean(arr ** 2)))
        now = time.time()

        if rms > VAD_THRESHOLD:
            audio_buffer.extend(samples)
            silence_start = None
        else:
            if audio_buffer:
                if silence_start is None:
                    silence_start = now
                elif now - silence_start > SILENCE_FLUSH_SECONDS:
                    buf = audio_buffer[:]
                    audio_buffer = []
                    silence_start = None
                    log(f"Silence flush: {len(buf)} samples")
                    transcribe_sync(buf, buffer_sample_rate)

    log("Exiting")

if __name__ == "__main__":
    main()