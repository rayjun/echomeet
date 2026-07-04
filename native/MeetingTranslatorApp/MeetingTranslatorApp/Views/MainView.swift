import SwiftUI
import AppKit

// MARK: - Accent Color
extension Color {
    static let echoBlue = Color(red: 0.35, green: 0.62, blue: 0.95)
    static let echoBlueLight = Color(red: 0.35, green: 0.62, blue: 0.95).opacity(0.12)
    static let echoBlueMedium = Color(red: 0.35, green: 0.62, blue: 0.95).opacity(0.25)
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
            // Native toolbar style
            HStack(spacing: 12) {
                Toggle("麦克风", isOn: $includeMic)
                    .disabled(captureManager.isCapturing)
                    .toggleStyle(.switch)
                    .controlSize(.small)

                Toggle("翻译", isOn: $enableTranslation)
                    .disabled(captureManager.isCapturing)
                    .toggleStyle(.switch)
                    .controlSize(.small)

                Spacer()

                if captureManager.isCapturing {
                    Button {
                        stopCapture()
                    } label: {
                        Label("停止", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
                } else {
                    Button {
                        startCapture()
                    } label: {
                        Label("开始记录", systemImage: "record.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.echoBlue)
                    .controlSize(.small)
                }

                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Status bar
            HStack(spacing: 8) {
                if captureManager.isCapturing {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.red)
                            .frame(width: 6, height: 6)
                            .opacity(0.8)
                        Text("录制中")
                            .font(.caption)
                            .foregroundColor(.red)
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
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            Divider()

            // Live transcript area
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if transcriptStore.entries.isEmpty && speechRecognizer.currentText.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "waveform.circle")
                                .font(.system(size: 40))
                                .foregroundColor(.echoBlue)
                                .opacity(0.6)
                            Text("点击「开始记录」捕获系统音频和麦克风")
                                .foregroundColor(.secondary)
                                .font(.callout)
                        }
                        .padding(.vertical, 60)
                        .frame(maxWidth: .infinity)
                    }

                    // Current live text
                    if !speechRecognizer.currentText.isEmpty && captureManager.isCapturing {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Image(systemName: "dot.radiowaves.left.and.right")
                                    .font(.caption)
                                    .foregroundColor(.echoBlue)
                                Text("实时识别中")
                                    .font(.caption)
                                    .foregroundColor(.echoBlue)
                            }
                            Text(speechRecognizer.currentText)
                                .font(.body)
                                .padding(10)
                                .background(Color.echoBlueLight)
                                .cornerRadius(8)
                        }
                    }

                    // Transcript entries — newest at top
                    ForEach(transcriptStore.entries.reversed()) { entry in
                        TranscriptEntryView(entry: entry)
                            .id(entry.id)
                    }
                }
                .padding(16)
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
                .controlSize(.small)
                .disabled(transcriptStore.entries.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 600, minHeight: 450)
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
        VStack(alignment: .leading, spacing: 5) {
            Text(fmt.string(from: entry.timestamp))
                .font(.caption)
                .foregroundColor(.secondary)
                .monospacedDigit()
            if !entry.chinese.isEmpty {
                Text(entry.chinese)
                    .font(.body)
                    .foregroundColor(.primary)
            }
            Text(entry.original)
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .background(Color.echoBlueLight)
        .cornerRadius(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}