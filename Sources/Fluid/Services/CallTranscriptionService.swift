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
    private var voiceProcessedMicrophoneCapture: CallVoiceProcessedMicrophoneCapture?
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
        guard let microphone = AppServices.shared
            .microphonePreferenceCoordinator
            .inputDeviceForCapture()
        else {
            self.status = "Call capture failed"
            throw CallTranscriptionError.microphoneUnavailable
        }

        self.status = "Starting call capture..."
        let session = CallCaptureSession(microphoneDevice: microphone)
        do {
            let directory = try await session.start()
            self.captureSession = session
            self.lastRecordingDirectory = directory

            // Run Apple's VoiceProcessingIO path in parallel with the existing raw microphone
            // capture. This is deliberately an A/B prototype: microphone.m4a remains the raw mic,
            // while microphone-voice-processing.wav is Apple's processed version and becomes the
            // local transcription source only when the prototype starts and captures signal.
            let voiceProcessedCapture = CallVoiceProcessedMicrophoneCapture(
                microphoneDevice: microphone,
                outputURL: directory.appendingPathComponent("microphone-voice-processing.wav")
            )
            do {
                try voiceProcessedCapture.start()
                self.voiceProcessedMicrophoneCapture = voiceProcessedCapture
            } catch {
                self.voiceProcessedMicrophoneCapture = nil
                DebugLogger.shared.info(
                    "Apple voice-processing prototype unavailable; keeping raw microphone path: \(error.localizedDescription)",
                    source: "CallTranscriptionService"
                )
            }

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

        let voiceProcessedTrack = self.stopVoiceProcessedMicrophoneCapture()

        let rawRecording: CallRecording
        do {
            rawRecording = try await session.stop()
            self.lastRecordingDirectory = rawRecording.directoryURL
        } catch {
            self.status = "Call capture failed"
            throw error
        }

        let recording = Self.recordingUsingVoiceProcessedMicrophoneIfAvailable(
            rawRecording,
            voiceProcessedTrack: voiceProcessedTrack
        )

        self.isTranscribing = true
        defer { self.isTranscribing = false }

        let transcription = CallTrackTranscriptionService(asrService: self.asrService)
        do {
            self.status = "Transcribing call speakers..."
            let result = try await transcription.transcribe(recording)
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
        _ = self.stopVoiceProcessedMicrophoneCapture()
        guard let session = self.captureSession else { return }
        self.captureSession = nil
        self.isRecording = false
        _ = try? await session.stop()
    }

    private func stopVoiceProcessedMicrophoneCapture() -> CallVoiceProcessedMicrophoneCapture.Track? {
        guard let capture = self.voiceProcessedMicrophoneCapture else { return nil }
        self.voiceProcessedMicrophoneCapture = nil
        do {
            let track = try capture.stop()
            guard track.hasSignal else {
                DebugLogger.shared.info(
                    "Apple voice-processing prototype captured no meaningful signal; using raw microphone track",
                    source: "CallTranscriptionService"
                )
                return nil
            }
            return track
        } catch {
            DebugLogger.shared.warning(
                "Apple voice-processing prototype failed; using raw microphone track: \(error.localizedDescription)",
                source: "CallTranscriptionService"
            )
            return nil
        }
    }

    private static func recordingUsingVoiceProcessedMicrophoneIfAvailable(
        _ recording: CallRecording,
        voiceProcessedTrack: CallVoiceProcessedMicrophoneCapture.Track?
    ) -> CallRecording {
        guard let voiceProcessedTrack else { return recording }

        let captureStartOffset = max(
            0,
            voiceProcessedTrack.startedAt.timeIntervalSince(recording.startedAt)
        )
        let firstAudioOffset = captureStartOffset + voiceProcessedTrack.firstAudioOffsetSeconds

        DebugLogger.shared.info(
            "Using Apple voice-processed microphone for local call attribution [offset=\(String(format: "%.3f", firstAudioOffset))s]; raw microphone.m4a preserved for A/B comparison",
            source: "CallTranscriptionService"
        )

        return CallRecording(
            directoryURL: recording.directoryURL,
            audioURL: recording.audioURL,
            systemAudioURL: recording.systemAudioURL,
            microphoneAudioURL: voiceProcessedTrack.url,
            systemStartOffsetSeconds: recording.systemStartOffsetSeconds,
            microphoneStartOffsetSeconds: firstAudioOffset,
            systemAudioHasSignal: recording.systemAudioHasSignal,
            startedAt: recording.startedAt,
            duration: recording.duration
        )
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
