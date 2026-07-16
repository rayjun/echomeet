import SwiftUI

@main
@available(macOS 26.0, *)
struct EchoMeetApp: App {
    @StateObject private var captureManager = AudioCaptureManager()
    @StateObject private var speechRecognizer = SpeechRecognizerManager()
    @StateObject private var translator = Translator()
    @StateObject private var transcriptStore = TranscriptStore()

    var body: some Scene {
        WindowGroup {
            MainView(
                captureManager: captureManager,
                speechRecognizer: speechRecognizer,
                translator: translator,
                transcriptStore: transcriptStore
            )
        }
        .windowResizability(.contentMinSize)
    }
}