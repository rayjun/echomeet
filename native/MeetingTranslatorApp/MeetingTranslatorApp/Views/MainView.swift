import SwiftUI
import AppKit

// MARK: - Accent Color
extension Color {
    static let echoBlue = Color(red: 0.25, green: 0.57, blue: 0.92)
    static let echoBlueDeep = Color(red: 0.20, green: 0.50, blue: 0.85)
    static let echoBlueLight = Color(red: 0.25, green: 0.57, blue: 0.92).opacity(0.10)
    static let echoBlueMedium = Color(red: 0.25, green: 0.57, blue: 0.92).opacity(0.20)
    static let echoSwitchOn = Color(red: 0.70, green: 0.85, blue: 1.0)
    static let echoStop = Color(red: 0.15, green: 0.30, blue: 0.50)
    static let echoRecording = Color(red: 0.90, green: 0.60, blue: 0.20)
}

extension LinearGradient {
    static let echoBlueGradient = LinearGradient(
        colors: [Color(red: 0.25, green: 0.57, blue: 0.92), Color(red: 0.20, green: 0.50, blue: 0.85)],
        startPoint: .leading,
        endPoint: .trailing
    )
}

struct MainView: View {
    @ObservedObject var captureManager: AudioCaptureManager
    @ObservedObject var speechRecognizer: SpeechRecognizerManager
    @ObservedObject var translator: Translator
    @ObservedObject var transcriptStore: TranscriptStore

    @State private var includeMic = true
    @State private var enableTranslation = false
    @State private var showSettings = false
    @State private var lastTranslatedText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header bar with blue gradient
            HStack(spacing: 16) {
                // App title
                HStack(spacing: 8) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                    Text("EchoMeet")
                        .font(.headline)
                        .foregroundColor(.white)
                }

                Spacer()

                // Toggles
                HStack(spacing: 16) {
                    Toggle("麦克风", isOn: $includeMic)
                        .disabled(captureManager.isCapturing)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(Color.echoSwitchOn)
                        .foregroundColor(.white)

                    Toggle("翻译", isOn: $enableTranslation)
                        .disabled(captureManager.isCapturing)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(Color.echoSwitchOn)
                        .foregroundColor(.white)
                }

                Divider()
                    .frame(height: 20)
                    .opacity(0.3)

