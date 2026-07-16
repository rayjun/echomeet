import Foundation
import Speech
import AVFoundation

@MainActor
final class SpeechRecognizerManager: ObservableObject {
    @Published var currentText: String = ""
    @Published var isRunning = false
    @Published var errorMessage: String?
    @Published var currentSpeaker: Int = 1

    var onSentenceComplete: ((String, Int) -> Void)?

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private var pendingPcmChunks: [Int16] = []
    private var currentSampleRate: Int = 48000
    private var chunkTimer: Timer?
    private var lastSpeechTime: Date = .distantPast
    private var restartDelay: Date = .distantPast
    private var restartCount = 0
    private var restartBackoff: Double = 0.3
    private var lastSavedText: String = ""

    private var lastTextChangeTime: Date = .distantPast
    private var lastTextContent: String = ""
    private var consecutiveSilenceChunks: Int = 0
    private var isSilenceFinalizing: Bool = false

    private let silenceThreshold: Float = 0.006
    private let silenceDurationToFinalize: Double = 1.8
    private let textStallDurationToFinalize: Double = 2.0
    private let maxSentenceLength: Int = 80
    private let minMeaningfulWords: Int = 2

    private let sentenceEnders: CharacterSet = {
        var cs = CharacterSet(charactersIn: "。！？.!?\n\r；;")
        cs.insert(charactersIn: "\u{3002}\u{FF01}\u{FF1F}\u{FF0C}")
        return cs
    }()

    private let fillerWords: Set<String> = [
        "um", "uh", "er", "ah", "hmm", "mm", "uh-huh", "uh-huh",
        "嗯", "啊", "呃", "哎", "那个", "这个", "就是", "然后",
        "对吧", "的话", "一下", "其实", "基本上",
    ]

