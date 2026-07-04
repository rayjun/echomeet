import Foundation
import Speech
import AVFoundation

@MainActor
final class SpeechRecognizerManager: ObservableObject {
    @Published var currentText: String = ""
    @Published var isRunning = false
    @Published var errorMessage: String?

    var onSentenceComplete: ((String) -> Void)?

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private var pendingPcmChunks: [Int16] = []
    private var currentSampleRate: Int = 48000
    private var chunkTimer: Timer?
    private var lastSpeechTime: Date = .distantPast
    private var restartDelay: Date = .distantPast
    private var isRestarting = false
    private var restartCount = 0
    private var restartBackoff: Double = 0.3
    private var lastSavedText: String = ""

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

    private func flushPendingChunks() {
        guard !pendingPcmChunks.isEmpty else { return }
        let chunks = pendingPcmChunks
        pendingPcmChunks.removeAll()

        guard let recognitionRequest = recognitionRequest else { return }

        let sampleRate = currentSampleRate
        let samples = chunks
        let frameCount = samples.count
        guard frameCount > 0 else { return }

        // Compute raw RMS
        var rawSumSq: Float = 0
        for sample in samples {
            let f = Float32(sample) / Float32(Int16.max)
            rawSumSq += f * f
        }
        let rawRms = sqrt(rawSumSq / Float(frameCount))

        // VAD: skip near-silent frames
        let now = Date()
        let inHangover = now.timeIntervalSince(lastSpeechTime) < 0.5
        if rawRms < 0.0003 && !inHangover {
            return
        }
        if rawRms > 0.001 {
            lastSpeechTime = now
        }

        // Adaptive gain
        let targetRms: Float = 0.08
        let gain = min(50.0, max(1.0, targetRms / max(rawRms, 0.0001)))

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

        startNewRecognitionTask(recognizer: recognizer)

        isRunning = true
        errorMessage = nil
        logToFile("Started, isRunning=true")

        chunkTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.isRunning else { return }
                self.flushPendingChunks()
                // Auto-restart if task ended
                if self.recognitionTask == nil {
                    let elapsed = Date().timeIntervalSince(self.restartDelay)
                    if elapsed > Double(self.restartBackoff) {
                        if let r = self.speechRecognizer, r.isAvailable {
                            self.restartCount += 1
                            // Exponential backoff: 0.3s, 0.6s, 1.2s, 2.4s... max 5s
                            self.restartBackoff = min(5.0, 0.3 * pow(2.0, Double(self.restartCount)))
                            self.logToFile("Timer restart (count=\(self.restartCount), backoff=\(self.restartBackoff)s)")
                            self.startNewRecognitionTask(recognizer: r)
                        }
                    }
                }
            }
        }
    }

    private func startNewRecognitionTask(recognizer: SFSpeechRecognizer) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false
        request.taskHint = .dictation
        recognitionRequest = request
        isRestarting = false
        lastSavedText = ""
        restartDelay = Date()

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self = self else { return }
                
                if let result = result {
                    let text = result.bestTranscription.formattedString
                    self.currentText = text
                    self.restartCount = 0
                    self.restartBackoff = 0.3

                    // Segment by length (120 chars) or by pause (2s no change)
                    let shouldSaveByLength = text.count >= 120
                    
                    // Check for pause
                    var shouldSaveByPause = false
                    if text == self.currentText && !text.isEmpty && text.count > 10 {
                        // text didn't change since last callback — check time
                        // We use isFinal as the main pause detector
                    }

                    if shouldSaveByLength && !text.isEmpty {
                        self.saveSentence(text)
                        return  // saveSentence will restart
                    }

                    if result.isFinal && !text.isEmpty && text.count > 3 {
                        self.saveSentence(text)
                    } else if result.isFinal {
                        // isFinal with no text — task ended, let chunkTimer restart
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
                    // Mark task as ended so chunkTimer can restart
                    self.recognitionTask = nil
                    self.recognitionRequest = nil
                    self.restartDelay = Date()
                }
            }
        }
    }

    private func saveSentence(_ text: String) {
        let sentence = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty, sentence != lastSavedText else { return }
        lastSavedText = sentence
        logToFile("Sentence: \(sentence.prefix(120))")
        onSentenceComplete?(sentence)
        currentText = ""
        
        // Just cancel current task — let chunkTimer restart
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        
        // Reset backoff so timer can restart quickly
        restartCount = 0
        restartBackoff = 0.3
        restartDelay = Date()
    }

    func stop() {
        chunkTimer?.invalidate()
        chunkTimer = nil
        // Save last text
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