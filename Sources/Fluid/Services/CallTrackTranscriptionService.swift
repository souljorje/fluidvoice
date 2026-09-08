import Foundation

/// Transcribes the two call tracks independently, then merges their timestamped speaker turns.
/// The microphone is known to be the local user, so diarization never has to rediscover "You".
@MainActor
final class CallTrackTranscriptionService {
    private let asrService: ASRService

    init(asrService: ASRService) {
        self.asrService = asrService
    }

    func transcribe(_ recording: CallRecording) async throws -> TranscriptionResult {
        let startedAt = Date()
        let anchor = [
            recording.systemStartOffsetSeconds,
            recording.microphoneStartOffsetSeconds,
        ]
        .compactMap { $0 }
        .min() ?? 0

        var trackResults: [TranscriptionResult] = []
        var segments: [SpeakerTranscriptSegment] = []
        var gaps: [SpeakerTranscriptGap] = []
        var notices: [String] = []

        if let microphoneURL = recording.microphoneAudioURL {
            let result = try await self.transcribeTemporaryTrack(
                microphoneURL,
                options: FileTranscriptionOptions(
                    speakerLabelsEnabled: true,
                    expectedSpeakerCount: 1
                )
            )
            trackResults.append(result)
            let shift = max(0, (recording.microphoneStartOffsetSeconds ?? anchor) - anchor)
            segments += Self.localSegments(from: result, shift: shift)
            gaps += Self.shiftedGaps(result.speakerLabelingGaps, by: shift)
            if let notice = result.speakerLabelingNotice {
                notices.append("Local track: \(notice)")
            }
        }

        if recording.systemAudioHasSignal, let systemURL = recording.systemAudioURL {
            let result = try await self.transcribeTemporaryTrack(
                systemURL,
                options: .call
            )
            trackResults.append(result)
            let shift = max(0, (recording.systemStartOffsetSeconds ?? anchor) - anchor)
            segments += Self.remoteSegments(from: result, shift: shift)
            gaps += Self.shiftedGaps(result.speakerLabelingGaps, by: shift)
            if let notice = result.speakerLabelingNotice {
                notices.append("Remote track: \(notice)")
            }
        } else if recording.systemAudioURL != nil {
            notices.append(
                "No system-audio signal was detected. If the remote side was speaking, check FluidVoice's System Audio Recording permission."
            )
        }

        segments.sort {
            if $0.startSeconds == $1.startSeconds {
                return $0.endSeconds < $1.endSeconds
            }
            return $0.startSeconds < $1.startSeconds
        }
        gaps.sort { $0.startSeconds < $1.startSeconds }

        guard !segments.isEmpty else {
            // Keep the existing Meeting Transcription pipeline as the final fallback for unusual
            // files where track-level diarization/transcription could not produce usable text.
            return try await MeetingTranscriptionService(asrService: self.asrService)
                .transcribeFile(recording.audioURL, options: .call)
        }

        let text = segments.map(\.plainText).joined(separator: "\n\n")
        let confidence = trackResults.isEmpty
            ? 0
            : trackResults.reduce(Float(0)) { $0 + $1.confidence } / Float(trackResults.count)
        let result = TranscriptionResult(
            text: text,
            confidence: confidence,
            duration: recording.duration,
            processingTime: Date().timeIntervalSince(startedAt),
            fileName: recording.audioURL.lastPathComponent,
            timestamp: recording.startedAt,
            speakerSegments: segments,
            speakerLabelingNotice: notices.isEmpty ? nil : notices.joined(separator: " "),
            speakerLabelingGaps: gaps
        )
        FileTranscriptionHistoryStore.shared.addEntry(result)
        return result
    }

    private func transcribeTemporaryTrack(
        _ url: URL,
        options: FileTranscriptionOptions
    ) async throws -> TranscriptionResult {
        let result = try await MeetingTranscriptionService(asrService: self.asrService)
            .transcribeFile(url, options: options)
        // MeetingTranscriptionService owns persistence for ordinary uploaded files. These track
        // results are implementation details; only the merged call should remain in history.
        FileTranscriptionHistoryStore.shared.deleteEntry(id: result.id)
        return result
    }

    private static func localSegments(
        from result: TranscriptionResult,
        shift: Double
    ) -> [SpeakerTranscriptSegment] {
        if !result.speakerSegments.isEmpty {
            return result.speakerSegments.map {
                SpeakerTranscriptSegment(
                    speaker: "You",
                    startSeconds: $0.startSeconds + shift,
                    endSeconds: $0.endSeconds + shift,
                    text: $0.text
                )
            }
        }
        return self.fallbackSegment(
            from: result,
            speaker: "You",
            shift: shift
        )
    }

    private static func remoteSegments(
        from result: TranscriptionResult,
        shift: Double
    ) -> [SpeakerTranscriptSegment] {
        if !result.speakerSegments.isEmpty {
            return result.speakerSegments.map {
                SpeakerTranscriptSegment(
                    speaker: $0.speaker,
                    startSeconds: $0.startSeconds + shift,
                    endSeconds: $0.endSeconds + shift,
                    text: $0.text
                )
            }
        }
        return self.fallbackSegment(
            from: result,
            speaker: "Speaker 1",
            shift: shift
        )
    }

    private static func fallbackSegment(
        from result: TranscriptionResult,
        speaker: String,
        shift: Double
    ) -> [SpeakerTranscriptSegment] {
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return [
            SpeakerTranscriptSegment(
                speaker: speaker,
                startSeconds: shift,
                endSeconds: shift + max(0, result.duration),
                text: text
            ),
        ]
    }

    private static func shiftedGaps(
        _ gaps: [SpeakerTranscriptGap],
        by shift: Double
    ) -> [SpeakerTranscriptGap] {
        gaps.map {
            SpeakerTranscriptGap(
                startSeconds: $0.startSeconds + shift,
                endSeconds: $0.endSeconds + shift
            )
        }
    }
}
