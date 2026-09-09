import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

struct CallRecording: Sendable {
    let directoryURL: URL
    let audioURL: URL
    let startedAt: Date
    let duration: TimeInterval
}

enum CallTranscriptionError: LocalizedError {
    case noAudioCaptured
    case notRecording
    case microphoneUnavailable
    case systemAudioUnavailable(String)
    case audioWriterFailed(String)
    case audioMixFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioCaptured:
            return "No call audio was captured."
        case .notRecording:
            return "No call recording is active."
        case .microphoneUnavailable:
            return "No microphone is available for call recording."
        case let .systemAudioUnavailable(detail):
            return "System audio could not be captured. Allow FluidVoice to record system audio in Privacy & Security, then try again. \(detail)"
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

/// Captures system audio and the selected microphone independently so they can be aligned into a
/// single call recording without requesting screen access. Transcription runs once on the mixed
/// recording; the source tracks are kept only as capture artifacts.
final class CallCaptureSession: @unchecked Sendable {
    private let microphoneDevice: AudioDevice.Device
    private var systemTap: CallSystemAudioTap?
    private var systemCapture: DirectCoreAudioLifecycleController?
    private var microphoneCapture: DirectCoreAudioLifecycleController?
    private var systemWriter: CallPCMTrackWriter?
    private var microphoneWriter: CallPCMTrackWriter?
    private var directoryURL: URL?
    private var startedAt: Date?
    private var captureStartedHostTime: UInt64?
    private var recordingStamp: String?

    init(microphoneDevice: AudioDevice.Device) {
        self.microphoneDevice = microphoneDevice
    }

    func start() async throws -> URL {
        let startedAt = Date()
        let stamp = Self.recordingStamp(for: startedAt)
        let directory = try Self.makeRecordingDirectory(stamp: stamp)
        let systemPCMURL = directory.appendingPathComponent("system.caf")
        let microphonePCMURL = directory.appendingPathComponent("microphone.caf")
        let captureStartedHostTime = AudioGetCurrentHostTime()

        let systemWriter = CallPCMTrackWriter(
            url: systemPCMURL,
            captureStartedHostTime: captureStartedHostTime
        )
        let microphoneWriter = CallPCMTrackWriter(
            url: microphonePCMURL,
            captureStartedHostTime: captureStartedHostTime
        )

        self.directoryURL = directory
        self.startedAt = startedAt
        self.recordingStamp = stamp
        self.captureStartedHostTime = captureStartedHostTime
        self.systemWriter = systemWriter
        self.microphoneWriter = microphoneWriter

        do {
            let tap = try await CallSystemAudioTap.create()
            self.systemTap = tap

            let systemCapture = DirectCoreAudioLifecycleController(
                packetHandler: { samples, frameCount, sampleRate, hostTime, _ in
                    do {
                        try systemWriter.append(
                            samples: samples,
                            frameCount: frameCount,
                            sampleRate: sampleRate,
                            hostTime: hostTime
                        )
                    } catch {
                        systemWriter.record(error: error)
                    }
                },
                installsHardwareListeners: false,
                onFormatInvalidated: { _ in }
            )
            self.systemCapture = systemCapture
            do {
                _ = try await systemCapture.start(
                    deviceID: tap.aggregateDeviceID,
                    deviceName: "FluidVoice System Audio",
                    reason: "call_recording"
                )
            } catch {
                throw CallTranscriptionError.systemAudioUnavailable(error.localizedDescription)
            }

            let microphoneCapture = DirectCoreAudioLifecycleController(
                packetHandler: { samples, frameCount, sampleRate, hostTime, _ in
                    do {
                        try microphoneWriter.append(
                            samples: samples,
                            frameCount: frameCount,
                            sampleRate: sampleRate,
                            hostTime: hostTime
                        )
                    } catch {
                        microphoneWriter.record(error: error)
                    }
                },
                installsHardwareListeners: false,
                onFormatInvalidated: { _ in }
            )
            self.microphoneCapture = microphoneCapture
            _ = try await microphoneCapture.start(
                deviceID: self.microphoneDevice.id,
                deviceName: self.microphoneDevice.name,
                reason: "call_recording"
            )

            return directory
        } catch {
            await self.stopCaptureInfrastructure(reason: "call_start_failed")
            self.resetCaptureState()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func stop() async throws -> CallRecording {
        guard let directory = self.directoryURL,
              let startedAt = self.startedAt,
              let stamp = self.recordingStamp
        else {
            throw CallTranscriptionError.notRecording
        }

        await self.stopCaptureInfrastructure(reason: "call_stop")

        let systemTrack = try self.systemWriter?.finish()
        let microphoneTrack = try self.microphoneWriter?.finish()
        self.systemWriter = nil
        self.microphoneWriter = nil

        let exportedSystemTrack = try await Self.exportTrack(
            systemTrack,
            to: directory.appendingPathComponent("system.m4a")
        )
        let exportedMicrophoneTrack = try await Self.exportTrack(
            microphoneTrack,
            to: directory.appendingPathComponent("microphone.m4a")
        )

        let tracks = [exportedSystemTrack, exportedMicrophoneTrack].compactMap { $0 }
        guard !tracks.isEmpty else {
            self.resetCaptureState()
            throw CallTranscriptionError.noAudioCaptured
        }

        let outputURL = directory.appendingPathComponent("call-\(stamp).m4a")
        let audioURL = try await CallAudioMixer.makeMixedRecording(
            outputURL: outputURL,
            tracks: tracks
        )
        let duration = await Self.duration(of: audioURL)

        let recording = CallRecording(
            directoryURL: directory,
            audioURL: audioURL,
            startedAt: startedAt,
            duration: duration
        )
        self.resetCaptureState()
        return recording
    }

    private func stopCaptureInfrastructure(reason: String) async {
        if let microphoneCapture = self.microphoneCapture {
            _ = await microphoneCapture.stop(retainPrepared: false, reason: reason)
        }
        self.microphoneCapture = nil

        if let systemCapture = self.systemCapture {
            _ = await systemCapture.stop(retainPrepared: false, reason: reason)
        }
        self.systemCapture = nil

        self.systemTap?.destroy()
        self.systemTap = nil
    }

    private func resetCaptureState() {
        self.systemTap = nil
        self.systemCapture = nil
        self.microphoneCapture = nil
        self.systemWriter = nil
        self.microphoneWriter = nil
        self.directoryURL = nil
        self.startedAt = nil
        self.captureStartedHostTime = nil
        self.recordingStamp = nil
    }

    private static func recordingStamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: date)
    }

