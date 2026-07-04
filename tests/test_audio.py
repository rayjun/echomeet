import numpy as np

from meeting_translator.audio import AudioChunk, mix_chunks


def test_mix_chunks_aligns_shorter_inputs_and_averages_channels():
    mic = AudioChunk("mic", 16000, np.array([[1.0], [1.0], [1.0], [1.0]], dtype=np.float32))
    system = AudioChunk("system", 16000, np.array([[0.0], [0.5]], dtype=np.float32))

    mixed = mix_chunks([mic, system])

    assert mixed.sample_rate == 16000
    assert mixed.name == "mixed"
    np.testing.assert_allclose(mixed.samples[:, 0], np.array([0.5, 0.75, 0.5, 0.5], dtype=np.float32))


def test_mix_chunks_collapses_stereo_to_mono_before_mixing():
    stereo = AudioChunk("system", 48000, np.array([[1.0, -1.0], [0.5, 0.5]], dtype=np.float32))
    mic = AudioChunk("mic", 48000, np.array([[0.5], [0.5]], dtype=np.float32))

    mixed = mix_chunks([stereo, mic])

    np.testing.assert_allclose(mixed.samples[:, 0], np.array([0.25, 0.5], dtype=np.float32))


def test_mix_chunks_rejects_mismatched_sample_rates():
    chunks = [
        AudioChunk("mic", 16000, np.zeros((2, 1), dtype=np.float32)),
        AudioChunk("system", 48000, np.zeros((2, 1), dtype=np.float32)),
    ]

    try:
        mix_chunks(chunks)
    except ValueError as exc:
        assert "same sample rate" in str(exc)
    else:
        raise AssertionError("expected mismatched sample rates to fail")


def test_multi_input_stream_opens_each_device_with_its_supported_channel_count():
    from meeting_translator.audio import MultiInputAudioStream

    opened = []

    class FakeStream:
        def __init__(self, **kwargs):
            opened.append(kwargs)

        def start(self):
            pass

        def stop(self):
            pass

        def close(self):
            pass

    class FakeSoundDevice:
        InputStream = FakeStream

        def query_devices(self, device):
            return {"max_input_channels": 2 if device == 3 else 1}

    stream = MultiInputAudioStream([1, 3], sample_rate=48000, sounddevice_module=FakeSoundDevice())
    stream.start()
    stream.close()

    assert [entry["channels"] for entry in opened] == [1, 2]


def test_measure_input_levels_reports_rms_peak_and_activity():
    from meeting_translator.audio import measure_input_levels

    class FakeStream:
        def __init__(self, callback, **kwargs):
            self.callback = callback
            self.kwargs = kwargs

        def start(self):
            self.callback(np.array([[0.0, 0.0], [0.5, -0.5]], dtype=np.float32), 2, None, None)

        def stop(self):
            pass

        def close(self):
            pass

    class FakeSoundDevice:
        InputStream = FakeStream

        def query_devices(self, device):
            return {"name": "Loopback", "max_input_channels": 2, "default_samplerate": 48000}

    levels = measure_input_levels([7], seconds=0, sounddevice_module=FakeSoundDevice())

    assert levels == [{"index": 7, "name": "Loopback", "rms": 0.353553, "peak": 0.5, "active": True}]
