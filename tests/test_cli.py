from meeting_translator.cli import build_parser


def test_cli_accepts_multiple_audio_devices():
    args = build_parser().parse_args(["run", "--device", "0", "--device", "3", "--output-dir", "out", "--max-windows", "1"])

    assert args.command == "run"
    assert args.devices == [0, 3]
    assert args.output_dir == "out"
    assert args.max_windows == 1
