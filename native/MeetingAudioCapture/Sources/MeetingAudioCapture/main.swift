import Foundation
import ScreenCaptureKit
import CoreAudio
import AVFoundation
import CoreMedia

// MARK: - CLI Entry Point

@main
struct MeetingAudioCapture {
    static func main() async {
        await CLI.run()
    }
}

enum CLI {
    static func run() async {
        let args = CommandLine.arguments

        if args.count < 2 {
            printUsage()
            return
        }

        let command = args[1]

        switch command {
        case "list":
            await listApps()
        case "capture":
            await capture(args)
        case "mic-test":
            micTest()
        default:
            printUsage()
        }
    }

    static func printUsage() {
        let lines = [
            "MeetingAudioCapture - native macOS audio capture for meeting transcription",
            "",
            "USAGE:",
            "  MeetingAudioCapture list",
            "    List capturable applications",
            "",
            "  MeetingAudioCapture capture --app <bundleID> [--mic] [--duration <seconds>]",
            "    Capture system audio from the specified app (and optionally microphone)",
            "    Audio is written to stdout as 16-bit PCM, 16kHz, mono",
            "",
            "  MeetingAudioCapture mic-test",
            "    List available microphone input devices",
            "",
            "EXAMPLES:",
            "  MeetingAudioCapture list",
            "  MeetingAudioCapture capture --app com.apple.Safari --mic --duration 30",
            "  MeetingAudioCapture capture --app com.google.Chrome --mic",
        ]
        for line in lines {
            print(line)
        }
    }

    static func listApps() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            var seen = Set<String>()
            print("Capturable applications:")
            for app in content.applications {
                let bid = app.bundleIdentifier
                if seen.contains(bid) { continue }
                seen.insert(bid)
                print("  \(bid)\t\(app.applicationName)")
            }
        } catch {
            errPrint("Error listing apps: \(error)")
        }
    }

    static func micTest() {
        let devices = AudioDevice.listInputDevices()
        print("Microphone input devices:")
        for d in devices {
            print("  \(d.id)\t\(d.name)\t\(d.channels)ch\t\(d.sampleRate)Hz")
        }
    }

    static func capture(_ args: [String]) async {
        var bundleID: String?
        var includeMic = false
        var duration: TimeInterval = 0

        var i = 2
        while i < args.count {
            switch args[i] {
            case "--app":
                i += 1
                if i < args.count { bundleID = args[i] }
            case "--mic":
                includeMic = true
            case "--duration":
                i += 1
                if i < args.count, let d = TimeInterval(args[i]) { duration = d }
            default:
                break
            }
            i += 1
        }

        guard let bid = bundleID else {
            errPrint("Error: --app is required")
            printUsage()
            return
        }

        let capturer = AudioCapturer(
            bundleID: bid,
            includeMic: includeMic,
            duration: duration
        )
        await capturer.run()
    }
}

// MARK: - Stderr helper

func errPrint(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

// MARK: - Audio Device helpers

struct AudioDevice {
    let id: AudioDeviceID
    let name: String
    let channels: Int
    let sampleRate: Double

    static func listInputDevices() -> [AudioDevice] {
        var result: [AudioDevice] = []

        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &size) == noErr else {
            return result
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propAddr, 0, nil, &size, &ids) == noErr else {
            return result
        }

        for id in ids {
            let info = deviceInfo(id)
            if info.channels > 0 {
                result.append(info)
            }
        }
        return result
    }

    static func deviceInfo(_ id: AudioDeviceID) -> AudioDevice {
        var nameRef: CFString = "" as CFString
        var propAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        AudioObjectGetPropertyData(id, &propAddr, 0, nil, &nameSize, &nameRef)

        var channels = 0
        propAddr.mSelector = kAudioDevicePropertyStreamConfiguration
        propAddr.mScope = kAudioDevicePropertyScopeInput
        var cfgSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(id, &propAddr, 0, nil, &cfgSize)
        if cfgSize > 0 {
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(cfgSize), alignment: 1)
            AudioObjectGetPropertyData(id, &propAddr, 0, nil, &cfgSize, buffer)
            let listPtr = buffer.assumingMemoryBound(to: AudioBufferList.self)
            let blist = UnsafeMutableAudioBufferListPointer(listPtr)
            for buf in blist {
                channels += Int(buf.mNumberChannels)
            }
            buffer.deallocate()
        }

        var rate = 0.0
        propAddr.mSelector = kAudioDevicePropertyNominalSampleRate
        propAddr.mScope = kAudioObjectPropertyScopeGlobal
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(id, &propAddr, 0, nil, &rateSize, &rate)

        return AudioDevice(id: id, name: nameRef as String, channels: channels, sampleRate: rate)
    }
}

// MARK: - Audio Capturer (ScreenCaptureKit)

final class AudioCapturer {
    let bundleID: String
    let includeMic: Bool
    let duration: TimeInterval
    var outputHandler: AudioOutputHandler?

    init(bundleID: String, includeMic: Bool, duration: TimeInterval) {
        self.bundleID = bundleID
        self.includeMic = includeMic
        self.duration = duration
    }

