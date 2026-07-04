import Foundation

@MainActor
final class Translator: ObservableObject {
    @Published var isTranslating = false
    @Published var errorMessage: String?

    var apiKey: String = ""
    var baseURL: String = "https://api.openai.com/v1/chat/completions"
    var model: String = "gpt-4o-mini"

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        session = URLSession(configuration: config)
    }

    func logToFile(_ message: String) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("EchoMeet", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let logURL = dir.appendingPathComponent("debug.log")
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(ts)] [Translator] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(data); h.closeFile() }
            } else { try? data.write(to: logURL) }
        }
    }

    func translate(_ text: String) async -> String? {
        logToFile("translate called, apiKey length=\(apiKey.count), baseURL=\(baseURL), model=\(model)")
        guard !apiKey.isEmpty else {
            logToFile("ERROR: apiKey is empty")
            errorMessage = "未设置 API Key"
            return nil
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logToFile("text is empty, skipping")
            return nil
        }

        isTranslating = true
        defer { isTranslating = false }

        let requestBody: [String: Any] = [
            "model": model,
            "messages": [
                [
                    "role": "system",
                    "content": "You are a professional translator. Translate the following text to Chinese. Return only the translation, nothing else."
                ],
                [
                    "role": "user",
                    "content": text
                ]
            ],
            "temperature": 1
        ]

        // Ensure URL ends with /chat/completions
        var urlString = baseURL
        if !urlString.hasSuffix("/chat/completions") {
            if urlString.hasSuffix("/") { urlString.removeLast() }
            urlString += "/chat/completions"
        }
        logToFile("Final URL: \(urlString)")
        guard let url = URL(string: urlString) else {
            logToFile("ERROR: invalid URL \(urlString)")
            errorMessage = "无效的 Base URL"
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: requestBody)
        logToFile("Request prepared, sending...")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                logToFile("ERROR: invalid response")
                errorMessage = "无效响应"
                return nil
            }
            guard httpResponse.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                logToFile("ERROR: HTTP \(httpResponse.statusCode): \(body.prefix(200))")
                errorMessage = "API 错误 \(httpResponse.statusCode): \(body)"
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let message = firstChoice["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                logToFile("ERROR: cannot parse response")
                errorMessage = "无法解析响应"
                return nil
            }
            logToFile("Translation OK: \(content.prefix(60))")
            errorMessage = nil
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            logToFile("ERROR: request failed: \(error.localizedDescription)")
            errorMessage = "翻译请求失败: \(error.localizedDescription)"
            return nil
        }
    }
}