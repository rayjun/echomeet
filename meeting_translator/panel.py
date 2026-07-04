from __future__ import annotations

import argparse
import json
import os
import subprocess
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Callable
from urllib.parse import urlparse

from meeting_translator.audio import list_input_devices, measure_input_levels


@dataclass(frozen=True)
class PanelConfig:
    api_key: str = ""
    base_url: str = ""
    model: str = ""

    def env(self) -> dict[str, str]:
        values = {}
        if self.api_key:
            values["OPENAI_API_KEY"] = self.api_key
        if self.base_url:
            values["OPENAI_BASE_URL"] = self.base_url
        if self.model:
            values["MEETING_TRANSLATOR_MODEL"] = self.model
        return values


def create_start_command(
    devices: list[int],
    output_dir: Path,
    whisper_model: str = "small",
    window_seconds: float = 8.0,
    no_translate: bool = False,
) -> list[str]:
    command = [
        "meeting-translator",
        "run",
        "--output-dir",
        str(output_dir),
        "--whisper-model",
        whisper_model,
        "--window-seconds",
        str(window_seconds),
    ]
    for device in devices:
        command.extend(["--device", str(device)])
    if no_translate:
        command.append("--no-translate")
    return command


def _default_popen(command: list[str], env: dict[str, str] | None = None, log_path: Path | None = None):
    log_handle = open(log_path or os.devnull, "ab", buffering=0)
    return subprocess.Popen(command, stdout=log_handle, stderr=subprocess.STDOUT, env=env)


class PanelState:
    def __init__(self, output_dir: Path, popen: Callable | None = None):
        self.output_dir = Path(output_dir)
        self.output_dir.mkdir(parents=True, exist_ok=True)
        self.log_path = self.output_dir / "meeting-translator.log"
        self.popen = popen or _default_popen
        self.process = None
        self.command: list[str] | None = None

    def status(self) -> dict:
        exit_code = self.process.poll() if self.process is not None else None
        running = self.process is not None and exit_code is None
        return {
            "running": running,
            "pid": getattr(self.process, "pid", None) if running else None,
            "exit_code": exit_code,
            "output_dir": str(self.output_dir),
            "command": self.command,
            "log_path": str(self.log_path),
            "log_tail": self._log_tail(),
        }

    def _log_tail(self) -> str:
        if not self.log_path.exists():
            return ""
        text = self.log_path.read_text(encoding="utf-8", errors="replace")
        return "\n".join(text.splitlines()[-40:]) + ("\n" if text.endswith("\n") else "")

    def start(
        self,
        devices: list[int],
        whisper_model: str = "small",
        window_seconds: float = 8.0,
        no_translate: bool = False,
        config: PanelConfig | None = None,
    ) -> dict:
        if self.status()["running"]:
            return self.status()
        command = create_start_command(devices, self.output_dir, whisper_model, window_seconds, no_translate)
        env = os.environ.copy()
        if config is not None:
            env.update(config.env())
        self.process = self.popen(command, env=env, log_path=self.log_path)
        self.command = command
        return self.status()

    def stop(self) -> dict:
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
        return self.status()

    def transcript(self) -> list[dict]:
        path = self.output_dir / "meeting.jsonl"
        if not path.exists():
            return []
        entries = []
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.strip():
                entries.append(json.loads(line))
        return entries


class PanelApp:
    def __init__(
        self,
        state: PanelState,
        device_provider: Callable[[], list[dict]] | None = None,
        level_provider: Callable[[list[int], float], list[dict]] | None = None,
    ):
        self.state = state
        self.device_provider = device_provider or list_input_devices
        self.level_provider = level_provider or measure_input_levels

    def handle(self, method: str, path: str, body: bytes) -> tuple[str, dict[str, str], bytes]:
        try:
            return self._handle(method, path, body)
        except Exception as exc:
            return self._json({"error": str(exc)}, status="500 Internal Server Error")

    def _handle(self, method: str, path: str, body: bytes) -> tuple[str, dict[str, str], bytes]:
        parsed = urlparse(path)
        if method == "GET" and parsed.path == "/":
            return "200 OK", {"Content-Type": "text/html; charset=utf-8"}, HTML.encode("utf-8")
        if method == "GET" and parsed.path == "/api/status":
            return self._json(self.state.status())
        if method == "GET" and parsed.path == "/api/devices":
            return self._json({"devices": self.device_provider()})
        if method == "POST" and parsed.path == "/api/levels":
            payload = json.loads(body.decode("utf-8") or "{}")
            devices = [int(device) for device in payload.get("devices", [])]
            seconds = float(payload.get("seconds", 1.0))
            return self._json({"levels": self.level_provider(devices, seconds)})
        if method == "GET" and parsed.path == "/api/transcript":
            return self._json({"entries": self.state.transcript()})
        if method == "POST" and parsed.path == "/api/start":
            payload = json.loads(body.decode("utf-8") or "{}")
            config = PanelConfig(
                api_key=str(payload.get("api_key", "")),
                base_url=str(payload.get("base_url", "")),
                model=str(payload.get("model", "")),
            )
            if not bool(payload.get("no_translate", False)) and not (config.api_key or os.getenv("OPENAI_API_KEY") or os.getenv("VOICE_TOOLS_OPENAI_KEY")):
                return self._json({"error": "API Key is required unless 不调用翻译/只转写 is enabled"}, status="400 Bad Request")
            status = self.state.start(
                [int(device) for device in payload.get("devices", [])],
                whisper_model=payload.get("whisper_model", "small"),
                window_seconds=float(payload.get("window_seconds", 8)),
                no_translate=bool(payload.get("no_translate", False)),
                config=config,
            )
            return self._json(status)
        if method == "POST" and parsed.path == "/api/stop":
            return self._json(self.state.stop())
        return "404 Not Found", {"Content-Type": "text/plain; charset=utf-8"}, b"Not found"

    def _json(self, payload: dict, status: str = "200 OK") -> tuple[str, dict[str, str], bytes]:
        return status, {"Content-Type": "application/json; charset=utf-8"}, json.dumps(payload, ensure_ascii=False).encode("utf-8")


