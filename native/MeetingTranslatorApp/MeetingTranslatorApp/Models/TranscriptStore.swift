import Foundation

struct TranscriptEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let original: String
    let chinese: String
    let speaker: Int

    init(id: UUID = UUID(), timestamp: Date = Date(), original: String, chinese: String, speaker: Int = 1) {
        self.id = id
        self.timestamp = timestamp
        self.original = original
        self.chinese = chinese
        self.speaker = speaker
    }
}

@MainActor
final class TranscriptStore: ObservableObject {
    @Published var entries: [TranscriptEntry] = []

    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("EchoMeet", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        fileURL = appDir.appendingPathComponent("transcript.json")
        loadFromDisk()
    }

    func add(original: String, chinese: String, speaker: Int = 1) {
        let entry = TranscriptEntry(original: original, chinese: chinese, speaker: speaker)
        entries.append(entry)
        saveToDisk()
    }

    func replaceLast(original: String, chinese: String, speaker: Int = 1) {
        guard !entries.isEmpty else {
            add(original: original, chinese: chinese, speaker: speaker)
            return
        }
        let last = entries.last!
        entries[entries.count - 1] = TranscriptEntry(
            id: last.id,
            timestamp: last.timestamp,
            original: original,
            chinese: chinese,
            speaker: speaker
        )
        saveToDisk()
    }

    func clear() {
        entries.removeAll()
        saveToDisk()
    }

    private func saveToDisk() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(entries) {
            try? data.write(to: fileURL)
        }
    }

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? decoder.decode([TranscriptEntry].self, from: data) {
            entries = loaded
        }
    }

    func exportMarkdown() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines = ["# Meeting Transcript", ""]
        for entry in entries {
            lines.append("## \(formatter.string(from: entry.timestamp)) — Speaker \(entry.speaker)")
            lines.append("")
            lines.append("**中文:** \(entry.chinese)")
            lines.append("")
            lines.append("**Original:** \(entry.original)")
            lines.append("")
            lines.append("---")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}