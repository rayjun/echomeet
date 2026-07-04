# EchoMeet 🔊

A native macOS app for real-time meeting transcription and translation. Captures system audio (browser, meeting apps) and microphone, transcribes with on-device speech recognition, and translates to Chinese via OpenAI-compatible APIs.

![macOS 14+](https://img.shields.io/badge/macOS-14.0%2B-blue)
![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange)
![License: MIT](https://img.shields.io/badge/License-MIT-green)

## Features

- **System Audio Capture** — Uses Core Audio Process Tap to capture audio from any app (Chrome, Safari, Teams, Zoom, etc.) without virtual audio devices
- **On-Device Speech Recognition** — Powered by `SFSpeechRecognizer` for free, real-time transcription with no model downloads
- **Chinese Translation** — Integrates with any OpenAI-compatible API (OpenAI, Ollama, LM Studio, etc.)
- **Native SwiftUI Interface** — Clean, Notion-like experience with one-click start/stop
- **Export** — Save transcripts as Markdown with original text and Chinese translation side by side
- **Privacy First** — All API keys stored locally via UserDefaults, no telemetry, no cloud relay

## Architecture

```
┌─────────────────────────────────────────────────┐
│                   EchoMeet App                   │
│                                                  │
│  ┌──────────────┐  ┌────────────┐  ┌─────────┐  │
│  │ AudioCapture │→│  Speech    │→│Translator│  │
│  │   Manager    │  │ Recognizer │  │         │  │
│  │              │  │  Manager   │  │ (URLSess)│  │
│  │ Core Audio   │  │ SFSpeech   │  │ OpenAI   │  │
│  │ Process Tap  │  │ Recognizer │  │ compat.  │  │
│  └──────────────┘  └────────────┘  └─────────┘  │
│                                      ↓          │
│                              ┌────────────┐     │
│                              │ Transcript │     │
│                              │   Store    │     │
│                              │ JSON + MD  │     │
│                              └────────────┘     │
└─────────────────────────────────────────────────┘
```

### Components

| File | Role |
|------|------|
| `AudioCaptureManager.swift` | Core Audio Process Tap — captures system output audio via aggregate device + AVAudioEngine |
| `SpeechRecognizerManager.swift` | SFSpeechRecognizer — streams audio buffers for real-time transcription |
| `Translator.swift` | URLSession — calls OpenAI-compatible `/v1/chat/completions` endpoint |
| `TranscriptStore.swift` | Persistence — saves transcript entries as JSON, exports to Markdown |
| `MainView.swift` | SwiftUI main window — start/stop, live transcript display, export |
| `SettingsView.swift` | Settings — speech recognition language, API key, base URL, model |

## Requirements

- macOS 14.2+ (for Core Audio Process Tap API)
- Xcode 15+ or Swift 5.9+ command line tools
- An OpenAI-compatible API key for translation (optional — transcription works without it)

## Build & Run

```bash
cd native/MeetingTranslatorApp
swift build

# Create .app bundle
mkdir -p .build/EchoMeet.app/Contents/MacOS
cp .build/debug/EchoMeet .build/EchoMeet.app/Contents/MacOS/
cp MeetingTranslatorApp/Info.plist .build/EchoMeet.app/Contents/
codesign --force --deep --sign - .build/EchoMeet.app

# Launch
open .build/EchoMeet.app
```

### App Icon

The blue ripple icon is generated from `native/EchoMeet-Logo.svg`:

```bash
cd native
rsvg-convert -w 1024 -h 1024 EchoMeet-Logo.svg > icon_1024.png
# Generate .icns (see build scripts for details)
cp EchoMeet.icns MeetingTranslatorApp/.build/EchoMeet.app/Contents/Resources/AppIcon.icns
```

## Usage

1. **Grant Permissions** — On first launch, macOS will prompt for:
   - **Microphone** — needed for mic input
   - **Speech Recognition** — needed for SFSpeechRecognizer
   - If prompts don't appear, go to System Settings → Privacy & Security

2. **Configure Translation (optional)** — Click the ⚙️ gear icon:
   - **API Key** — Your OpenAI-compatible API key
   - **Base URL** — e.g. `https://api.openai.com/v1/chat/completions` (defaults to OpenAI)
   - **Model** — e.g. `gpt-4o-mini` (or your local model name)
   - **Recognition Language** — English, Chinese, Japanese, Korean, French, German, Spanish

3. **Start Recording** — Click "开始记录" to capture system audio + microphone
4. **View Live Transcript** — Recognized text appears in real-time; translations are added as sentences complete
5. **Export** — Click "导出 Markdown" to save the full transcript

## CLI Helper (Legacy)

The project also includes a Swift CLI helper for listing capturable apps:

```bash
cd native/MeetingAudioCapture
swift build
.build/debug/MeetingAudioCapture list    # list capturable apps
.build/debug/MeetingAudioCapture capture --app com.google.Chrome  # capture audio
```

A Python-based CLI toolkit (`meeting_translator/`) is also available for batch transcription using `faster-whisper`:

```bash
pip install -e ".[dev]"
meeting-translator devices          # list audio input devices
meeting-translator native-apps      # list capturable apps
meeting-translator native-run --app com.google.Chrome  # capture + transcribe
```

## Permissions

EchoMeet requires these macOS permissions:

| Permission | Purpose |
|-----------|---------|
| Microphone | Capture microphone input for in-person meeting audio |
| Speech Recognition | On-device transcription via SFSpeechRecognizer |
| Core Audio Process Tap | Capture system audio output (requires macOS 14.2+) |

No screen recording permission is needed — audio capture uses Core Audio Process Tap, not ScreenCaptureKit.

## Tech Stack

- **Audio Capture**: Core Audio Process Tap (`AudioHardwareCreateProcessTap`) + AVAudioEngine
- **Speech Recognition**: `SFSpeechRecognizer` (on-device, free)
- **Translation**: OpenAI-compatible Chat Completions API via `URLSession`
- **UI**: SwiftUI with native macOS form style
- **Persistence**: JSON + Markdown export to user-selected location

## License

MIT © rayjun