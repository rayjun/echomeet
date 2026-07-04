from __future__ import annotations

import queue
import time
from dataclasses import dataclass
from typing import Iterable

import numpy as np


@dataclass(frozen=True)
class AudioChunk:
    name: str
    sample_rate: int
    samples: np.ndarray


def _mono(samples: np.ndarray) -> np.ndarray:
    array = np.asarray(samples, dtype=np.float32)
    if array.ndim == 1:
        array = array.reshape(-1, 1)
    if array.shape[1] == 1:
        return array
    return array.mean(axis=1, keepdims=True, dtype=np.float32)


def mix_chunks(chunks: Iterable[AudioChunk]) -> AudioChunk:
    chunk_list = list(chunks)
    if not chunk_list:
        raise ValueError("at least one audio chunk is required")
    sample_rates = {chunk.sample_rate for chunk in chunk_list}
    if len(sample_rates) != 1:
        raise ValueError("all audio chunks must use the same sample rate")
    arrays = [_mono(chunk.samples) for chunk in chunk_list]
    max_len = max(array.shape[0] for array in arrays)
    padded = []
    for array in arrays:
        if array.shape[0] < max_len:
            array = np.pad(array, ((0, max_len - array.shape[0]), (0, 0)))
        padded.append(array)
    mixed = np.mean(np.stack(padded, axis=0), axis=0, dtype=np.float32)
    return AudioChunk("mixed", chunk_list[0].sample_rate, np.clip(mixed, -1.0, 1.0).astype(np.float32))


def list_input_devices() -> list[dict]:
    import sounddevice as sd

    devices = []
    for idx, device in enumerate(sd.query_devices()):
        if int(device.get("max_input_channels", 0)) > 0:
            devices.append(
                {
                    "index": idx,
                    "name": device.get("name", ""),
                    "channels": int(device.get("max_input_channels", 0)),
                    "sample_rate": int(device.get("default_samplerate", 48000)),
                }
            )
    return devices


def measure_input_levels(devices: list[int], seconds: float = 1.0, sounddevice_module=None) -> list[dict]:
    sd = sounddevice_module
    if sd is None:
        import sounddevice as sd

    levels = []
    for device in devices:
        info = sd.query_devices(device)
        channels = max(1, int(info.get("max_input_channels", 1)))
        sample_rate = int(info.get("default_samplerate", 48000))
        frames = []

        def callback(indata, frame_count, time_info, status):
            frames.append(np.asarray(indata, dtype=np.float32).copy())

        stream = sd.InputStream(device=device, channels=channels, samplerate=sample_rate, dtype="float32", callback=callback)
        stream.start()
        try:
            time.sleep(seconds)
        finally:
            stream.stop()
            stream.close()
        if frames:
            samples = np.concatenate(frames, axis=0)
            rms = float(np.sqrt(np.mean(samples * samples))) if samples.size else 0.0
            peak = float(np.max(np.abs(samples))) if samples.size else 0.0
        else:
            rms = 0.0
            peak = 0.0
        levels.append(
            {
                "index": int(device),
                "name": str(info.get("name", device)),
                "rms": round(rms, 6),
                "peak": round(peak, 6),
                "active": peak > 0.01 or rms > 0.003,
            }
        )
    return levels


class MultiInputAudioStream:
    def __init__(self, devices: list[int], sample_rate: int = 16000, sounddevice_module=None):
        if not devices:
            raise ValueError("at least one input device is required")
        self.devices = devices
        self.sample_rate = sample_rate
        self._sounddevice_module = sounddevice_module
        self._queues: list[queue.Queue[np.ndarray]] = [queue.Queue() for _ in devices]
        self._streams = []
        self._started = False

    def __enter__(self) -> "MultiInputAudioStream":
        self.start()
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.close()

    def start(self) -> None:
        if self._started:
            return
        sd = self._sounddevice_module
        if sd is None:
            import sounddevice as sd

        for device, chunk_queue in zip(self.devices, self._queues):
            channels = max(1, int(sd.query_devices(device).get("max_input_channels", 1)))

            def callback(indata, frames, time_info, status, chunk_queue=chunk_queue):
                chunk_queue.put(np.asarray(indata, dtype=np.float32).copy())

            stream = sd.InputStream(
                device=device,
                channels=channels,
                samplerate=self.sample_rate,
                dtype="float32",
                callback=callback,
            )
            stream.start()
            self._streams.append(stream)
        self._started = True

    def read_window(self, seconds: float) -> AudioChunk | None:
        if not self._started:
            self.start()
        time.sleep(seconds)
        device_chunks = []
        for device, chunk_queue in zip(self.devices, self._queues):
            frames = []
            while True:
                try:
                    frames.append(chunk_queue.get_nowait())
                except queue.Empty:
                    break
            if frames:
                samples = np.concatenate(frames, axis=0)
            else:
                samples = np.zeros((int(seconds * self.sample_rate), 1), dtype=np.float32)
            device_chunks.append(AudioChunk(str(device), self.sample_rate, samples))
        if not device_chunks:
            return None
        return mix_chunks(device_chunks)

    def close(self) -> None:
        for stream in self._streams:
            stream.stop()
            stream.close()
        self._streams.clear()
        self._started = False
