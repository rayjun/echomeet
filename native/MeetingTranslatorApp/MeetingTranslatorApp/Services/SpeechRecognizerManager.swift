import Foundation
import AVFoundation
import Speech
import OSLog

@available(macOS 26.0, *)
@MainActor
final class SpeechRecognizerManager: ObservableObject {
    @Published var currentText: String = ""
    @Published var isRunning = false
    @Published var errorMessage: String?
    @Published var currentSpeaker: Int = 1

    var onSentenceComplete: ((String, Int) -> Void)?

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var analyzeTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var converter: AVAudioConverter?

    private var lastSavedText: String = ""
    private var currentTranscript: String = ""
    private var lastResultText: String = ""
    private var resultStableCount: Int = 0
    private var stableThreshold: Int = 3

    private let fillerWords: Set<String> = [
        "um", "uh", "er", "ah", "hmm", "mm",
        "嗯", "啊", "呃", "哎", "那个", "这个",
    ]

    private let logger = Logger(subsystem: "com.rayjun.echomeet", category: "Speech")

    private func logToFile(_ message: String) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("EchoMeet", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let logURL = dir.appendingPathComponent("debug.log")
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(ts)] [Speech] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logURL.path) {
            if let h = try? FileHandle(forWritingTo: logURL) {
                h.seekToEndOfFile()
                h.write(data)
                h.closeFile()
            } else {
                try? data.write(to: logURL, options: .atomic)
            }
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }

    func requestAuthorization() async -> Bool {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        logToFile("Speech auth status: \(status.rawValue)")
        if status != .authorized {
            errorMessage = "语音识别权限未授权: \(status.rawValue)"
            return false
        }

        let micStatus = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        logToFile("Mic auth status: \(micStatus)")
        if !micStatus {
            errorMessage = "麦克风权限未授权"
            return false
        }
        return true
    }

    func start(locale: Locale = Locale(identifier: "en-US")) {
        stop()
        logToFile("Starting SpeechTranscriber for locale: \(locale.identifier)")

        guard SpeechTranscriber.isAvailable else {
            logToFile("SpeechTranscriber not available")
            errorMessage = "SpeechTranscriber 不可用"
            return
        }

        isRunning = true
        errorMessage = nil
        currentSpeaker = 1

        // Find matching locale and start capture asynchronously
        Task {
            await self.setupAndStart(locale: locale)
        }
    }

    private func setupAndStart(locale: Locale) async {
        // Find a matching locale from supportedLocales
        // macOS 26 uses underscore format (en_US) not hyphen format (en-US)
        let supportedLocales = await SpeechTranscriber.supportedLocales
        let matchingLocale = supportedLocales.first { loc in
            loc.language.languageCode == locale.language.languageCode &&
            loc.region == locale.region
        } ?? supportedLocales.first { loc in
            loc.language.languageCode == locale.language.languageCode
        }

        guard let actualLocale = matchingLocale else {
            logToFile("Locale \(locale.identifier) not supported. Supported: \(supportedLocales.map { $0.identifier })")
            errorMessage = "语言 \(locale.identifier) 不被支持"
            isRunning = false
            return
        }

        logToFile("Using locale: \(actualLocale.identifier) (requested: \(locale.identifier))")

        let transcriber = SpeechTranscriber(locale: actualLocale, preset: .progressiveTranscription)
        self.transcriber = transcriber

        // Create SpeechAnalyzer with the transcriber module
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        isRunning = true
        errorMessage = nil
        currentSpeaker = 1

        // Start asset preparation and audio capture
        await self.startAudioCapture()
    }

    private func startAudioCapture() async {
        guard let transcriber = self.transcriber, let analyzer = self.analyzer else {
            logToFile("Missing transcriber or analyzer")
            errorMessage = "识别器未初始化"
            isRunning = false
            return
        }

        // First, prepare the analyzer with the target audio format
        // SpeechTranscriber requires 16-bit signed integer PCM at 16kHz
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            logToFile("Failed to create target audio format")
            errorMessage = "音频格式创建失败"
            isRunning = false
            return
        }

        logToFile("Preparing analyzer...")
        do {
            try await analyzer.prepareToAnalyze(in: targetFormat)
            logToFile("Analyzer prepared successfully")
        } catch {
            logToFile("Analyzer prepare error: \(error)")
            errorMessage = "语音模型未就绪: \(error.localizedDescription)"
            isRunning = false
            return
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        self.audioEngine = engine
        self.inputNode = inputNode

        let inputFormat = inputNode.outputFormat(forBus: 0)
        let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        guard let converter = converter else {
            logToFile("Failed to create audio converter")
            errorMessage = "音频格式转换失败"
            isRunning = false
            return
        }
        self.converter = converter

        logToFile("Audio input: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount)ch → 16000Hz Int16")

        // Start the audio engine
        do {
            engine.prepare()
            try engine.start()
            logToFile("Audio engine started")
        } catch {
            logToFile("Engine start failed: \(error)")
            errorMessage = "音频引擎启动失败: \(error.localizedDescription)"
            isRunning = false
            return
        }

        // Create an async sequence for audio buffers
        let audioSequence = AsyncStream<AnalyzerInput> { continuation in
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
                if let converted = self.convertBuffer(buffer, converter: converter, to: targetFormat) {
                    continuation.yield(AnalyzerInput(buffer: converted))
                }
            }
        }

        // Start analyzing audio
        analyzeTask = Task {
            do {
                let lastTime = try await analyzer.analyzeSequence(audioSequence)
                if let lastTime = lastTime {
                    try await analyzer.finalizeAndFinish(through: lastTime)
                }
            } catch {
                await MainActor.run {
                    self.logToFile("Analyze error: \(error)")
                    self.errorMessage = "识别错误: \(error.localizedDescription)"
                }
            }
        }

        // Start collecting results
        resultTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    await MainActor.run {
                        self.handleResult(text)
                    }
                }
            } catch {
                await MainActor.run {
                    self.logToFile("Result error: \(error)")
                }
            }
        }

        logToFile("Transcription running")
    }

    private func convertBuffer(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / converter.inputFormat.sampleRate)
        guard frameCount > 0,
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }

        var error: NSError?
        var inputBuffer = buffer
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if status == .error || error != nil {
            return nil
        }
        outputBuffer.frameLength = frameCount
        return outputBuffer
    }

    private func handleResult(_ text: String) {
        let cleaned = cleanText(text)
        guard !cleaned.isEmpty else { return }

        currentText = cleaned

        // Track result stability — progressive transcription sends
        // multiple updates for the same audio; only save when stable
        if cleaned == lastResultText {
            resultStableCount += 1
        } else {
            lastResultText = cleaned
            resultStableCount = 0
        }

        // Save when:
        // 1. Result has been stable for N consecutive callbacks, OR
        // 2. Sentence-ending punctuation detected with enough content, OR
        // 3. Text is getting too long
        if resultStableCount >= stableThreshold {
            if !cleaned.isEmpty && cleaned != lastSavedText {
                saveSentence(cleaned)
            }
            resultStableCount = 0
        } else if let split = checkSentenceSplit(cleaned) {
            // Punctuation-based split — but only save if different from last
            if split != lastSavedText {
                saveSentence(split)
            }
        } else if cleaned.count >= 120 {
            if cleaned != lastSavedText {
                saveSentence(cleaned)
            }
        }
    }

    private func cleanText(_ text: String) -> String {
        var words = text.components(separatedBy: " ")
        words.removeAll { fillerWords.contains($0.lowercased()) }
        var result = words.joined(separator: " ")
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func checkSentenceSplit(_ text: String) -> String? {
        guard text.count > 5 else { return nil }
        let enders: Set<Character> = ["。", "！", "？", ".", "!", "?", "\n"]
        if let lastChar = text.last, enders.contains(lastChar) {
            return text
        }
        for ender in enders {
            if let range = text.range(of: String(ender), options: .backwards) {
                let beforeEnd = text.distance(from: text.startIndex, to: range.lowerBound)
                if beforeEnd >= 5 {
                    let firstPart = String(text[..<range.upperBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if firstPart.count >= 5 {
                        return firstPart
                    }
                }
            }
        }
        return nil
    }

    private func saveSentence(_ text: String) {
        let sentence = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty, sentence != lastSavedText else { return }

        let wordCount = sentence.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        let isCJK = sentence.unicodeScalars.contains { $0.value > 0x3000 }
        if (!isCJK && wordCount < 3 && sentence.count < 10) || (isCJK && sentence.count < 5) {
            logToFile("Filtered short: \"\(sentence.prefix(40))\"")
            currentText = ""
            return
        }

        lastSavedText = sentence
        logToFile("Sentence [Speaker \(currentSpeaker)]: \(sentence.prefix(120))")
        onSentenceComplete?(sentence, currentSpeaker)
        currentText = ""
    }

    func stop() {
        analyzeTask?.cancel()
        analyzeTask = nil
        resultTask?.cancel()
        resultTask = nil

        if let engine = audioEngine, let node = inputNode {
            node.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
        inputNode = nil
        converter = nil

        // Save last text
        if !currentText.isEmpty && currentText.count > 3 {
            saveSentence(currentText)
        }

        analyzer = nil
        transcriber = nil
        isRunning = false
        logToFile("Stopped")
    }

    func clearText() {
        currentText = ""
    }

    // No-op for compatibility — audio is captured internally now
    func feedAudioData(_ audioData: AudioData) {}
}