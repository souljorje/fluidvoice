import Foundation

/// Transcribes the two call tracks independently, then merges their timestamped speaker turns.
/// The microphone is authoritative for `You`; the system track is authoritative for remote voices.
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
        var remoteCallSegmentsForSuppression: [SpeakerTranscriptSegment] = []

        // Transcribe the remote/system side first. Its diarized speech intervals can then be used
        // to remove acoustic speaker leakage from the microphone before we label anything as You.
        if recording.systemAudioHasSignal, let systemURL = recording.systemAudioURL {
            let result = try await self.transcribeTemporaryTrack(
                systemURL,
                options: .call
            )
            trackResults.append(result)

            let shift = max(0, (recording.systemStartOffsetSeconds ?? anchor) - anchor)
            let remoteSegments = Self.remoteSegments(from: result, shift: shift)
            segments += remoteSegments
            gaps += Self.shiftedGaps(result.speakerLabelingGaps, by: shift)

            // Only real diarized intervals are safe for leakage suppression. A standard-transcript
            // fallback is represented as one full-file segment and must not mute the whole mic.
            if !result.speakerSegments.isEmpty {
                remoteCallSegmentsForSuppression = result.speakerSegments.map {
                    SpeakerTranscriptSegment(
                        speaker: $0.speaker,
                        startSeconds: $0.startSeconds + shift,
                        endSeconds: $0.endSeconds + shift,
                        text: $0.text
                    )
                }
            } else {
                DebugLogger.shared.info(
                    "Remote diarization produced no timed segments; microphone leakage suppression skipped",
                    source: "CallTrackTranscriptionService"
                )
            }

            if let notice = result.speakerLabelingNotice {
                notices.append("Remote track: \(notice)")
            }
        } else if recording.systemAudioURL != nil {
            notices.append(
                "No system-audio signal was detected. If the remote side was speaking, check FluidVoice's System Audio Recording permission."
            )
        }

        if let microphoneURL = recording.microphoneAudioURL {
            let shift = max(0, (recording.microphoneStartOffsetSeconds ?? anchor) - anchor)
            var localInputURL = microphoneURL
            var isolatedLocalTrack: CallMicrophoneLeakageSuppressor.Result?

            if !remoteCallSegmentsForSuppression.isEmpty {
                do {
                    isolatedLocalTrack = try await CallMicrophoneLeakageSuppressor.makeLocalOnlyTrack(
                        microphoneURL: microphoneURL,
                        microphoneShiftSeconds: shift,
                        remoteCallSegments: remoteCallSegmentsForSuppression,
                        outputDirectory: recording.directoryURL
                    )
                    if let isolatedLocalTrack {
                        localInputURL = isolatedLocalTrack.url
                        DebugLogger.shared.info(
                            "Suppressed \(isolatedLocalTrack.mutedRangeCount) remote-speech ranges from microphone attribution",
                            source: "CallTrackTranscriptionService"
                        )
                    }
                } catch {
                    // Speaker isolation improves attribution, but must never make an otherwise
                    // transcribable call fail. Fall back to the untouched microphone track.
                    DebugLogger.shared.warning(
                        "Microphone leakage suppression failed: \(error.localizedDescription)",
                        source: "CallTrackTranscriptionService"
                    )
                }
            }

            let result: TranscriptionResult
            if let isolatedLocalTrack {
                defer { try? FileManager.default.removeItem(at: isolatedLocalTrack.url) }
                result = try await self.transcribeTemporaryTrack(
                    localInputURL,
                    options: FileTranscriptionOptions(
                        // The diarizer is used only to obtain timestamped speech turns here.
                        // Identity comes from the microphone source itself, never clustering.
                        speakerLabelsEnabled: true,
                        expectedSpeakerCount: 1
                    )
                )
                notices.append(
                    "Local attribution excludes periods where remote speech was active, preventing speaker playback from being mislabeled as You."
                )
            } else {
                result = try await self.transcribeTemporaryTrack(
                    localInputURL,
                    options: FileTranscriptionOptions(
                        speakerLabelsEnabled: true,
                        expectedSpeakerCount: 1
                    )
                )
            }

            trackResults.append(result)
            segments += Self.localSegments(from: result, shift: shift)
            gaps += Self.shiftedGaps(result.speakerLabelingGaps, by: shift)
            if let notice = result.speakerLabelingNotice {
                notices.append("Local track: \(notice)")
            }
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
