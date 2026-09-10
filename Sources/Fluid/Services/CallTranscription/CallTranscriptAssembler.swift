import Foundation

nonisolated enum CallTranscriptAssembler {
    static func assemble(
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
}
