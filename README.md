# EchoMeet 🔊

A native macOS app for real-time meeting transcription and translation. Captures system audio (browser, meeting apps) and microphone, transcribes with on-device speech recognition, and translates to Chinese via OpenAI-compatible APIs.

## Features

- **System Audio Capture** — Uses Core Audio Process Tap to capture audio from any app (Chrome, Safari, Teams, Zoom, etc.) without virtual audio devices
- **On-Device Speech Recognition** — Powered by `SFSpeechRecognizer` for free, real-time transcription with no model downloads
- **Chinese Translation** — Integrates with any OpenAI-compatible API (OpenAI, Ollama, LM Studio, etc.)
- **Native SwiftUI Interface** — Clean, Notion-like experience with one-click start/stop
- **Export** — Save transcripts as Markdown with original text and Chinese translation side by side
- **Privacy First** — All API keys stored locally via UserDefaults, no telemetry, no cloud relay

## Installation

### Requirements

- macOS 14.2+ (for Core Audio Process Tap API)
- Xcode 15+ or Swift 5.9+ command line tools
- An OpenAI-compatible API key for translation (optional — transcription works without it)

### Build & Run

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

On first launch, macOS will prompt for **Microphone** and **Speech Recognition** permissions. If prompts don't appear, go to System Settings → Privacy & Security.