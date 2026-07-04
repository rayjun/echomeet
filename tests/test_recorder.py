import numpy as np

from meeting_translator.audio import AudioChunk
from meeting_translator.recorder import MeetingRecorder


class FakeAudioStream:
    def __init__(self):
        self.calls = 0

    def read_window(self, seconds):
        self.calls += 1
        if self.calls == 1:
            return AudioChunk("mixed", 16000, np.ones((1600, 1), dtype=np.float32))
        return None


class FakeTranscriber:
    def transcribe(self, chunk):
        return "hello team"


class FakeTranslator:
    def translate(self, text):
        return "团队好"


def test_meeting_recorder_processes_one_window_and_writes_transcript(tmp_path):
    recorder = MeetingRecorder(
        audio_stream=FakeAudioStream(),
        transcriber=FakeTranscriber(),
        translator=FakeTranslator(),
        output_dir=tmp_path,
        window_seconds=1,
        max_windows=1,
    )

    entries = recorder.run()

    assert len(entries) == 1
    assert entries[0].original == "hello team"
    assert entries[0].chinese == "团队好"
    assert (tmp_path / "meeting.jsonl").exists()
    assert "团队好" in (tmp_path / "meeting.md").read_text(encoding="utf-8")
