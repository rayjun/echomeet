from __future__ import annotations

import json
import os
import urllib.request
from typing import Callable


class OpenAICompatibleTranslator:
    def __init__(
        self,
        api_key: str | None = None,
        model: str | None = None,
        base_url: str | None = None,
        opener: Callable | None = None,
    ):
        self.api_key = api_key or os.getenv("OPENAI_API_KEY") or os.getenv("VOICE_TOOLS_OPENAI_KEY")
        self.model = model or os.getenv("MEETING_TRANSLATOR_MODEL", "gpt-4o-mini")
        self.base_url = base_url or os.getenv("OPENAI_BASE_URL", "https://api.openai.com/v1/chat/completions")
        self.opener = opener or urllib.request.urlopen
        if not self.api_key:
            raise ValueError("OPENAI_API_KEY or VOICE_TOOLS_OPENAI_KEY is required for Chinese translation")

    def translate(self, text: str) -> str:
        if not text.strip():
            return ""
        payload = {
            "model": self.model,
            "temperature": 0,
            "messages": [
                {
                    "role": "system",
                    "content": "Translate meeting transcript snippets into concise, natural Simplified Chinese. Preserve names, numbers, technical terms, decisions, and action items. Return only Chinese.",
                },
                {"role": "user", "content": text},
            ],
        }
        data = json.dumps(payload).encode("utf-8")
        request = urllib.request.Request(
            self.base_url,
            data=data,
            headers={"Authorization": f"Bearer {self.api_key}", "Content-Type": "application/json"},
            method="POST",
        )
        with self.opener(request, timeout=60) as response:
            result = json.loads(response.read().decode("utf-8"))
        return result["choices"][0]["message"]["content"].strip()


class NoopTranslator:
    def translate(self, text: str) -> str:
        return text
