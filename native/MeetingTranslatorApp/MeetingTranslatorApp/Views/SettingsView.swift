import SwiftUI

struct SettingsView: View {
    @ObservedObject var translator: Translator
    @ObservedObject var speechRecognizer: SpeechRecognizerManager

    @State private var apiKeyInput: String = ""
    @State private var baseURLInput: String = ""
    @State private var modelInput: String = ""
    @State private var selectedLocale: String = "en-US"

    let locales = [
        ("en-US", "English (US)"),
        ("en-GB", "English (UK)"),
        ("zh-CN", "中文 (简体)"),
        ("ja-JP", "日本語"),
        ("ko-KR", "한국어"),
        ("fr-FR", "Français"),
        ("de-DE", "Deutsch"),
        ("es-ES", "Español"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("设置")
                    .font(.headline)
                Spacer()
                Button {
                    NSApp.keyWindow?.close()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            Form {
                Section("语音识别") {
                    Picker("识别语言", selection: $selectedLocale) {
                        ForEach(locales, id: \.0) { code, name in
                            Text(name).tag(code)
                        }
                    }
                    if let err = speechRecognizer.errorMessage {
                        Text(err).foregroundColor(.red).font(.caption)
                    }
                }

                Section("翻译 API") {
                    SecureField("API Key", text: $apiKeyInput)
                    TextField("Base URL", text: $baseURLInput)
                        .textFieldStyle(.roundedBorder)
                    TextField("Model", text: $modelInput)
                        .textFieldStyle(.roundedBorder)
                    if let err = translator.errorMessage {
                        Text(err).foregroundColor(.red).font(.caption)
                    }
                }

                Section {
                    Button {
                        translator.apiKey = apiKeyInput
                        translator.baseURL = baseURLInput.isEmpty ? "https://api.openai.com/v1/chat/completions" : baseURLInput
                        translator.model = modelInput.isEmpty ? "gpt-4o-mini" : modelInput
                        UserDefaults.standard.set(apiKeyInput, forKey: "apiKey")
                        UserDefaults.standard.set(translator.baseURL, forKey: "baseURL")
                        UserDefaults.standard.set(translator.model, forKey: "model")
                        UserDefaults.standard.set(selectedLocale, forKey: "locale")
                    } label: {
                        Label("保存设置", systemImage: "checkmark.circle.fill")
                    }
                    .tint(.echoBlue)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 500, height: 400)
        .onAppear {
            apiKeyInput = UserDefaults.standard.string(forKey: "apiKey") ?? ""
            baseURLInput = UserDefaults.standard.string(forKey: "baseURL") ?? "https://api.openai.com/v1/chat/completions"
            modelInput = UserDefaults.standard.string(forKey: "model") ?? "gpt-4o-mini"
            selectedLocale = UserDefaults.standard.string(forKey: "locale") ?? "en-US"
            translator.apiKey = apiKeyInput
            translator.baseURL = baseURLInput
            translator.model = modelInput
        }
    }
}