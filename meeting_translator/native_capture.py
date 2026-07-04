from __future__ import annotations

import os
import shutil
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

import numpy as np


NATIVE_HELPER_NAME = "MeetingAudioCapture"


def find_native_helper() -> Optional[str]:
    project_root = Path(__file__).resolve().parent.parent
    candidate = project_root / "native" / "MeetingAudioCapture" / ".build" / "debug" / NATIVE_HELPER_NAME
    if candidate.exists() and os.access(candidate, os.X_OK):
        return str(candidate)
    found = shutil.which(NATIVE_HELPER_NAME)
    if found:
        return found
    return None


def list_capturable_apps(helper_path: str | None = None) -> list[dict]:
    helper_path = helper_path or find_native_helper()
    if not helper_path:
        return []
    result = subprocess.run(
        [helper_path, "list"],
        capture_output=True,
        text=True,
        timeout=15,
    )
    apps = []
    for line in result.stdout.splitlines():
        line = line.strip()
        if not line or line.startswith("Capturable"):
            continue
        parts = line.split("\t", 1)
        if len(parts) == 2:
            apps.append({"bundle_id": parts[0].strip(), "name": parts[1].strip()})
        elif len(parts) == 1 and parts[0].strip():
            apps.append({"bundle_id": parts[0].strip(), "name": parts[0].strip()})
    return apps


@dataclass
class NativeCaptureConfig:
    bundle_id: str
    include_mic: bool = False
    duration: float = 0.0


class NativeAudioStream:
    def __init__(self, config: NativeCaptureConfig, helper_path: str | None = None):
        self.config = config
        self.helper_path = helper_path or find_native_helper()
        if not self.helper_path:
            raise RuntimeError("MeetingAudioCapture helper not found. Build it first: cd native/MeetingAudioCapture && swift build")
        self.process: Optional[subprocess.Popen] = None
        self._started = False

    def __enter__(self) -> "NativeAudioStream":
        self.start()
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.close()

    def start(self) -> None:
        if self._started:
            return
        cmd = [self.helper_path, "capture", "--app", self.config.bundle_id]
        if self.config.include_mic:
            cmd.append("--mic")
        if self.config.duration > 0:
            cmd.extend(["--duration", str(self.config.duration)])
        self.process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self._started = True

    def read_window(self, seconds: float, sample_rate: int = 16000):
        if not self._started:
            self.start()
        assert self.process is not None and self.process.stdout is not None
        from meeting_translator.audio import AudioChunk

        target_bytes = int(seconds * sample_rate) * 2
        collected = bytearray()
        while len(collected) < target_bytes:
            remaining = target_bytes - len(collected)
            chunk = self.process.stdout.read(remaining)
            if not chunk:
                break
            collected.extend(chunk)
        if not collected:
            samples = np.zeros((int(seconds * sample_rate), 1), dtype=np.float32)
        else:
            raw = np.frombuffer(bytes(collected[:target_bytes]), dtype=np.int16)
            samples = (raw.astype(np.float32) / 32768.0).reshape(-1, 1)
        return AudioChunk(name="native", sample_rate=sample_rate, samples=samples)

    def close(self) -> None:
        if self.process is not None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
            self.process = None
        self._started = False