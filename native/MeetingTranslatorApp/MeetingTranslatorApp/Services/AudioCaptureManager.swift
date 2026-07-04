import Foundation
import CoreAudio
import AVFoundation
import AppKit

final class AudioCaptureManager: ObservableObject {
    @Published var isCapturing = false
    @Published var errorMessage: String?
    @Published var audioFrameCount: Int = 0

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var audioEngine: AVAudioEngine?
    private var savedDefaultInput: AudioDeviceID = 0
    private var audioSink: ((AudioData) -> Void)?
    private var logFrameCount = 0

    private func logToFile(_ message: String) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("EchoMeet", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let logURL = dir.appendingPathComponent("debug.log")
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(ts)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(data); h.closeFile() }
            } else { try? data.write(to: logURL) }
        }
    }

    func startCapture(includeMic: Bool, audioSink: @escaping (AudioData) -> Void) {
        logToFile("startCapture: includeMic=\(includeMic)")
        errorMessage = nil
        self.audioSink = audioSink

        // 1. Create Core Audio Process Tap — capture all system output audio
        let tapDesc = CATapDescription()
        tapDesc.name = "EchoMeet"
        tapDesc.isPrivate = false
        tapDesc.muteBehavior = CATapMuteBehavior.unmuted
        tapDesc.isMixdown = true
        tapDesc.isMono = true
        // No processes, no deviceUID — capture all system output

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let createStatus: OSStatus
        if #available(macOS 14.2, *) {
            createStatus = AudioHardwareCreateProcessTap(tapDesc, &newTapID)
        } else {
            errorMessage = "需要 macOS 14.2 或更高版本"
            return
        }
        guard createStatus == noErr else {
            logToFile("CreateProcessTap failed: \(createStatus)")
            errorMessage = "无法创建音频 tap (code=\(createStatus))"
            return
        }
        tapID = newTapID
        logToFile("Tap created: ID=\(tapID)")

        // 2. Get tap UID
        var tapUID: CFString = "" as CFString
        var tapUidSize = UInt32(MemoryLayout<CFString>.size)
        var tapUidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let uidStatus = AudioObjectGetPropertyData(tapID, &tapUidAddr, 0, nil, &tapUidSize, &tapUID)
        guard uidStatus == noErr else {
            logToFile("Get tap UID failed: \(uidStatus)")
            errorMessage = "无法获取 tap UID"
            cleanupAll()
            return
        }

        // 3. Create aggregate device with tap as input
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "EchoMeet Device",
            kAudioAggregateDeviceUIDKey: "com.rayjun.echomeet.\(UUID().uuidString)",
            kAudioAggregateDeviceIsStackedKey: 0
        ]
        var newDeviceID: AudioObjectID = 0
        let aggStatus = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &newDeviceID)
        guard aggStatus == noErr else {
            logToFile("CreateAggregateDevice failed: \(aggStatus)")
            errorMessage = "无法创建聚合设备"
            cleanupAll()
            return
        }
        aggregateDeviceID = newDeviceID
        logToFile("Aggregate device: ID=\(aggregateDeviceID)")

        // 4. Add tap to aggregate device
        var tapListAddr = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyTapList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let tapList: CFArray = [tapUID] as CFArray
        var tapListMut = tapList
        let listSize = UInt32(MemoryLayout<CFArray>.size)
        let setStatus = AudioObjectSetPropertyData(aggregateDeviceID, &tapListAddr, 0, nil, listSize, &tapListMut)
        if setStatus != noErr {
            logToFile("Set tap list failed: \(setStatus)")
        } else {
            logToFile("Tap added to aggregate device")
        }

        // 5. Save current default input, set aggregate device as default input
        var defaultInputAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var savedSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultInputAddr, 0, nil, &savedSize, &savedDefaultInput)
        logToFile("Saved default input: \(savedDefaultInput)")

        let setInputStatus = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultInputAddr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &aggregateDeviceID)
        if setInputStatus != noErr {
            logToFile("Set default input failed: \(setInputStatus)")
        } else {
            logToFile("Default input set to aggregate device")
        }

        // 6. Start AVAudioEngine — it will use the aggregate device as default input
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        logToFile("Engine input format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount)ch")

        // Use the engine's native format, convert later
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
            guard let self = self else { return }
            let samples = Self.extractSamples(from: buffer)
            if samples.isEmpty { return }

            DispatchQueue.main.async {
                self.audioFrameCount += 1
                self.logFrameCount += 1
                if self.logFrameCount == 1 || self.logFrameCount % 100 == 0 {
                    self.logToFile("Audio frame #\(self.logFrameCount): \(samples.count) samples")
                }
                self.audioSink?(AudioData(samples: samples, sampleRate: Int(inputFormat.sampleRate)))
            }
        }

        do {
            engine.prepare()
            try engine.start()
            audioEngine = engine
            isCapturing = true
            logToFile("Audio engine started successfully!")
        } catch {
            logToFile("Engine start failed: \(error)")
            errorMessage = "音频引擎启动失败: \(error.localizedDescription)"
            // Restore default input
            AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultInputAddr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &savedDefaultInput)
            cleanupAll()
        }
    }

    private static func extractSamples(from buffer: AVAudioPCMBuffer) -> [Int16] {
        let frameCount = Int(buffer.frameLength)
        if let int16Data = buffer.int16ChannelData?[0] {
            return Array(UnsafeBufferPointer(start: int16Data, count: frameCount))
        }
        if let floatData = buffer.floatChannelData?[0] {
            var result = [Int16](repeating: 0, count: frameCount)
            for i in 0..<frameCount {
                let clamped = max(-1.0, min(1.0, floatData[i]))
                result[i] = Int16(clamped * Float32(Int16.max))
            }
            return result
        }
        return []
    }

    func stopCapture() {
        logToFile("stopCapture called")

        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            audioEngine = nil
        }

        // Restore default input device
        var defaultInputAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if savedDefaultInput != 0 {
            AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultInputAddr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &savedDefaultInput)
            logToFile("Default input restored to \(savedDefaultInput)")
            savedDefaultInput = 0
        }

        cleanupAll()
        isCapturing = false
        logToFile("Capture stopped")
    }

    private func cleanupAll() {
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            if #available(macOS 14.2, *) {
                AudioHardwareDestroyProcessTap(tapID)
            }
            tapID = kAudioObjectUnknown
        }
    }
}

struct AudioData {
    let samples: [Int16]
    let sampleRate: Int
}