    func run() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )

            guard let app = content.applications.first(where: { $0.bundleIdentifier == bundleID }) else {
                errPrint("Error: app \(bundleID) not found among capturable apps")
                return
            }

            guard let display = content.displays.first else {
                errPrint("Error: no display found")
                return
            }
            let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])

            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 16000
            config.channelCount = 1
            config.showsCursor = false
            config.width = 2
            config.height = 2

            if #available(macOS 15.0, *) {
                config.captureMicrophone = includeMic
            } else {
                if includeMic {
                    errPrint("Warning: captureMicrophone requires macOS 15.0+, ignoring --mic")
                }
            }

            let handler = AudioOutputHandler()
            outputHandler = handler

            let stream = SCStream(filter: filter, configuration: config, delegate: handler)
            try stream.addStreamOutput(
                handler,
                type: SCStreamOutputType.audio,
                sampleHandlerQueue: DispatchQueue.global(qos: .userInitiated)
            )

            try await stream.startCapture()
            errPrint("CAPTURE_STARTED \(bundleID) mic=\(includeMic)")

            if duration > 0 {
                try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                try await stream.stopCapture()
                errPrint("CAPTURE_STOPPED")
            } else {
                try await Task.sleep(nanoseconds: UInt64.max / 4)
            }
        } catch {
            errPrint("Capture error: \(error)")
        }
    }
}

// MARK: - Stream Delegate & Output Handler

final class AudioOutputHandler: NSObject, SCStreamDelegate, SCStreamOutput {
    var sampleCount: UInt64 = 0
    let formatConverter = FormatConverter()

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard sampleBuffer.isValid else { return }
        guard CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }

        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

        let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        guard let asbdPtr = asbdPtr else { return }
        let inFormat = asbdPtr.pointee

        // Get the audio data from the sample buffer
        var blockBuffer: CMBlockBuffer?
        let bufferListSize = MemoryLayout<AudioBufferList>.size + 7 * MemoryLayout<AudioBuffer>.size
        let listPtr = UnsafeMutableRawPointer.allocate(byteCount: bufferListSize, alignment: 16)
        defer { listPtr.deallocate() }

        let audioList = listPtr.assumingMemoryBound(to: AudioBufferList.self)

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioList,
            bufferListSize: bufferListSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return }

        let blist = UnsafeMutableAudioBufferListPointer(audioList)
        guard let firstBuffer = blist.first else { return }
        guard firstBuffer.mData != nil else { return }

        let frameCount = Int(firstBuffer.mDataByteSize) / Int(inFormat.mBytesPerFrame)
        guard frameCount > 0 else { return }

        let pcmData = formatConverter.convert(
            firstBuffer.mData!,
            frameCount: frameCount,
            inFormat: inFormat
        )

        if !pcmData.isEmpty {
            pcmData.withUnsafeBytes { rawBuffer in
                let bytes = rawBuffer.baseAddress!
                let count = rawBuffer.count
                _ = FileHandle.standardOutput.write(Data(bytes: bytes, count: count))
            }
            sampleCount += UInt64(pcmData.count / 2)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        errPrint("Stream stopped with error: \(error)")
    }
}

// MARK: - Format Converter (to 16-bit PCM 16kHz mono)

final class FormatConverter {
    func convert(_ dataPtr: UnsafeMutableRawPointer, frameCount: Int, inFormat: AudioStreamBasicDescription) -> [UInt8] {
        // ScreenCaptureKit typically delivers Float32 non-interleaved
        // We convert to Int16 16kHz mono

        let inRate = inFormat.mSampleRate
        let inChannels = Int(inFormat.mChannelsPerFrame)
        let bytesPerFrame = Int(inFormat.mBytesPerFrame)
        let isFloat = (inFormat.mFormatFlags & kAudioFormatFlagIsFloat) != 0

        guard isFloat else {
            // If already int16, just copy with resampling
            return convertInt16(dataPtr, frameCount: frameCount, inRate: inRate, inChannels: inChannels, bytesPerFrame: bytesPerFrame)
        }

        let floatPtr = dataPtr.assumingMemoryBound(to: Float32.self)
        let ratio = inRate / 16000.0
        let outFrames = Int(Double(frameCount) / ratio)
        guard outFrames > 0 else { return [] }

        var result = [UInt8]()
        result.reserveCapacity(outFrames * 2)

        for i in 0..<outFrames {
            let srcIdx = Int(Double(i) * ratio)
            guard srcIdx < frameCount else { break }

            // Average channels to mono
            var sample: Float32 = 0.0
            if inChannels > 1 {
                for ch in 0..<inChannels {
                    sample += floatPtr[srcIdx * inChannels + ch]
                }
                sample /= Float32(inChannels)
            } else {
                sample = floatPtr[srcIdx]
            }

            let clamped = max(-1.0, min(1.0, sample))
            let int16 = Int16(clamped * Float32(Int16.max))
            result.append(UInt8(Int32(int16) & 0xFF))
            result.append(UInt8((Int32(int16) >> 8) & 0xFF))
        }

        return result
    }

    private func convertInt16(_ dataPtr: UnsafeMutableRawPointer, frameCount: Int, inRate: Double, inChannels: Int, bytesPerFrame: Int) -> [UInt8] {
        let int16Ptr = dataPtr.assumingMemoryBound(to: Int16.self)
        let ratio = inRate / 16000.0
        let outFrames = Int(Double(frameCount) / ratio)
        guard outFrames > 0 else { return [] }

        var result = [UInt8]()
        result.reserveCapacity(outFrames * 2)

        for i in 0..<outFrames {
            let srcIdx = Int(Double(i) * ratio)
            guard srcIdx < frameCount else { break }

            var sample: Int16 = 0
            if inChannels > 1 {
                var sum: Int32 = 0
                for ch in 0..<inChannels {
                    sum += Int32(int16Ptr[srcIdx * inChannels + ch])
                }
                sample = Int16(sum / Int32(inChannels))
            } else {
                sample = int16Ptr[srcIdx]
            }

            result.append(UInt8(Int32(sample) & 0xFF))
            result.append(UInt8((Int32(sample) >> 8) & 0xFF))
        }

        return result
    }
}