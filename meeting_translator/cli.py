from __future__ import annotations

import argparse
from pathlib import Path


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Realtime meeting transcription and Chinese translation")
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("devices", help="list input devices")
    subparsers.add_parser("native-apps", help="list capturable apps via native helper")

    native_run = subparsers.add_parser("native-run", help="capture and transcribe using the native macOS helper")
    native_run.add_argument("--app", required=True, help="bundle ID of the app to capture (e.g. com.google.Chrome)")
    native_run.add_argument("--mic", action="store_true", help="also capture microphone (requires macOS 15+)")
    native_run.add_argument("--duration", type=float, default=0, help="stop after N seconds; 0 = unlimited")
    native_run.add_argument("--window-seconds", type=float, default=8.0)
    native_run.add_argument("--max-windows", type=int, default=None)
    native_run.add_argument("--output-dir", default="transcripts")
    native_run.add_argument("--whisper-model", default="small")
    native_run.add_argument("--language", default=None)
    native_run.add_argument("--no-translate", action="store_true")

    run = subparsers.add_parser("run", help="record, transcribe, and translate")
    run.add_argument("--device", dest="devices", action="append", type=int, required=True, help="input device index; pass twice for mic + computer/loopback audio")
    run.add_argument("--sample-rate", type=int, default=48000)
    run.add_argument("--window-seconds", type=float, default=8.0)
    run.add_argument("--max-windows", type=int, default=None, help="stop after N windows; useful for smoke tests")
    run.add_argument("--output-dir", default="transcripts")
    run.add_argument("--whisper-model", default="small")
    run.add_argument("--language", default=None, help="optional source language code for Whisper, e.g. en, zh")
    run.add_argument("--no-translate", action="store_true", help="write transcription without calling an LLM translator")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.command == "devices":
        from meeting_translator.audio import list_input_devices

        for device in list_input_devices():
            print(f"{device['index']}: {device['name']} ({device['channels']} ch, {device['sample_rate']} Hz)")
        return 0

    if args.command == "native-apps":
        from meeting_translator.native_capture import find_native_helper, list_capturable_apps

        helper = find_native_helper()
        if not helper:
            print("MeetingAudioCapture helper not found. Build it: cd native/MeetingAudioCapture && swift build")
            return 1
        apps = list_capturable_apps(helper)
        for app in apps:
            print(f"{app['bundle_id']}\t{app['name']}")
        return 0

    if args.command == "native-run":
        from meeting_translator.native_capture import NativeAudioStream, NativeCaptureConfig, find_native_helper
        from meeting_translator.recorder import MeetingRecorder
        from meeting_translator.transcriber import FasterWhisperTranscriber
        from meeting_translator.translation import NoopTranslator, OpenAICompatibleTranslator

        helper = find_native_helper()
        if not helper:
            print("MeetingAudioCapture helper not found. Build it: cd native/MeetingAudioCapture && swift build")
            return 1

        translator = NoopTranslator() if args.no_translate else OpenAICompatibleTranslator()
        transcriber = FasterWhisperTranscriber(args.whisper_model, language=args.language)
        config = NativeCaptureConfig(
            bundle_id=args.app,
            include_mic=args.mic,
            duration=args.duration if args.duration > 0 else 0,
        )
        with NativeAudioStream(config, helper_path=helper) as audio_stream:
            recorder = MeetingRecorder(
                audio_stream=audio_stream,
                transcriber=transcriber,
                translator=translator,
                output_dir=Path(args.output_dir),
                window_seconds=args.window_seconds,
                max_windows=args.max_windows,
            )
            recorder.run()
        return 0

    from meeting_translator.audio import MultiInputAudioStream
    from meeting_translator.recorder import MeetingRecorder
    from meeting_translator.transcriber import FasterWhisperTranscriber
    from meeting_translator.translation import NoopTranslator, OpenAICompatibleTranslator

    translator = NoopTranslator() if args.no_translate else OpenAICompatibleTranslator()
    transcriber = FasterWhisperTranscriber(args.whisper_model, language=args.language)
    with MultiInputAudioStream(args.devices, sample_rate=args.sample_rate) as audio_stream:
        recorder = MeetingRecorder(
            audio_stream=audio_stream,
            transcriber=transcriber,
            translator=translator,
            output_dir=Path(args.output_dir),
            window_seconds=args.window_seconds,
            max_windows=args.max_windows,
        )
        recorder.run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
