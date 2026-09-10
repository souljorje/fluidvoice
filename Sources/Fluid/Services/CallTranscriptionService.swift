import Combine
import Foundation

@MainActor
final class CallTranscriptionService: ObservableObject {
    typealias CaptureSessionFactory = @MainActor (AudioDevice.Device) -> any CallCaptureSessionProtocol
    typealias MicrophoneProvider = @MainActor () -> AudioDevice.Device?

    @Published private(set) var isRecording = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var status = ""
    @Published private(set) var lastResult: TranscriptionResult?

    private let asrService: ASRService
    private let fileTranscriptionService: MeetingTranscriptionService
    private let audioCaptureCoordinator: AudioCaptureCoordinator
    private let captureSessionFactory: CaptureSessionFactory
    private let microphoneProvider: MicrophoneProvider
    private var captureSession: (any CallCaptureSessionProtocol)?
    private var startedAt: Date?
    private var durationTask: Task<Void, Never>?
    private var pipelineWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        asrService: ASRService,
        audioCaptureCoordinator: AudioCaptureCoordinator = .shared,
        captureSessionFactory: @escaping CaptureSessionFactory = { CallCaptureSession(microphoneDevice: $0) },
        microphoneProvider: @escaping MicrophoneProvider = {
            AppServices.shared.microphonePreferenceCoordinator.inputDeviceForCapture()
        }
    ) {
        self.asrService = asrService
        self.fileTranscriptionService = MeetingTranscriptionService(asrService: asrService)
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

        self.status = "Transcribing call..."
        AnalyticsService.shared.recordUsage(
            mode: .meeting,
            transcriptionModel: SettingsStore.shared.selectedSpeechModel.analyticsDescriptor
        )
        do {
            let result = try await self.transcribe(capturedAudio)
            self.lastResult = result
            FileTranscriptionHistoryStore.shared.addEntry(result)
            self.status = "Call transcript complete"
        } catch {
            self.status = "Call transcription failed"
            throw error
        }
    }

    func stopForTermination() async {
        self.stopDurationUpdates()

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

    private func transcribe(_ capturedAudio: CapturedCallAudio) async throws -> TranscriptionResult {
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
                let result = try await self.fileTranscriptionService.transcribeFile(
                    track.url,
                    options: .callSource(expectedSpeakerCount: expectedSpeakerCount)
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
        let result = self.assembleResult(
            sourceResults,
            capturedAudio: capturedAudio,
            processingTime: Date().timeIntervalSince(startedAt),
            sourceFailures: sourceFailures
        )
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CallTranscriptionError.noSpeechRecognized
        }
        return result
    }

    private func assembleResult(
        _ sourceResults: [(track: CapturedAudioTrack, result: TranscriptionResult)],
        capturedAudio: CapturedCallAudio,
        processingTime: TimeInterval,
        sourceFailures: [String]
    ) -> TranscriptionResult {
        var segments: [SpeakerTranscriptSegment] = []
        var gaps: [SpeakerTranscriptGap] = []
        var notices = sourceFailures
        var weightedConfidence: Float = 0
        var confidenceWeight: Float = 0
        var remoteSpeakerLabels: [String: String] = [:]

        for sourceResult in sourceResults {
            let result = sourceResult.result
            let offset = capturedAudio.relativeStart(for: sourceResult.track)
            let weight = Float(max(1, result.duration))
            weightedConfidence += result.confidence * weight
            confidenceWeight += weight

            if let notice = result.speakerLabelingNotice {
                let source = sourceResult.track.source == .microphone ? "Microphone" : "System audio"
                notices.append("\(source): \(notice)")
            }
            gaps.append(contentsOf: result.speakerLabelingGaps.map {
                SpeakerTranscriptGap(
                    startSeconds: $0.startSeconds + offset,
                    endSeconds: $0.endSeconds + offset
                )
            })

            if result.speakerSegments.isEmpty {
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let speaker = sourceResult.track.source == .microphone ? "You" : "Speaker 1"
                segments.append(SpeakerTranscriptSegment(
                    speaker: speaker,
                    startSeconds: offset,
                    endSeconds: offset + result.duration,
                    text: text
                ))
                continue
            }

            for segment in result.speakerSegments {
                let speaker: String
                if sourceResult.track.source == .microphone {
                    speaker = "You"
                } else if let existing = remoteSpeakerLabels[segment.speaker] {
                    speaker = existing
                } else {
                    speaker = "Speaker \(remoteSpeakerLabels.count + 1)"
                    remoteSpeakerLabels[segment.speaker] = speaker
                }
                segments.append(SpeakerTranscriptSegment(
                    speaker: speaker,
                    startSeconds: segment.startSeconds + offset,
                    endSeconds: segment.endSeconds + offset,
                    text: segment.text
                ))
            }
        }

        segments.sort {
            if $0.startSeconds == $1.startSeconds {
                return $0.speaker < $1.speaker
            }
            return $0.startSeconds < $1.startSeconds
        }
        gaps.sort { $0.startSeconds < $1.startSeconds }
        let duration = sourceResults.map {
            capturedAudio.relativeStart(for: $0.track) + $0.result.duration
        }.max() ?? 0

        return TranscriptionResult(
            text: segments.map(\.plainText).joined(separator: "\n\n"),
            confidence: confidenceWeight > 0 ? weightedConfidence / confidenceWeight : 0,
            duration: duration,
            processingTime: processingTime,
            fileName: capturedAudio.fileName,
            kind: .call,
            speakerSegments: segments,
            speakerLabelingNotice: notices.isEmpty ? nil : notices.joined(separator: " "),
            speakerLabelingGaps: gaps
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
