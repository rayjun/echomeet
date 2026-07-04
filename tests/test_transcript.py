import json

from meeting_translator.transcript import TranscriptEntry, TranscriptWriter


def test_transcript_writer_appends_jsonl_and_markdown(tmp_path):
    writer = TranscriptWriter(tmp_path / "meeting")
    entry = TranscriptEntry(
        source="mixed",
        started_at="2026-06-30T10:00:00+08:00",
        ended_at="2026-06-30T10:00:05+08:00",
        original="We should ship the demo tomorrow.",
        chinese="我们应该明天发布演示。",
    )

    writer.append(entry)

    json_line = (tmp_path / "meeting.jsonl").read_text(encoding="utf-8").strip()
    assert json.loads(json_line)["chinese"] == "我们应该明天发布演示。"

    markdown = (tmp_path / "meeting.md").read_text(encoding="utf-8")
    assert "# Meeting Transcript" in markdown
    assert "**原文**: We should ship the demo tomorrow." in markdown
    assert "**中文**: 我们应该明天发布演示。" in markdown