    private static func makeRecordingDirectory(stamp: String) throws -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let root = applicationSupport
            .appendingPathComponent("FluidVoice", isDirectory: true)
            .appendingPathComponent("Calls", isDirectory: true)
        let suffix = String(UUID().uuidString.prefix(6))
        let directory = root.appendingPathComponent("\(stamp)-\(suffix)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func exportTrack(
        _ track: CapturedAudioTrack?,
        to outputURL: URL
    ) async throws -> CapturedAudioTrack? {
        guard let track else { return nil }
        try? FileManager.default.removeItem(at: outputURL)

        let asset = AVURLAsset(url: track.url)
        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw CallTranscriptionError.audioWriterFailed("Could not create the audio exporter.")
        }
        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a

        await withCheckedContinuation { continuation in
            exporter.exportAsynchronously {
                continuation.resume()
            }
        }
        guard exporter.status == .completed else {
            throw CallTranscriptionError.audioWriterFailed(
                exporter.error?.localizedDescription ?? "Audio export did not complete."
            )
        }
        try? FileManager.default.removeItem(at: track.url)
        return CapturedAudioTrack(
            url: outputURL,
            startOffsetSeconds: track.startOffsetSeconds
        )
    }

    private static func duration(of url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return 0 }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite ? max(0, seconds) : 0
    }
}

/// Owns the Core Audio global process tap and the private aggregate device that exposes it as an
/// input device. No screen or window frames are involved.
private final class CallSystemAudioTap: @unchecked Sendable {
    let tapID: AudioObjectID
    let aggregateDeviceID: AudioObjectID
    private let lock = NSLock()
    private var isDestroyed = false

    private init(tapID: AudioObjectID, aggregateDeviceID: AudioObjectID) {
        self.tapID = tapID
        self.aggregateDeviceID = aggregateDeviceID
    }

    deinit {
        self.destroy()
    }

    static func create() async throws -> CallSystemAudioTap {
        let excludedProcesses = Self.currentProcessObjectID().map { [$0] } ?? []
        let tapDescription = CATapDescription(
            stereoGlobalTapButExcludeProcesses: excludedProcesses
        )
        tapDescription.name = "FluidVoice Call System Audio"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted
        tapDescription.uuid = UUID()

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard tapStatus == noErr, tapID != kAudioObjectUnknown else {
            throw CallTranscriptionError.systemAudioUnavailable(
                "Core Audio could not create a system-audio tap (OSStatus \(tapStatus))."
            )
        }

        let aggregateUID = "com.fluidvoice.call-audio.\(UUID().uuidString)"
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "FluidVoice Call Audio",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]

