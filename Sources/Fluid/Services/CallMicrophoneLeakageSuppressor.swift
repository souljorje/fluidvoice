import AVFoundation
import Foundation

/// Produces a temporary microphone track with known remote-speech intervals muted.
///
/// The system-audio track is authoritative for the remote side of a call. When the same remote
/// speech leaks acoustically through speakers into the microphone, muting those intervals keeps it
/// from being mislabeled as `You`. The tradeoff is intentionally conservative: local speech that
/// overlaps remote speech is not attributed to `You` unless we can distinguish it reliably later.
nonisolated enum CallMicrophoneLeakageSuppressor {
    struct Result: Sendable {
        let url: URL
        let mutedRangeCount: Int
    }

    private struct TimeRange: Sendable {
        let startSeconds: Double
        let endSeconds: Double
    }

    private static let paddingSeconds: Double = 0.12
    private static let framesPerChunk: AVAudioFrameCount = 8192

    static func makeLocalOnlyTrack(
        microphoneURL: URL,
        microphoneShiftSeconds: Double,
        remoteCallSegments: [SpeakerTranscriptSegment],
        outputDirectory: URL
    ) async throws -> Result? {
        let ranges = self.muteRanges(
            remoteCallSegments: remoteCallSegments,
            microphoneShiftSeconds: microphoneShiftSeconds
        )
        guard !ranges.isEmpty else { return nil }

        let outputURL = outputDirectory.appendingPathComponent("microphone-local-only.wav")
        return try await Task.detached(priority: .userInitiated) {
            try self.writeMutedCopy(
                inputURL: microphoneURL,
                outputURL: outputURL,
                ranges: ranges
            )
        }.value
    }

    private static func muteRanges(
        remoteCallSegments: [SpeakerTranscriptSegment],
        microphoneShiftSeconds: Double
    ) -> [TimeRange] {
        let ranges = remoteCallSegments.compactMap { segment -> TimeRange? in
            let start = segment.startSeconds - microphoneShiftSeconds - self.paddingSeconds
            let end = segment.endSeconds - microphoneShiftSeconds + self.paddingSeconds
            guard end > 0, end > start else { return nil }
            return TimeRange(
                startSeconds: max(0, start),
                endSeconds: end
            )
        }
        .sorted { $0.startSeconds < $1.startSeconds }

        guard var current = ranges.first else { return [] }
        var merged: [TimeRange] = []

        for range in ranges.dropFirst() {
            if range.startSeconds <= current.endSeconds {
                current = TimeRange(
                    startSeconds: current.startSeconds,
                    endSeconds: max(current.endSeconds, range.endSeconds)
                )
            } else {
                merged.append(current)
                current = range
            }
        }
        merged.append(current)
        return merged
    }

    private static func writeMutedCopy(
        inputURL: URL,
        outputURL: URL,
        ranges: [TimeRange]
    ) throws -> Result {
        let input = try AVAudioFile(forReading: inputURL)
        let format = input.processingFormat
        guard format.sampleRate > 0,
              format.channelCount > 0,
              format.commonFormat == .pcmFormatFloat32
        else {
            throw CallTranscriptionError.audioWriterFailed(
                "The microphone track could not be prepared for local-speaker isolation."
            )
        }

        try? FileManager.default.removeItem(at: outputURL)
        let output = try AVAudioFile(
            forWriting: outputURL,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: self.framesPerChunk
        ) else {
            throw CallTranscriptionError.audioWriterFailed(
                "Could not allocate the local-speaker isolation buffer."
            )
        }

        let sampleRate = format.sampleRate
        var rangeIndex = 0
        var frameCursor: AVAudioFramePosition = 0

        while frameCursor < input.length {
            let remaining = input.length - frameCursor
            let framesToRead = AVAudioFrameCount(
                min(AVAudioFramePosition(self.framesPerChunk), remaining)
            )
            buffer.frameLength = 0
            try input.read(into: buffer, frameCount: framesToRead)
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { break }

            let chunkStart = frameCursor
            let chunkEnd = chunkStart + AVAudioFramePosition(frameCount)

            while rangeIndex < ranges.count {
                let range = ranges[rangeIndex]
                let rangeStart = AVAudioFramePosition(
                    (range.startSeconds * sampleRate).rounded(.down)
                )
                let rangeEnd = AVAudioFramePosition(
                    (range.endSeconds * sampleRate).rounded(.up)
                )

                if rangeEnd <= chunkStart {
                    rangeIndex += 1
                    continue
                }
                if rangeStart >= chunkEnd {
                    break
                }

                let localStart = Int(max(0, rangeStart - chunkStart))
                let localEnd = Int(min(AVAudioFramePosition(frameCount), rangeEnd - chunkStart))
                if localEnd > localStart, let channels = buffer.floatChannelData {
                    for channelIndex in 0..<Int(format.channelCount) {
                        let channel = channels[channelIndex]
                        for sampleIndex in localStart..<localEnd {
                            channel[sampleIndex] = 0
                        }
                    }
                }

                if rangeEnd <= chunkEnd {
                    rangeIndex += 1
                } else {
                    break
                }
            }

            try output.write(from: buffer)
            frameCursor += AVAudioFramePosition(frameCount)
        }

        return Result(url: outputURL, mutedRangeCount: ranges.count)
    }
}
