from meeting_translator.translation import OpenAICompatibleTranslator


class FakeResponse:
    def __init__(self, payload):
        self.payload = payload

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def read(self):
        return self.payload


class FakeOpener:
    def __init__(self):
        self.requests = []

    def __call__(self, request, timeout):
        self.requests.append((request, timeout))
        return FakeResponse(b'{"choices":[{"message":{"content":"\xe4\xb8\xad\xe6\x96\x87"}}]}')


def test_openai_compatible_translator_sends_translation_prompt():
    opener = FakeOpener()
    translator = OpenAICompatibleTranslator(
        api_key="key",
        model="test-model",
        base_url="https://example.test/v1/chat/completions",
        opener=opener,
    )

    translated = translator.translate("Please review the launch plan.")

    assert translated == "中文"
    request, timeout = opener.requests[0]
    assert timeout == 60
    assert request.full_url == "https://example.test/v1/chat/completions"
    body = request.data.decode("utf-8")
    assert "test-model" in body
    assert "Please review the launch plan." in body
    assert request.headers["Authorization"] == "Bearer key"