        var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &aggregateDeviceID
        )
        guard aggregateStatus == noErr, aggregateDeviceID != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tapID)
            throw CallTranscriptionError.systemAudioUnavailable(
                "Core Audio could not create the private capture device (OSStatus \(aggregateStatus))."
            )
        }

        do {
            try await Self.waitUntilAlive(deviceID: aggregateDeviceID)
        } catch {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            AudioHardwareDestroyProcessTap(tapID)
            throw error
        }

        return CallSystemAudioTap(
            tapID: tapID,
            aggregateDeviceID: aggregateDeviceID
        )
    }

    func destroy() {
        self.lock.lock()
        guard !self.isDestroyed else {
            self.lock.unlock()
            return
        }
        self.isDestroyed = true
        self.lock.unlock()

        if self.aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(self.aggregateDeviceID)
        }
        if self.tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(self.tapID)
        }
    }

    private static func waitUntilAlive(deviceID: AudioObjectID) async throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        for _ in 0..<30 {
            var isAlive: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &size,
                &isAlive
            )
            if status == noErr, isAlive != 0 {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        throw CallTranscriptionError.systemAudioUnavailable(
            "The Core Audio capture device did not become ready."
        )
    }

    private static func currentProcessObjectID() -> AudioObjectID? {
        var pid = getpid()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &pid) { pidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                pidPointer,
                &size,
                &processObjectID
            )
        }
        guard status == noErr, processObjectID != kAudioObjectUnknown else { return nil }
        return processObjectID
    }
}

/// File writer used after the repository's realtime-safe direct capture ring. The packet callback
/// is already off Core Audio's IO thread, so encoding/file IO here cannot block the realtime path.
private final class CallPCMTrackWriter: @unchecked Sendable {
    private static let maximumFramesPerPacket: AVAudioFrameCount = 8192

    private let url: URL
    private let captureStartedHostTime: UInt64
    private let lock = NSLock()
    private var audioFile: AVAudioFile?
    private var audioFormat: AVAudioFormat?
    private var reusableBuffer: AVAudioPCMBuffer?
    private var firstHostTime: UInt64?
    private var hasWrittenAudio = false
    private var storedError: Error?

    init(url: URL, captureStartedHostTime: UInt64) {
        self.url = url
        self.captureStartedHostTime = captureStartedHostTime
    }

    func append(
        samples: UnsafePointer<Float>,
        frameCount: Int,
        sampleRate: Double,
        hostTime: UInt64
    ) throws {
        guard frameCount > 0, sampleRate > 0 else { return }
        self.lock.lock()
        defer { self.lock.unlock() }
        if let storedError = self.storedError {
            throw storedError
        }

        if self.audioFile == nil {
            try self.prepare(sampleRate: sampleRate)
            self.firstHostTime = hostTime
        }
        guard let audioFile = self.audioFile,
              let buffer = self.reusableBuffer,
              let channel = buffer.floatChannelData?.pointee
        else {
            throw CallTranscriptionError.audioWriterFailed("Could not prepare the PCM writer.")
        }
        guard frameCount <= Int(buffer.frameCapacity) else {
            throw CallTranscriptionError.audioWriterFailed(
                "Captured audio packet exceeded the supported frame count."
            )
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        channel.update(from: samples, count: frameCount)
        try audioFile.write(from: buffer)
        self.hasWrittenAudio = true
    }

    func record(error: Error) {
        self.lock.lock()
        if self.storedError == nil {
            self.storedError = error
        }
        self.lock.unlock()
    }

    func finish() throws -> CapturedAudioTrack? {
        self.lock.lock()
        defer { self.lock.unlock() }
        if let storedError = self.storedError {
            throw storedError
        }
        guard self.hasWrittenAudio, let firstHostTime = self.firstHostTime else {
            self.audioFile = nil
            self.reusableBuffer = nil
            try? FileManager.default.removeItem(at: self.url)
            return nil
        }

        self.audioFile = nil
        self.audioFormat = nil
        self.reusableBuffer = nil

        let delta = firstHostTime >= self.captureStartedHostTime
            ? firstHostTime - self.captureStartedHostTime
            : 0
        let offset = Double(AudioConvertHostTimeToNanos(delta)) / 1_000_000_000
        return CapturedAudioTrack(
            url: self.url,
            startOffsetSeconds: offset.isFinite ? max(0, offset) : 0
        )
    }

    private func prepare(sampleRate: Double) throws {
        try? FileManager.default.removeItem(at: self.url)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: 8192
            )
        else {
            throw CallTranscriptionError.audioWriterFailed("Could not create the PCM format.")
        }

        self.audioFile = try AVAudioFile(
            forWriting: self.url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        self.audioFormat = format
        self.reusableBuffer = buffer
    }
}

private enum CallAudioMixer {
    static func makeMixedRecording(
        outputURL: URL,
        tracks: [CapturedAudioTrack]
    ) async throws -> URL {
        guard let anchorSeconds = tracks.map(\.startOffsetSeconds).min() else {
            throw CallTranscriptionError.noAudioCaptured
        }
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
