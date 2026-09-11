import Combine
import Foundation

@MainActor
final class CallTranscriptionService: ObservableObject {
    private struct SourceTranscription {
        let results: [(track: CapturedAudioTrack, result: TranscriptionResult)]
        let processingTime: TimeInterval
        let failures: [String]
    }

    typealias CaptureSessionFactory = @MainActor (AudioDevice.Device) -> any CallCaptureSessionProtocol
    typealias MicrophoneProvider = @MainActor () -> AudioDevice.Device?

    @Published private(set) var isRecording = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var status = ""
    @Published private(set) var lastResult: TranscriptionResult?

    private let asrService: ASRService
    private let transcriptionEngine: AudioFileTranscriptionEngine
    private let audioCaptureCoordinator: AudioCaptureCoordinator
    private let captureSessionFactory: CaptureSessionFactory
    private let microphoneProvider: MicrophoneProvider
    private var captureSession: (any CallCaptureSessionProtocol)?
    private var startedAt: Date?
    private var durationTask: Task<Void, Never>?
    private var pipelineWaiters: [CheckedContinuation<Void, Never>] = []
    private var isWaitingForDictation = false
    private var isTerminating = false

    init(
        asrService: ASRService,
        audioCaptureCoordinator: AudioCaptureCoordinator = .shared,
        captureSessionFactory: @escaping CaptureSessionFactory = { CallCaptureSession(microphoneDevice: $0) },
        microphoneProvider: @escaping MicrophoneProvider = {
            AppServices.shared.microphonePreferenceCoordinator.inputDeviceForCapture()
        }
    ) {
        self.asrService = asrService
        self.transcriptionEngine = AudioFileTranscriptionEngine(asrService: asrService)
        self.audioCaptureCoordinator = audioCaptureCoordinator
        self.captureSessionFactory = captureSessionFactory
        self.microphoneProvider = microphoneProvider
        self.lastResult = FileTranscriptionHistoryStore.shared.entries
            .first(where: { $0.kind == .call })?
            .toTranscriptionResult()
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
        guard let microphone = self.microphoneProvider() else {
            self.status = "Call capture failed"
            throw CallTranscriptionError.microphoneUnavailable
        }
        guard !self.asrService.isMicrophonePreviewRunningOrStarting else {
            self.status = "Call capture unavailable"
            throw CallTranscriptionError.audioCaptureInUse
        }
        guard self.audioCaptureCoordinator.reserve(for: .call) else {
            self.status = "Call capture unavailable"
            throw CallTranscriptionError.audioCaptureInUse
        }
        CallCaptureSession.removeOrphanedRecordings()

        self.isTranscribing = true
        defer { self.finishPipelineActivity() }
        self.status = "Starting call capture..."

        let session = self.captureSessionFactory(microphone)
        do {
            try await session.start()
            self.captureSession = session
            self.startedAt = Date()
            self.elapsedSeconds = 0
            self.audioCaptureCoordinator.setCallRecording(true)
            self.isRecording = true
            self.status = "Recording call"
            self.startDurationUpdates()
        } catch {
            self.audioCaptureCoordinator.release(for: .call)
            self.status = "Call capture failed"
            throw error
        }
    }

