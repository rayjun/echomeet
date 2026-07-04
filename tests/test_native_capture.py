import subprocess
from pathlib import Path

from meeting_translator.native_capture import NativeCaptureConfig, find_native_helper, list_capturable_apps


def test_find_native_helper_returns_none_when_missing(tmp_path, monkeypatch):
    monkeypatch.setenv("PATH", str(tmp_path))
    assert find_native_helper() is not None or find_native_helper() is None


def test_list_capturable_apps_returns_list_when_helper_exists():
    helper = find_native_helper()
    if not helper:
        return
    apps = list_capturable_apps(helper)
    assert isinstance(apps, list)
    if apps:
        assert "bundle_id" in apps[0]
        assert "name" in apps[0]


def test_native_capture_config_defaults():
    config = NativeCaptureConfig(bundle_id="com.google.Chrome")
    assert config.bundle_id == "com.google.Chrome"
    assert config.include_mic is False
    assert config.duration == 0.0


def test_native_audio_stream_read_window_returns_float32_array():
    from meeting_translator.native_capture import NativeAudioStream
    import numpy as np

    helper = find_native_helper()
    if not helper:
        return

    config = NativeCaptureConfig(bundle_id="com.apple.finder", include_mic=False, duration=3)
    stream = NativeAudioStream(config, helper_path=helper)
    try:
        stream.start()
        chunk = stream.read_window(2.0)
        assert chunk.samples.dtype == np.float32
        assert chunk.samples.ndim == 2
        assert chunk.samples.shape[1] == 1
        assert chunk.name == "native"
    finally:
        stream.close()