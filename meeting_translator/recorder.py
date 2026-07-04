from __future__ import annotations

from datetime import datetime
from pathlib import Path

from meeting_translator.transcript import TranscriptEntry, TranscriptWriter


class MeetingRecorder:
    def __init__(
        self,
        audio_stream,
        transcriber,
        translator,
        output_dir: Path,
        window_seconds: float = 8.0,
        max_windows: int | None = None,
    ):
        self.audio_stream = audio_stream
        self.transcriber = transcriber
        self.translator = translator
        self.output_dir = Path(output_dir)
        self.window_seconds = window_seconds
        self.max_windows = max_windows
        self.writer = TranscriptWriter(self.output_dir / "meeting")

    def run(self) -> list[TranscriptEntry]:
        entries: list[TranscriptEntry] = []
        count = 0
        while self.max_windows is None or count < self.max_windows:
            started = datetime.now().astimezone()
            chunk = self.audio_stream.read_window(self.window_seconds)
            ended = datetime.now().astimezone()
            if chunk is None:
                break
            original = self.transcriber.transcribe(chunk).strip()
            if original:
                chinese = self.translator.translate(original).strip()
                entry = TranscriptEntry(
                    source=chunk.name,
                    started_at=started.isoformat(timespec="seconds"),
                    ended_at=ended.isoformat(timespec="seconds"),
                    original=original,
                    chinese=chinese,
                )
                self.writer.append(entry)
                entries.append(entry)
                print(f"[{entry.ended_at}] {entry.chinese}", flush=True)
            count += 1
        return entries
