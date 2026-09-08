import Combine
import Foundation

@MainActor
final class CallTranscriptionService: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var status = ""
    @Published private(set) var lastResult: TranscriptionResult?
    @Published private(set) var lastRecordingDirectory: URL?

    private let asrService: ASRService
    private var captureSession: CallCaptureSession?
    private var startedAt: Date?
    private var durationTask: Task<Void, Never>?

    init(asrService: ASRService) {
        self.asrService = asrService
    }

    var elapsedText: String {
        let total = Int(self.elapsedSeconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    func start() async throws {
        guard !self.isRecording, !self.isTranscribing else { return }

        self.status = "Starting call capture..."
        let session = CallCaptureSession()
        do {
            let directory = try await session.start()
            self.captureSession = session
            self.lastRecordingDirectory = directory
            self.startedAt = Date()
            self.elapsedSeconds = 0
            self.isRecording = true
            self.status = "Recording call"
            self.startDurationUpdates()
        } catch {
            self.status = "Call capture failed"
            throw error
        }
    }

    @discardableResult
    func stopAndTranscribe() async throws -> TranscriptionResult {
        guard let session = self.captureSession, self.isRecording else {
            throw CallTranscriptionError.notRecording
        }

        self.durationTask?.cancel()
        self.durationTask = nil
        self.isRecording = false
        self.status = "Finalizing call audio..."
        self.captureSession = nil

        let recording: CallRecording
        do {
            recording = try await session.stop()
            self.lastRecordingDirectory = recording.directoryURL
        } catch {
            self.status = "Call capture failed"
            throw error
        }

        self.isTranscribing = true
        defer { self.isTranscribing = false }

        let transcription = MeetingTranscriptionService(asrService: self.asrService)
        do {
            self.status = "Transcribing call..."
            let result = try await transcription.transcribeFile(
                recording.audioURL,
                options: .call
            )
            self.lastResult = result
            self.status = "Call transcript complete"
            return result
        } catch {
            self.status = "Call transcription failed"
            throw error
        }
    }

    func stopForTermination() async {
        self.durationTask?.cancel()
        self.durationTask = nil
        guard let session = self.captureSession else { return }
        self.captureSession = nil
        self.isRecording = false
        _ = try? await session.stop()
    }

    private func startDurationUpdates() {
        self.durationTask?.cancel()
        self.durationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, let startedAt = self.startedAt else { continue }
                self.elapsedSeconds = Date().timeIntervalSince(startedAt)
            }
        }
    }
}