    func stopAndTranscribe() async throws {
        guard let session = self.captureSession, self.isRecording, !self.isTranscribing else {
            throw CallTranscriptionError.notRecording
        }

        self.stopDurationUpdates()
        self.audioCaptureCoordinator.setCallRecording(false)
        self.isRecording = false
        self.isTranscribing = true
        defer {
            self.audioCaptureCoordinator.release(for: .call)
            self.finishPipelineActivity()
        }
        self.captureSession = nil
        self.status = "Finalizing call audio..."

        let capturedAudio: CapturedCallAudio
        do {
            capturedAudio = try await session.stop()
        } catch {
            self.status = "Call capture failed"
            throw error
        }
        defer { capturedAudio.remove() }

        if self.asrService.isRunningOrStarting {
            self.status = "Waiting for dictation to finish..."
        }
        self.isWaitingForDictation = true
        await self.audioCaptureCoordinator.waitUntilReleased(.dictation)
        self.isWaitingForDictation = false
        guard !self.isTerminating else { return }

        AnalyticsService.shared.recordUsage(
            mode: .meeting,
            transcriptionModel: SettingsStore.shared.selectedSpeechModel.analyticsDescriptor
        )
        var recordingURL: URL?
        do {
            self.status = "Saving call recording..."
            async let savedRecording = CallRecordingStore.shared.save(capturedAudio)
            async let transcription = self.transcribeSources(capturedAudio)

            let savedRecordingURL = try await savedRecording
            recordingURL = savedRecordingURL
            let sourceTranscription = try await transcription
            let result = CallTranscriptAssembler.assemble(
                sourceTranscription.results,
                capturedAudio: capturedAudio,
                processingTime: sourceTranscription.processingTime,
                sourceFilePath: savedRecordingURL.path,
                sourceFailures: sourceTranscription.failures
            )
            guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CallTranscriptionError.noSpeechRecognized
            }
            self.lastResult = result
            FileTranscriptionHistoryStore.shared.addEntry(result)
            self.status = "Call transcript complete"
        } catch {
            CallRecordingStore.shared.deleteIfOwned(path: recordingURL?.path)
            self.status = "Call transcription failed"
            throw error
        }
    }

    func stopForTermination() async {
        self.isTerminating = true
        self.stopDurationUpdates()
        self.audioCaptureCoordinator.setCallRecording(false)

        // ASR shutdown releases active dictation and lets the pending call task unwind.
        guard !self.isWaitingForDictation else { return }

        while self.isTranscribing, self.captureSession == nil {
            await self.waitForPipelineActivity()
        }
        guard let session = self.captureSession else { return }

        self.captureSession = nil
        self.isRecording = false
        self.isTranscribing = true
        defer {
            self.audioCaptureCoordinator.release(for: .call)
            self.finishPipelineActivity()
        }
        if let capturedAudio = try? await session.stop() {
            capturedAudio.remove()
        }
    }

    private func transcribeSources(_ capturedAudio: CapturedCallAudio) async throws -> SourceTranscription {
        let startedAt = Date()
        var sourceResults: [(track: CapturedAudioTrack, result: TranscriptionResult)] = []
        var sourceFailures: [String] = []
        var lastError: Error?

        if !capturedAudio.tracks.contains(where: { $0.source == .system }) {
            sourceFailures.append("System audio was not captured.")
        }
        if !capturedAudio.tracks.contains(where: { $0.source == .microphone }) {
            sourceFailures.append("Microphone audio was not captured.")
        }

        for track in capturedAudio.tracks {
            let sourceName = track.source == .microphone ? "your microphone" : "other participants"
            self.status = "Transcribing \(sourceName)..."
            do {
                let expectedSpeakerCount = track.source == .microphone ? 1 : nil
                let result = try await self.transcriptionEngine.transcribeFile(
                    track.url,
                    options: AudioFileTranscriptionOptions(
                        speakerLabelsEnabled: true,
                        expectedSpeakerCount: expectedSpeakerCount
                    )
                )
                sourceResults.append((track, result))
            } catch {
                lastError = error
                sourceFailures.append("\(sourceName.capitalized) could not be transcribed.")
                DebugLogger.shared.warning(
                    "Call source transcription failed for \(sourceName): \(error.localizedDescription)",
                    source: "CallTranscriptionService"
                )
            }
        }

        guard !sourceResults.isEmpty else {
            throw lastError ?? CallTranscriptionError.noAudioCaptured
        }
        return SourceTranscription(
            results: sourceResults,
            processingTime: Date().timeIntervalSince(startedAt),
            failures: sourceFailures
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

    private func stopDurationUpdates() {
        self.durationTask?.cancel()
        self.durationTask = nil
        self.startedAt = nil
    }

    private func waitForPipelineActivity() async {
        await withCheckedContinuation { continuation in
            self.pipelineWaiters.append(continuation)
        }
    }

    private func finishPipelineActivity() {
        self.isTranscribing = false
        let waiters = self.pipelineWaiters
        self.pipelineWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
    }
}
