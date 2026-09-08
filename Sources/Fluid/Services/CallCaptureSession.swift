import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

struct CallRecording: Sendable {
    let directoryURL: URL
    let audioURL: URL
    let systemAudioURL: URL?
    let microphoneAudioURL: URL?
    let startedAt: Date
    let duration: TimeInterval
}

enum CallTranscriptionError: LocalizedError {
    case noDisplayAvailable
    case noAudioCaptured
    case notRecording
    case audioWriterFailed(String)
    case audioMixFailed(String)

    var errorDescription: String? {
        switch self {
        case .noDisplayAvailable:
            return "No display is available for system-audio capture."
        case .noAudioCaptured:
            return "No call audio was captured."
        case .notRecording:
            return "No call recording is active."
        case let .audioWriterFailed(message):
            return "Could not save call audio: \(message)"
        case let .audioMixFailed(message):
            return "Could not prepare call audio: \(message)"
        }
    }
}

private struct CapturedAudioTrack: Sendable {
    let url: URL
    let startOffsetSeconds: Double
}

final class CallCaptureSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let sampleQueue = DispatchQueue(label: "com.fluidvoice.call-capture.audio", qos: .userInitiated)
    private var stream: SCStream?
    private var systemWriter: CallAudioTrackWriter?
    private var microphoneWriter: CallAudioTrackWriter?
    private var directoryURL: URL?
    private var startedAt: Date?
    private var captureStartedUptime: TimeInterval?
    private var captureError: Error?

    func start() async throws -> URL {
        let directory = try Self.makeRecordingDirectory()
        let systemURL = directory.appendingPathComponent("system.m4a")
        let microphoneURL = directory.appendingPathComponent("microphone.m4a")

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw CallTranscriptionError.noDisplayAvailable
        }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.captureMicrophone = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.showsCursor = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        self.directoryURL = directory
        self.startedAt = Date()
        self.stream = stream
        self.systemWriter = CallAudioTrackWriter(url: systemURL)
        self.microphoneWriter = CallAudioTrackWriter(url: microphoneURL)
        self.captureError = nil

        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.sampleQueue)
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: self.sampleQueue)
            self.captureStartedUptime = ProcessInfo.processInfo.systemUptime
            try await stream.startCapture()
            return directory
        } catch {
            self.resetCaptureState()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func stop() async throws -> CallRecording {
        guard let directory = self.directoryURL, let startedAt = self.startedAt else {
            throw CallTranscriptionError.notRecording
        }

        var stopError: Error?
        if let stream = self.stream {
            do {
                try await stream.stopCapture()
            } catch {
                stopError = error
            }
        }
        self.stream = nil

        // ScreenCaptureKit invokes both audio outputs on this queue. Draining it guarantees
        // every delivered sample has reached its writer before finalization begins.
        self.sampleQueue.sync {}

        let systemTrack = try await self.systemWriter?.finish()
        let microphoneTrack = try await self.microphoneWriter?.finish()
        self.systemWriter = nil
        self.microphoneWriter = nil
        self.directoryURL = nil
        self.startedAt = nil
        self.captureStartedUptime = nil

        if let error = self.captureError ?? stopError {
            self.captureError = nil
            throw error
        }
        self.captureError = nil

        let tracks = [systemTrack, microphoneTrack].compactMap { $0 }
        guard !tracks.isEmpty else {
            throw CallTranscriptionError.noAudioCaptured
        }

        let audioURL = try await CallAudioMixer.makeMixedRecording(
            in: directory,
            tracks: tracks
        )
        let duration = await Self.duration(of: audioURL)

        return CallRecording(
            directoryURL: directory,
            audioURL: audioURL,
            systemAudioURL: systemTrack?.url,
            microphoneAudioURL: microphoneTrack?.url,
            startedAt: startedAt,
            duration: duration
        )
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard self.captureError == nil, let captureStartedUptime = self.captureStartedUptime else { return }
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else { return }

        let arrivalUptime = ProcessInfo.processInfo.systemUptime
        do {
            switch outputType {
            case .audio:
                try self.systemWriter?.append(
                    sampleBuffer,
                    captureStartedUptime: captureStartedUptime,
                    arrivalUptime: arrivalUptime
                )
            case .microphone:
                try self.microphoneWriter?.append(
                    sampleBuffer,
                    captureStartedUptime: captureStartedUptime,
                    arrivalUptime: arrivalUptime
                )
            default:
                break
            }
        } catch {
            self.captureError = error
            DebugLogger.shared.error(
                "Call audio capture failed: \(error.localizedDescription)",
                source: "CallCaptureSession"
            )
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.sampleQueue.async { [weak self] in
            guard let self, self.captureError == nil else { return }
            self.captureError = error
            DebugLogger.shared.error(
                "Call capture stream stopped: \(error.localizedDescription)",
                source: "CallCaptureSession"
            )
        }
    }

    private func resetCaptureState() {
        self.stream = nil
        self.systemWriter = nil
        self.microphoneWriter = nil
        self.directoryURL = nil
        self.startedAt = nil
        self.captureStartedUptime = nil
        self.captureError = nil
    }

    private static func makeRecordingDirectory() throws -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let root = applicationSupport
            .appendingPathComponent("FluidVoice", isDirectory: true)
            .appendingPathComponent("Calls", isDirectory: true)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func duration(of url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return 0 }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite ? max(0, seconds) : 0
    }
}

private final class CallAudioTrackWriter: @unchecked Sendable {
    private static let readinessTimeout: TimeInterval = 1

    private let url: URL
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var startOffsetSeconds: Double?
    private var hasAppendedSamples = false

    init(url: URL) {
        self.url = url
    }

