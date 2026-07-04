import json

from meeting_translator.panel import PanelConfig, PanelState, create_start_command, make_app
from meeting_translator.transcript import TranscriptEntry, TranscriptWriter


class FakeProcess:
    def __init__(self, returncode=None):
        self.returncode = returncode
        self.terminated = False

    def poll(self):
        return self.returncode

    def terminate(self):
        self.terminated = True
        self.returncode = -15


def test_create_start_command_uses_selected_devices_and_output_dir(tmp_path):
    command = create_start_command([1, 3], tmp_path, whisper_model="small", window_seconds=5, no_translate=True)

    assert command[:3] == ["meeting-translator", "run", "--output-dir"]
    assert str(tmp_path) in command
    assert command.count("--device") == 2
    assert "1" in command
    assert "3" in command
    assert "--no-translate" in command


def test_panel_state_starts_and_stops_process(tmp_path):
    created = []

    def fake_popen(command, env=None, log_path=None):
        created.append((command, env))
        return FakeProcess()

    state = PanelState(output_dir=tmp_path, popen=fake_popen)

    status = state.start([1, 3], no_translate=True)
    assert status["running"] is True
    assert created

    stopped = state.stop()
    assert stopped["running"] is False
    assert state.process.terminated is True


def test_panel_state_passes_model_config_via_environment(tmp_path):
    created = []

    def fake_popen(command, env=None, log_path=None):
        created.append((command, env))
        return FakeProcess()

    state = PanelState(output_dir=tmp_path, popen=fake_popen)
    config = PanelConfig(api_key="sk-test", base_url="https://llm.test/v1/chat/completions", model="gpt-test")

    state.start([1], config=config)

    command, env = created[0]
    assert "sk-test" not in " ".join(command)
    assert env["OPENAI_API_KEY"] == "sk-test"
    assert env["OPENAI_BASE_URL"] == "https://llm.test/v1/chat/completions"
    assert env["MEETING_TRANSLATOR_MODEL"] == "gpt-test"


def test_panel_state_reads_transcript_entries(tmp_path):
    writer = TranscriptWriter(tmp_path / "meeting")
    writer.append(TranscriptEntry("mixed", "t1", "t2", "hello", "你好"))

    state = PanelState(output_dir=tmp_path)

    assert state.transcript() == [{"source": "mixed", "started_at": "t1", "ended_at": "t2", "original": "hello", "chinese": "你好"}]


def test_panel_http_status_endpoint_returns_json(tmp_path):
    state = PanelState(output_dir=tmp_path)
    app = make_app(state)
    status, headers, body = app.handle("GET", "/api/status", b"")

    assert status == "200 OK"
    assert headers["Content-Type"] == "application/json; charset=utf-8"
    assert json.loads(body.decode("utf-8"))["running"] is False


def test_panel_http_devices_endpoint_uses_injected_provider(tmp_path):
    state = PanelState(output_dir=tmp_path)
    app = make_app(state, device_provider=lambda: [{"index": 7, "name": "Loopback", "channels": 2, "sample_rate": 48000}])

    status, headers, body = app.handle("GET", "/api/devices", b"")

    assert status == "200 OK"
    assert json.loads(body.decode("utf-8"))["devices"][0]["name"] == "Loopback"


def test_panel_http_levels_endpoint_uses_selected_devices(tmp_path):
    state = PanelState(output_dir=tmp_path)
    seen = []

    def level_provider(devices, seconds=1.0):
        seen.append((devices, seconds))
        return [{"index": devices[0], "name": "Loopback", "rms": 0.1, "peak": 0.2, "active": True}]

    app = make_app(state, level_provider=level_provider)

    status, headers, body = app.handle("POST", "/api/levels", json.dumps({"devices": [7], "seconds": 0.25}).encode("utf-8"))

    assert status == "200 OK"
    assert seen == [([7], 0.25)]
    assert json.loads(body.decode("utf-8"))["levels"][0]["active"] is True


def test_panel_http_start_accepts_model_config_without_exposing_key_in_status(tmp_path):
    created = []

    def fake_popen(command, env=None, log_path=None):
        created.append((command, env))
        return FakeProcess()

    state = PanelState(output_dir=tmp_path, popen=fake_popen)
    app = make_app(state)
    payload = {"devices": [1], "api_key": "secret", "base_url": "https://llm.test/v1/chat/completions", "model": "gpt-test"}

    status, headers, body = app.handle("POST", "/api/start", json.dumps(payload).encode("utf-8"))

    response = json.loads(body.decode("utf-8"))
    assert status == "200 OK"
    assert "secret" not in json.dumps(response)
    assert created[0][1]["OPENAI_API_KEY"] == "secret"


def test_panel_http_errors_are_returned_as_json(tmp_path):
    state = PanelState(output_dir=tmp_path)
    app = make_app(state, device_provider=lambda: (_ for _ in ()).throw(RuntimeError("audio unavailable")))

    status, headers, body = app.handle("GET", "/api/devices", b"")

    assert status == "500 Internal Server Error"
    assert headers["Content-Type"] == "application/json; charset=utf-8"
    assert json.loads(body.decode("utf-8"))["error"] == "audio unavailable"


def test_panel_rejects_translation_start_without_api_key(tmp_path, monkeypatch):
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    monkeypatch.delenv("VOICE_TOOLS_OPENAI_KEY", raising=False)
    state = PanelState(output_dir=tmp_path)
    app = make_app(state)
    payload = {"devices": [1], "no_translate": False, "api_key": ""}

    status, headers, body = app.handle("POST", "/api/start", json.dumps(payload).encode("utf-8"))

    assert status == "400 Bad Request"
    assert "API Key" in json.loads(body.decode("utf-8"))["error"]


def test_panel_status_reports_process_exit_code_and_log_tail(tmp_path):
    class ExitedProcess:
        pid = 123

        def poll(self):
            return 1

    state = PanelState(output_dir=tmp_path)
    state.process = ExitedProcess()
    state.command = ["meeting-translator", "run"]
    state.log_path.write_text("first\nlast error\n", encoding="utf-8")

    status = state.status()

    assert status["running"] is False
    assert status["exit_code"] == 1
    assert status["log_tail"] == "first\nlast error\n"
