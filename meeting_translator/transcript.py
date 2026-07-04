from __future__ import annotations

import json
from dataclasses import asdict, dataclass
from pathlib import Path


@dataclass(frozen=True)
class TranscriptEntry:
    source: str
    started_at: str
    ended_at: str
    original: str
    chinese: str


class TranscriptWriter:
    def __init__(self, output_base: Path):
        self.output_base = output_base
        self.jsonl_path = output_base.with_suffix(".jsonl")
        self.markdown_path = output_base.with_suffix(".md")
        self.jsonl_path.parent.mkdir(parents=True, exist_ok=True)
        if not self.markdown_path.exists():
            self.markdown_path.write_text("# Meeting Transcript\n\n", encoding="utf-8")

    def append(self, entry: TranscriptEntry) -> None:
        with self.jsonl_path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(asdict(entry), ensure_ascii=False) + "\n")
        block = (
            f"## {entry.started_at} → {entry.ended_at} ({entry.source})\n\n"
            f"**原文**: {entry.original}\n\n"
            f"**中文**: {entry.chinese}\n\n"
        )
        with self.markdown_path.open("a", encoding="utf-8") as handle:
            handle.write(block)
