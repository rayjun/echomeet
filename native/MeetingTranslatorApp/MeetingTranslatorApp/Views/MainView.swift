import SwiftUI
import AppKit

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
            // Top toolbar
            HStack {
                Toggle("麦克风", isOn: $includeMic)
                    .disabled(captureManager.isCapturing)

                Toggle("翻译", isOn: $enableTranslation)
                    .disabled(captureManager.isCapturing)

                Spacer()

                if captureManager.isCapturing {
                    Button("停止") {
                        stopCapture()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    Button("开始记录") {
                        startCapture()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }

                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
            .padding(12)

            Divider()

            // Status bar
            HStack {
                if captureManager.isCapturing {
                    Label("录制中", systemImage: "circle.fill")
                        .foregroundColor(.red)
                        .font(.caption)
                }
                if let err = captureManager.errorMessage {
                    Text(err).foregroundColor(.red).font(.caption)
                }
                if let err = speechRecognizer.errorMessage {
                    Text(err).foregroundColor(.red).font(.caption)
                }
                Spacer()
                Text("\(transcriptStore.entries.count) 条记录 | \(captureManager.audioFrameCount) 音频帧")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            // Live transcript area
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if transcriptStore.entries.isEmpty && speechRecognizer.currentText.isEmpty {
                        Text("点击「开始记录」捕获系统音频和麦克风")
                            .foregroundColor(.secondary)
                            .padding()
                    }

                    // Current live text
                    if !speechRecognizer.currentText.isEmpty && captureManager.isCapturing {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("实时识别中...")
                                .font(.caption)
                                .foregroundColor(.blue)
                            Text(speechRecognizer.currentText)
                                .font(.body)
                                .padding(8)
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(8)
                        }
                    }

                    // Transcript entries — newest at top, oldest at bottom
                    ForEach(transcriptStore.entries.reversed()) { entry in
                        TranscriptEntryView(entry: entry)
                            .id(entry.id)
                    }
                }
                .padding()
            }

            Divider()

            // Bottom bar
            HStack {
                Button("清空") {
                    transcriptStore.clear()
                    speechRecognizer.clearText()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("导出 Markdown") {
                    saveMarkdown()
                }
                .buttonStyle(.bordered)
                .disabled(transcriptStore.entries.isEmpty)
            }
            .padding(12)
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

            // Load API settings from UserDefaults
            translator.apiKey = UserDefaults.standard.string(forKey: "apiKey") ?? ""
            translator.baseURL = UserDefaults.standard.string(forKey: "baseURL") ?? "https://api.openai.com/v1/chat/completions"
            translator.model = UserDefaults.standard.string(forKey: "model") ?? "gpt-4o-mini"

            let locale = Locale(identifier: UserDefaults.standard.string(forKey: "locale") ?? "en-US")
            speechRecognizer.start(locale: locale)

            // Set up real-time sentence translation
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

        // Save any remaining text
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
        VStack(alignment: .leading, spacing: 4) {
            Text(fmt.string(from: entry.timestamp))
                .font(.caption)
                .foregroundColor(.secondary)
            if !entry.chinese.isEmpty {
                Text(entry.chinese).font(.body)
            }
            Text(entry.original)
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .padding(10)
        .background(Color.gray.opacity(0.08))
        .cornerRadius(8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}