    func append(
        _ sampleBuffer: CMSampleBuffer,
        captureStartedUptime: TimeInterval,
        arrivalUptime: TimeInterval
    ) throws {
        if self.writer == nil {
            try self.prepareWriter(
                for: sampleBuffer,
                captureStartedUptime: captureStartedUptime,
                arrivalUptime: arrivalUptime
            )
        }

        guard let writer, let input else { return }
        guard writer.status == .writing else {
            throw CallTranscriptionError.audioWriterFailed(
                writer.error?.localizedDescription ?? "Audio writer is not running."
            )
        }

        try self.waitUntilReady(input, writer: writer)

        guard input.append(sampleBuffer) else {
            throw CallTranscriptionError.audioWriterFailed(
                writer.error?.localizedDescription ?? "Could not append audio samples."
            )
        }
        self.hasAppendedSamples = true
    }

    func finish() async throws -> CapturedAudioTrack? {
        guard self.hasAppendedSamples,
              let writer,
              let input,
              let startOffsetSeconds
        else {
            try? FileManager.default.removeItem(at: self.url)
            return nil
        }

        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }

        guard writer.status == .completed else {
            throw CallTranscriptionError.audioWriterFailed(
                writer.error?.localizedDescription ?? "Audio writer did not finish successfully."
            )
        }
        return CapturedAudioTrack(
            url: self.url,
            startOffsetSeconds: startOffsetSeconds
        )
    }

    private func prepareWriter(
        for sampleBuffer: CMSampleBuffer,
        captureStartedUptime: TimeInterval,
        arrivalUptime: TimeInterval
    ) throws {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let basicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee
        else {
            throw CallTranscriptionError.audioWriterFailed("Missing audio format description.")
        }

        let firstPresentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let firstPresentationSeconds = CMTimeGetSeconds(firstPresentationTime)
        guard firstPresentationSeconds.isFinite else {
            throw CallTranscriptionError.audioWriterFailed("Captured audio has an invalid timestamp.")
        }

        let bufferDuration = CMTimeGetSeconds(CMSampleBufferGetDuration(sampleBuffer))
        let safeBufferDuration = bufferDuration.isFinite ? max(0, bufferDuration) : 0
        let estimatedBufferStartUptime = arrivalUptime - safeBufferDuration
        let startOffsetSeconds = max(0, estimatedBufferStartUptime - captureStartedUptime)

        try? FileManager.default.removeItem(at: self.url)
        let writer = try AVAssetWriter(outputURL: self.url, fileType: .m4a)
        let channels = max(1, Int(basicDescription.mChannelsPerFrame))
        let sampleRate = basicDescription.mSampleRate > 0 ? basicDescription.mSampleRate : 48_000
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels > 1 ? 192_000 : 96_000,
        ]
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: settings,
            sourceFormatHint: formatDescription
        )
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw CallTranscriptionError.audioWriterFailed("Audio writer rejected the captured format.")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw CallTranscriptionError.audioWriterFailed(
                writer.error?.localizedDescription ?? "Could not start audio writer."
            )
        }
        writer.startSession(atSourceTime: firstPresentationTime)

        self.writer = writer
        self.input = input
        self.startOffsetSeconds = startOffsetSeconds
    }

    private func waitUntilReady(_ input: AVAssetWriterInput, writer: AVAssetWriter) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + Self.readinessTimeout
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else {
                throw CallTranscriptionError.audioWriterFailed(
                    writer.error?.localizedDescription ?? "Audio writer stopped while encoding."
                )
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw CallTranscriptionError.audioWriterFailed(
                    "Audio encoder fell behind for more than \(Int(Self.readinessTimeout * 1000)) ms."
                )
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }
}

private enum CallAudioMixer {
    static func makeMixedRecording(
        in directory: URL,
        tracks: [CapturedAudioTrack]
    ) async throws -> URL {
        guard let anchorSeconds = tracks.map(\.startOffsetSeconds).min() else {
            throw CallTranscriptionError.noAudioCaptured
        }

        let outputURL = directory.appendingPathComponent("call.m4a")
        try? FileManager.default.removeItem(at: outputURL)

        let composition = AVMutableComposition()
        var mixParameters: [AVMutableAudioMixInputParameters] = []

        for capturedTrack in tracks {
            let asset = AVURLAsset(url: capturedTrack.url)
            guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            let duration = try await asset.load(.duration)
            let durationSeconds = CMTimeGetSeconds(duration)
            guard duration.isValid, durationSeconds.isFinite, durationSeconds > 0 else { continue }
            guard let destinationTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }

            let relativeStart = max(0, capturedTrack.startOffsetSeconds - anchorSeconds)
            let insertionTime = CMTime(seconds: relativeStart, preferredTimescale: 48_000)
            do {
                try destinationTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration),
                    of: sourceTrack,
                    at: insertionTime
                )
            } catch {
                throw CallTranscriptionError.audioMixFailed(error.localizedDescription)
            }

            let parameters = AVMutableAudioMixInputParameters(track: destinationTrack)
            parameters.setVolume(1, at: .zero)
            mixParameters.append(parameters)
        }

        guard !mixParameters.isEmpty else {
            throw CallTranscriptionError.noAudioCaptured
        }
        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw CallTranscriptionError.audioMixFailed("Could not create audio exporter.")
        }

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = mixParameters
        exporter.audioMix = audioMix
        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a

        await withCheckedContinuation { continuation in
            exporter.exportAsynchronously {
                continuation.resume()
            }
        }

        guard exporter.status == .completed else {
            throw CallTranscriptionError.audioMixFailed(
                exporter.error?.localizedDescription ?? "Audio export did not complete."
            )
        }
        return outputURL
    }
}