def make_app(
    state: PanelState,
    device_provider: Callable[[], list[dict]] | None = None,
    level_provider: Callable[[list[int], float], list[dict]] | None = None,
) -> PanelApp:
    return PanelApp(state, device_provider=device_provider, level_provider=level_provider)


def make_handler(app: PanelApp):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            self._send(*app.handle("GET", self.path, b""))

        def do_POST(self):
            length = int(self.headers.get("Content-Length", "0"))
            self._send(*app.handle("POST", self.path, self.rfile.read(length)))

        def log_message(self, format, *args):
            return

        def _send(self, status: str, headers: dict[str, str], body: bytes):
            code = int(status.split()[0])
            self.send_response(code)
            for key, value in headers.items():
                self.send_header(key, value)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    return Handler


HTML = """
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Meeting Translator</title>
  <style>
    :root { color-scheme: dark; font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif; }
    body { margin: 0; background: #0b1020; color: #eef2ff; }
    main { max-width: 980px; margin: 0 auto; padding: 28px; }
    .card { background: #121a31; border: 1px solid #26314f; border-radius: 18px; padding: 20px; margin-bottom: 16px; box-shadow: 0 18px 60px #0005; }
    h1 { margin: 0 0 8px; font-size: 28px; }
    .muted { color: #9aa7c7; }
    .error { color: #fca5a5; }
    button { border: 0; border-radius: 12px; padding: 10px 14px; font-weight: 700; color: #07101f; background: #86efac; cursor: pointer; }
    button.stop { background: #fca5a5; }
    button.secondary { background: #93c5fd; }
    label { display: block; padding: 8px 0; }
    input { accent-color: #86efac; }
    input[type="text"], input[type="password"], input[type="number"] { background: #0b1020; color: #eef2ff; border: 1px solid #33415f; border-radius: 10px; padding: 8px 10px; }
    .row { display: flex; flex-wrap: wrap; gap: 10px; align-items: center; }
    .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 12px; }
    .device { display: flex; align-items: center; gap: 10px; border: 1px solid #26314f; border-radius: 12px; padding: 10px; margin: 8px 0; cursor: pointer; }
    .device input { width: 20px; height: 20px; }
    .level { font-size: 12px; margin-left: auto; color: #9aa7c7; }
    .active-level { color: #86efac; }
    .entry { border-top: 1px solid #26314f; padding: 14px 0; }
    .zh { font-size: 18px; line-height: 1.7; }
    .orig { color: #9aa7c7; line-height: 1.5; }
    code { color: #bfdbfe; }
  </style>
</head>
<body>
<main>
  <section class="card">
    <h1>会议实时记录 / 中文翻译</h1>
    <div class="muted">选择麦克风和电脑/会议软件音频设备，点击开始。输出会同步写入 transcripts/meeting.md。</div>
  </section>
  <section class="card">
    <h2>音频设备</h2>
    <div class="row">
      <button class="secondary" onclick="loadDevices()">刷新设备</button>
      <button class="secondary" onclick="checkLevels()">检测音量</button>
      <button onclick="start()">开始记录</button>
      <button class="stop" onclick="stop()">停止</button>
      <label><input id="noTranslate" type="checkbox"> 不调用翻译，只转写</label>
      <label>窗口秒数 <input id="windowSeconds" type="number" value="8" min="2" max="60" style="width: 70px"></label>
    </div>
    <p id="status" class="muted"></p>
    <div id="devices" class="muted">正在加载音频设备...</div>
  </section>
  <section class="card">
    <h2>大模型 API</h2>
    <div class="muted">留空则使用当前环境变量；填写后只传给后台记录进程，不会显示在状态命令里。</div>
    <div class="grid">
      <label>API Key <input id="apiKey" type="password" placeholder="OPENAI_API_KEY 或兼容服务 key"></label>
      <label>Base URL <input id="baseUrl" type="text" placeholder="https://api.openai.com/v1/chat/completions"></label>
      <label>Model <input id="modelName" type="text" placeholder="gpt-4o-mini"></label>
    </div>
  </section>
  <section class="card">
    <h2>实时内容</h2>
    <div id="transcript" class="muted">等待记录...</div>
  </section>
</main>
<script>
async function api(path, options = {}) {
  const res = await fetch(path, options)
  const data = await res.json()
  if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`)
  return data
}
async function loadDevices() {
  try {
    devices.className = 'muted'
    devices.textContent = '正在加载音频设备...'
    const data = await api('/api/devices')
    devices.className = ''
    devices.innerHTML = data.devices.length ? data.devices.map(d => `<label class="device" data-device="${d.index}"><input type="checkbox" value="${d.index}"><span>${d.index}: ${d.name} (${d.channels} ch, ${d.sample_rate} Hz)</span><span class="level" id="level-${d.index}">未检测</span></label>`).join('') : '<span class="muted">没有找到输入设备</span>'
  } catch (err) {
    devices.className = 'error'
    devices.textContent = `无法加载音频设备：${err.message}`
  }
}
async function refreshStatus() {
  try {
    const data = await api('/api/status')
    status.className = data.exit_code ? 'error' : 'muted'
    if (data.running) {
      status.textContent = `运行中：${data.command.join(' ')}`
    } else if (data.exit_code) {
      status.textContent = `进程已退出，退出码 ${data.exit_code}。日志：${data.log_tail || data.log_path}`
    } else {
      status.textContent = `已停止，输出目录：${data.output_dir}`
    }
  } catch (err) {
    status.className = 'error'
    status.textContent = `状态读取失败：${err.message}`
  }
}
async function checkLevels() {
  const selected = [...devices.querySelectorAll('input:checked')].map(x => Number(x.value))
  if (!selected.length) { alert('请先勾选要检测的输入设备'); return }
  selected.forEach(id => { const el = document.getElementById(`level-${id}`); if (el) { el.className = 'level'; el.textContent = '检测中...' } })
  try {
    const data = await api('/api/levels', { method: 'POST', body: JSON.stringify({ devices: selected, seconds: 1 }) })
    data.levels.forEach(level => {
      const el = document.getElementById(`level-${level.index}`)
      if (!el) return
      el.className = level.active ? 'level active-level' : 'level'
      el.textContent = level.active ? `有声音 rms=${level.rms}` : `无声音 rms=${level.rms}`
    })
    if (!data.levels.some(level => level.active)) alert('所选设备未检测到声音。网页视频通常需要 BlackHole/Loopback 这类系统音频回环设备。')
  } catch (err) { alert(`音量检测失败：${err.message}`) }
}
async function start() {
  const selected = [...devices.querySelectorAll('input:checked')].map(x => Number(x.value))
  if (!selected.length) { alert('请至少选择一个输入设备'); return }
  try {
    await api('/api/start', { method: 'POST', body: JSON.stringify({ devices: selected, window_seconds: Number(windowSeconds.value), no_translate: noTranslate.checked, api_key: apiKey.value, base_url: baseUrl.value, model: modelName.value }) })
    refreshStatus()
  } catch (err) { alert(`启动失败：${err.message}`) }
}
async function stop() { await api('/api/stop', { method: 'POST' }); refreshStatus() }
async function refreshTranscript() {
  try {
    const data = await api('/api/transcript')
    transcript.className = ''
    transcript.innerHTML = data.entries.length ? data.entries.slice().reverse().map(e => `<div class="entry"><div class="muted">${e.started_at} → ${e.ended_at}</div><div class="zh">${e.chinese}</div><div class="orig">${e.original}</div></div>`).join('') : '<span class="muted">等待记录...</span>'
  } catch (err) {
    transcript.className = 'error'
    transcript.textContent = `读取记录失败：${err.message}`
  }
}
loadDevices(); refreshStatus(); refreshTranscript(); setInterval(refreshStatus, 2000); setInterval(refreshTranscript, 2000)
</script>
</body>
</html>
"""


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Meeting Translator web panel")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8876)
    parser.add_argument("--output-dir", default="transcripts")
    args = parser.parse_args(argv)

    state = PanelState(Path(args.output_dir))
    app = make_app(state)
    server = ThreadingHTTPServer((args.host, args.port), make_handler(app))
    print(f"Meeting Translator panel: http://{args.host}:{args.port}", flush=True)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