    private func logToFile(_ message: String) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("EchoMeet", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let logURL = dir.appendingPathComponent("debug.log")
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(ts)] [Speech] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(data); h.closeFile() }
            } else { try? data.write(to: logURL) }
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

    func feedAudioData(_ audioData: AudioData) {
        guard isRunning else { return }
        currentSampleRate = audioData.sampleRate
        pendingPcmChunks.append(contentsOf: audioData.samples)
        let flushThreshold = Int(Double(audioData.sampleRate) * 0.1)
        if pendingPcmChunks.count >= flushThreshold {
            flushPendingChunks()
        }
    }

    private func computeRMS(_ samples: [Int16]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumSq: Float = 0
        for s in samples {
            let f = Float32(s) / Float32(Int16.max)
            sumSq += f * f
        }
        return sqrt(sumSq / Float(samples.count))
    }

    private func flushPendingChunks() {
        guard !pendingPcmChunks.isEmpty else { return }
        let chunks = pendingPcmChunks
        pendingPcmChunks.removeAll()

        guard let recognitionRequest = recognitionRequest else { return }

        let sampleRate = currentSampleRate
        let samples = chunks
        let frameCount = samples.count
        guard frameCount > 0 else { return }

        let rawRms = computeRMS(samples)
        let now = Date()

        if rawRms > silenceThreshold {
            lastSpeechTime = now
            consecutiveSilenceChunks = 0
        } else {
            consecutiveSilenceChunks += 1
        }

        let inHangover = now.timeIntervalSince(lastSpeechTime) < 0.4
        if rawRms < silenceThreshold * 0.4 && !inHangover {
            return
        }

        let targetRms: Float = 0.06
        let gain = min(30.0, max(1.0, targetRms / max(rawRms, 0.001)))

        let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        if let floatData = buffer.floatChannelData?[0] {
            for (i, sample) in samples.enumerated() {
                var f = Float32(sample) / Float32(Int16.max)
                f *= gain
                f = max(-1.0, min(1.0, f))
                floatData[i] = f
            }
        }

        recognitionRequest.append(buffer)
    }

    func start(locale: Locale = Locale(identifier: "en-US")) {
        stop()
        logToFile("Starting for locale: \(locale.identifier)")
        speechRecognizer = SFSpeechRecognizer(locale: locale)
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            logToFile("Not available")
            errorMessage = "语音识别器不可用"
            return
        }

        currentSpeaker = 1
        startNewRecognitionTask(recognizer: recognizer)

        isRunning = true
        errorMessage = nil
        logToFile("Started, isRunning=true")

        chunkTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.isRunning else { return }
                self.flushPendingChunks()
                self.checkSilenceFinalization()

                if self.recognitionTask == nil {
                    let elapsed = Date().timeIntervalSince(self.restartDelay)
                    if elapsed > self.restartBackoff {
                        if let r = self.speechRecognizer, r.isAvailable {
                            self.restartCount += 1
                            self.restartBackoff = min(3.0, 0.3 * pow(2.0, Double(self.restartCount)))
                            self.logToFile("Timer restart (count=\(self.restartCount), backoff=\(self.restartBackoff)s)")
                            self.startNewRecognitionTask(recognizer: r)
                        }
                    }
                }
            }
        }
    }

    private func checkSilenceFinalization() {
        guard isRunning, !currentText.isEmpty, !isSilenceFinalizing else { return }

        let now = Date()
        let silenceSince = now.timeIntervalSince(lastSpeechTime)
        let textStallSince = now.timeIntervalSince(lastTextChangeTime)

        let hasRealSpeech = lastSpeechTime != .distantPast
        let longSilence = hasRealSpeech && silenceSince > silenceDurationToFinalize
        let textStalled = textStallSince > textStallDurationToFinalize && currentText == lastTextContent

        if longSilence || textStalled {
            logToFile("Finalizing: silenceSince=\(String(format: "%.1f", silenceSince))s, textStall=\(String(format: "%.1f", textStallSince))s")
            let silenceGap = silenceSince
            finalizeCurrentSentence(silenceGap: silenceGap)
        }
    }

    private func startNewRecognitionTask(recognizer: SFSpeechRecognizer) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false
        request.taskHint = .dictation
        recognitionRequest = request
        isSilenceFinalizing = false
        lastSavedText = ""
        lastTextContent = ""
        lastTextChangeTime = Date()
        restartDelay = Date()

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self = self else { return }

                if let result = result {
                    let rawText = result.bestTranscription.formattedString
                    let cleaned = self.cleanText(rawText)

                    if cleaned != self.lastTextContent {
                        self.lastTextContent = cleaned
                        self.lastTextChangeTime = Date()
                    }

                    self.currentText = cleaned
                    self.restartCount = 0
                    self.restartBackoff = 0.3

                    if let splitSentence = self.checkSentenceSplit(cleaned) {
                        self.saveSentence(splitSentence)
                        return
                    }

                    if cleaned.count >= self.maxSentenceLength && !cleaned.isEmpty {
                        self.saveSentence(cleaned)
                        return
                    }

                    if result.isFinal && !cleaned.isEmpty && cleaned.count > 3 {
                        self.saveSentence(cleaned)
                    } else if result.isFinal {
                        self.recognitionTask = nil
                        self.recognitionRequest = nil
                        self.restartDelay = Date()
                    }
                }

                if let error = error {
                    let code = (error as NSError).code
                    if code != 203 && code != 1110 && code != 216 && code != 301 {
                        self.logToFile("Error: \(error.localizedDescription) code=\(code)")
                    }
                    self.recognitionTask = nil
                    self.recognitionRequest = nil
                    self.restartDelay = Date()
                }
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

        let unwanted: Set<Character> = ["\u{FF0C}", "\u{3001}"]
        if result.count <= 4 && result.allSatisfy({ unwanted.contains($0) || $0.isWhitespace }) {
            return ""
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

    private func finalizeCurrentSentence(silenceGap: Double) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != lastSavedText else {
            currentText = ""
            return
        }

        if silenceGap > 3.0 {
            currentSpeaker = currentSpeaker == 1 ? 2 : 1
            logToFile("Speaker switched to #\(currentSpeaker) (gap=\(String(format: "%.1f", silenceGap))s)")
        }

        isSilenceFinalizing = true
        saveSentence(text)
    }

    private func saveSentence(_ text: String) {
        let sentence = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty, sentence != lastSavedText else { return }

        let wordCount = sentence.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        let isCJK = sentence.unicodeScalars.contains { $0.value > 0x3000 }
        let tooShort = !isCJK && wordCount < minMeaningfulWords && sentence.count < 8
        let cjkTooShort = isCJK && sentence.count < 4

        if tooShort || cjkTooShort {
            logToFile("Filtered short: \"\(sentence.prefix(40))\" (\(wordCount) words, \(sentence.count) chars)")
            currentText = ""
            recognitionTask?.cancel()
            recognitionTask = nil
            recognitionRequest?.endAudio()
            recognitionRequest = nil
            restartCount = 0
            restartBackoff = 0.3
            restartDelay = Date()
            return
        }

        lastSavedText = sentence
        logToFile("Sentence [Speaker \(currentSpeaker)]: \(sentence.prefix(120))")
        onSentenceComplete?(sentence, currentSpeaker)
        currentText = ""

        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        restartCount = 0
        restartBackoff = 0.3
        restartDelay = Date()
    }

    func stop() {
        chunkTimer?.invalidate()
        chunkTimer = nil
        if !currentText.isEmpty && currentText.count > 3 {
            saveSentence(currentText)
        }
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        isRunning = false
    }

    func clearText() {
        currentText = ""
    }
}