                // Record / Stop button
                if captureManager.isCapturing {
                    Button {
                        stopCapture()
                    } label: {
                        Label("停止", systemImage: "stop.fill")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.echoStop)
                    .controlSize(.regular)
                } else {
                    Button {
                        startCapture()
                    } label: {
                        Label("开始", systemImage: "record.circle.fill")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.echoSwitchOn)
                    .foregroundColor(.echoBlueDeep)
                    .controlSize(.regular)
                }

                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.9))
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(LinearGradient.echoBlueGradient)

            // Status bar
            HStack(spacing: 8) {
                if captureManager.isCapturing {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color.echoRecording)
                            .frame(width: 7, height: 7)
                        Text("录制中")
                            .font(.caption)
                            .foregroundColor(.echoRecording)
                    }
                }
                if let err = captureManager.errorMessage {
                    Text(err).foregroundColor(.red).font(.caption)
                }
                if let err = speechRecognizer.errorMessage {
                    Text(err).foregroundColor(.red).font(.caption)
                }
                Spacer()
                Text("\(transcriptStore.entries.count) 条记录 · \(captureManager.audioFrameCount) 音频帧")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(Color.echoBlueLight)

            Divider()

            // Live transcript area
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if transcriptStore.entries.isEmpty && speechRecognizer.currentText.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "waveform.circle")
                                .font(.system(size: 48))
                                .foregroundColor(.echoBlue)
                                .opacity(0.5)
                            Text("点击「开始记录」捕获系统音频和麦克风")
                                .foregroundColor(.secondary)
                                .font(.callout)
                        }
                        .padding(.vertical, 80)
                        .frame(maxWidth: .infinity)
                    }

                    // Current live text
                    if !speechRecognizer.currentText.isEmpty && captureManager.isCapturing {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 5) {
                                Image(systemName: "dot.radiowaves.left.and.right")
                                    .font(.caption)
                                    .foregroundColor(.echoBlue)
                                Text("实时识别中")
                                    .font(.caption)
                                    .foregroundColor(.echoBlue)
                            }
                            Text(speechRecognizer.currentText)
                                .font(.body)
                                .padding(12)
                                .background(Color.echoBlueMedium)
                                .cornerRadius(10)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.echoBlue.opacity(0.3), lineWidth: 1)
                                )
                        }
                    }

                    // Transcript entries — newest at top
                    ForEach(transcriptStore.entries.reversed()) { entry in
                        TranscriptEntryView(entry: entry)
                            .id(entry.id)
                    }
                }
                .padding(20)
            }

            Divider()

            // Bottom bar
            HStack {
                Button {
                    transcriptStore.clear()
                    speechRecognizer.clearText()
                } label: {
                    Label("清空", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button {
                    saveMarkdown()
                } label: {
                    Label("导出 Markdown", systemImage: "square.and.arrow.down")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(.echoBlue)
                .controlSize(.small)
                .disabled(transcriptStore.entries.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 600, minHeight: 450)
        .tint(.echoBlue)
        .sheet(isPresented: $showSettings) {
            SettingsView(translator: translator, speechRecognizer: speechRecognizer)
        }
    }

    private func startCapture() {
        Task {
            let authorized = await speechRecognizer.requestAuthorization()
            guard authorized else { return }

            translator.apiKey = UserDefaults.standard.string(forKey: "apiKey") ?? ""
            translator.baseURL = UserDefaults.standard.string(forKey: "baseURL") ?? "https://api.openai.com/v1/chat/completions"
            translator.model = UserDefaults.standard.string(forKey: "model") ?? "gpt-4o-mini"

            let locale = Locale(identifier: UserDefaults.standard.string(forKey: "locale") ?? "en-US")
            speechRecognizer.start(locale: locale)

            speechRecognizer.onSentenceComplete = { sentence in
                Task {
                    if self.enableTranslation {
                        self.translator.logToFile("Translating: \(sentence.prefix(60))")
                        let chinese = await self.translator.translate(sentence) ?? ""
                        if chinese.isEmpty {
                            self.translator.logToFile("Translation returned empty")
                        }
                        self.transcriptStore.add(original: sentence, chinese: chinese)
                    } else {
                        self.transcriptStore.add(original: sentence, chinese: "")
                    }
                    self.lastTranslatedText = sentence
                }
            }

            captureManager.startCapture(includeMic: includeMic) { audioData in
                speechRecognizer.feedAudioData(audioData)
            }
        }
    }

    private func stopCapture() {
        captureManager.stopCapture()
        speechRecognizer.stop()

        let finalText = speechRecognizer.currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalText.isEmpty && finalText != lastTranslatedText {
            Task {
                if enableTranslation {
                    let chinese = await translator.translate(finalText) ?? ""
                    transcriptStore.add(original: finalText, chinese: chinese)
                } else {
                    transcriptStore.add(original: finalText, chinese: "")
                }
                lastTranslatedText = finalText
            }
        }
        speechRecognizer.clearText()
    }

    private func saveMarkdown() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "meeting-\(Int(Date().timeIntervalSince1970)).md"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? transcriptStore.exportMarkdown().write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

struct TranscriptEntryView: View {
    let entry: TranscriptEntry
    private let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "clock.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.echoBlue)
                Text(fmt.string(from: entry.timestamp))
                    .font(.caption)
                    .foregroundColor(.echoBlue)
                    .monospacedDigit()
            }
            if !entry.chinese.isEmpty {
                Text(entry.chinese)
                    .font(.body)
                    .foregroundColor(.primary)
            }
            Text(entry.original)
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .padding(14)
        .background(Color.echoBlueLight)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.echoBlue.opacity(0.15), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}