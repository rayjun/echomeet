from __future__ import annotations

import tempfile
from pathlib import Path

import soundfile as sf

from meeting_translator.audio import AudioChunk


class FasterWhisperTranscriber:
    def __init__(self, model_size: str = "small", language: str | None = None):
        from faster_whisper import WhisperModel

        self.language = language
        self.model = WhisperModel(model_size, device="auto", compute_type="auto")

    def transcribe(self, chunk: AudioChunk) -> str:
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as handle:
            path = Path(handle.name)
        try:
            sf.write(path, chunk.samples, chunk.sample_rate)
            segments, _ = self.model.transcribe(str(path), language=self.language, vad_filter=True)
            return " ".join(segment.text.strip() for segment in segments).strip()
        finally:
            path.unlink(missing_ok=True)
