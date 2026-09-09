import Combine
import Foundation

@MainActor
final class CallTranscriptionService: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isBusy = false
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var status = ""

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
        guard !self.isRecording, !self.isBusy else { return }
        guard let microphone = AppServices.shared
            .microphonePreferenceCoordinator
            .inputDeviceForCapture()
        else {
            self.status = "Call capture failed"
            throw CallTranscriptionError.microphoneUnavailable
        }

        self.isBusy = true
        defer { self.isBusy = false }
        self.status = "Starting call capture..."

        let session = CallCaptureSession(microphoneDevice: microphone)
        do {
            try await session.start()
            self.captureSession = session
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

    func stopAndTranscribe() async throws {
        guard let session = self.captureSession, self.isRecording, !self.isBusy else {
            throw CallTranscriptionError.notRecording
        }

        self.stopDurationUpdates()
        self.isRecording = false
        self.isBusy = true
        defer { self.isBusy = false }
        self.captureSession = nil
        self.status = "Finalizing call audio..."

        let audioURL: URL
        do {
            audioURL = try await session.stop()
        } catch {
            self.status = "Call capture failed"
            throw error
        }

        self.status = "Transcribing call..."
        do {
            _ = try await MeetingTranscriptionService(asrService: self.asrService)
                .transcribeFile(audioURL, options: .call)
            self.status = "Call transcript complete"
        } catch {
            self.status = "Call transcription failed"
            throw error
        }
    }

    func stopForTermination() async {
        self.stopDurationUpdates()
        guard let session = self.captureSession else { return }
        self.captureSession = nil
        self.isRecording = false
        self.isBusy = true
        defer { self.isBusy = false }
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

    private func stopDurationUpdates() {
        self.durationTask?.cancel()
        self.durationTask = nil
        self.startedAt = nil
    }
}
