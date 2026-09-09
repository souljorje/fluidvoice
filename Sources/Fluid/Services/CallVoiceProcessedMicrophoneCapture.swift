import AudioToolbox
import AVFoundation
import Foundation

/// Experimental call-microphone capture through AVAudioEngine's VoiceProcessingIO path.
///
/// This intentionally runs alongside the existing raw Core Audio microphone capture so every
/// recording keeps an A/B pair. The experiment answers one question: does Apple's macOS voice
/// processing remove playback produced by other apps (Zoom/Meet/etc.) from the microphone signal?
///
/// AVAudioEngine voice processing is tied to the system default input/output route on macOS. To
/// avoid silently changing the user's selected FluidVoice microphone, this prototype only runs
/// when FluidVoice's selected microphone is also the current system default input. Otherwise the
/// normal raw microphone pipeline remains authoritative.
final class CallVoiceProcessedMicrophoneCapture: @unchecked Sendable {
    struct Track: Sendable {
        let url: URL
        let startedAt: Date
        let firstAudioOffsetSeconds: Double
        let hasSignal: Bool
    }

    enum PrototypeError: LocalizedError {
        case selectedMicrophoneIsNotSystemDefault
        case invalidInputFormat
        case noAudioCaptured

        var errorDescription: String? {
            switch self {
            case .selectedMicrophoneIsNotSystemDefault:
                return "Apple voice-processing prototype requires the FluidVoice microphone to be the macOS default input device."
            case .invalidInputFormat:
                return "Apple voice processing exposed an invalid microphone format."
            case .noAudioCaptured:
                return "Apple voice processing produced no microphone audio."
            }
        }
    }

    private static let tapBufferSize: AVAudioFrameCount = 1024
    private static let maximumFramesPerPacket: AVAudioFrameCount = 8192
    private static let signalThreshold: Float = 0.000_01

    private let microphoneDevice: AudioDevice.Device
    private let outputURL: URL
    private let engine = AVAudioEngine()
    private let lock = NSLock()

    private var audioFile: AVAudioFile?
    private var reusableBuffer: AVAudioPCMBuffer?
    private var sampleRate: Double = 0
    private var startedAt: Date?
    private var startedHostTime: UInt64?
    private var firstHostTime: UInt64?
    private var peakMagnitude: Float = 0
    private var storedError: Error?
    private var hasWrittenAudio = false
    private var tapInstalled = false
    private var didStop = false

    init(microphoneDevice: AudioDevice.Device, outputURL: URL) {
        self.microphoneDevice = microphoneDevice
        self.outputURL = outputURL
    }

    deinit {
        self.stopEngineOnly()
    }

    func start() throws {
        guard let defaultInput = AudioDevice.getDefaultInputDevice(),
              defaultInput.id == self.microphoneDevice.id
        else {
            throw PrototypeError.selectedMicrophoneIsNotSystemDefault
        }

        // Voice processing must be enabled while the engine is stopped. Touching both nodes first
        // makes the intended full-duplex I/O topology explicit; enabling either node switches both
        // I/O nodes into Apple's voice-processing mode.
        let inputNode = self.engine.inputNode
        let outputNode = self.engine.outputNode
        try inputNode.setVoiceProcessingEnabled(true)

        guard inputNode.isVoiceProcessingEnabled, outputNode.isVoiceProcessingEnabled else {
            throw PrototypeError.invalidInputFormat
        }

        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw PrototypeError.invalidInputFormat
        }

        self.sampleRate = inputFormat.sampleRate
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ),
            let reusableBuffer = AVAudioPCMBuffer(
                pcmFormat: monoFormat,
                frameCapacity: Self.maximumFramesPerPacket
            )
        else {
            throw PrototypeError.invalidInputFormat
        }

        try? FileManager.default.removeItem(at: self.outputURL)
        self.audioFile = try AVAudioFile(
            forWriting: self.outputURL,
            settings: monoFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        self.reusableBuffer = reusableBuffer
        self.startedAt = Date()
        self.startedHostTime = AudioGetCurrentHostTime()

        inputNode.installTap(
            onBus: 0,
            bufferSize: Self.tapBufferSize,
            format: nil
        ) { [weak self] buffer, time in
            self?.append(buffer: buffer, time: time)
        }
        self.tapInstalled = true

        self.engine.prepare()
        try self.engine.start()

        DebugLogger.shared.info(
            "Apple voice-processing prototype active [input=\(self.microphoneDevice.name), sampleRate=\(Int(inputFormat.sampleRate)), channels=\(inputFormat.channelCount)]",
            source: "CallVoiceProcessedMicrophoneCapture"
        )
    }

    func stop() throws -> Track {
        self.stopEngineOnly()

        self.lock.lock()
        defer { self.lock.unlock() }

        if let storedError = self.storedError {
            throw storedError
        }
        guard self.hasWrittenAudio,
              let startedAt = self.startedAt,
              let startedHostTime = self.startedHostTime,
              let firstHostTime = self.firstHostTime
        else {
            self.audioFile = nil
            self.reusableBuffer = nil
            try? FileManager.default.removeItem(at: self.outputURL)
            throw PrototypeError.noAudioCaptured
        }

        self.audioFile = nil
        self.reusableBuffer = nil

        let delta = firstHostTime >= startedHostTime ? firstHostTime - startedHostTime : 0
        let firstAudioOffsetSeconds = Double(AudioConvertHostTimeToNanos(delta)) / 1_000_000_000
        return Track(
            url: self.outputURL,
            startedAt: startedAt,
            firstAudioOffsetSeconds: firstAudioOffsetSeconds.isFinite ? max(0, firstAudioOffsetSeconds) : 0,
            hasSignal: self.peakMagnitude >= Self.signalThreshold
        )
    }

    private func append(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        do {
            let samples = try AudioBufferConverter.monoSamples(
                from: buffer,
                targetSampleRate: self.sampleRate
            )
            guard !samples.isEmpty else { return }

            try samples.withUnsafeBufferPointer { pointer in
                guard let baseAddress = pointer.baseAddress else { return }
                try self.append(
                    samples: baseAddress,
                    frameCount: pointer.count,
                    hostTime: time.isHostTimeValid ? time.hostTime : AudioGetCurrentHostTime()
                )
            }
        } catch {
            self.lock.lock()
            if self.storedError == nil {
                self.storedError = error
            }
            self.lock.unlock()
        }
    }

    private func append(
        samples: UnsafePointer<Float>,
        frameCount: Int,
        hostTime: UInt64
    ) throws {
        guard frameCount > 0 else { return }

        self.lock.lock()
        defer { self.lock.unlock() }

        if let storedError = self.storedError {
            throw storedError
        }
        guard let audioFile = self.audioFile,
              let buffer = self.reusableBuffer,
              let channel = buffer.floatChannelData?.pointee
        else {
            throw CallTranscriptionError.audioWriterFailed(
                "Apple voice-processing microphone writer was not prepared."
            )
        }
        guard frameCount <= Int(buffer.frameCapacity) else {
            throw CallTranscriptionError.audioWriterFailed(
                "Apple voice-processing microphone packet exceeded the supported frame count."
            )
        }

        if self.firstHostTime == nil {
            self.firstHostTime = hostTime
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        channel.update(from: samples, count: frameCount)
        for index in 0..<frameCount {
            self.peakMagnitude = max(self.peakMagnitude, abs(samples[index]))
        }
        try audioFile.write(from: buffer)
        self.hasWrittenAudio = true
    }

    private func stopEngineOnly() {
        self.lock.lock()
        guard !self.didStop else {
            self.lock.unlock()
            return
        }
        self.didStop = true
        self.lock.unlock()

        if self.engine.isRunning {
            self.engine.stop()
        }
        if self.tapInstalled {
            self.engine.inputNode.removeTap(onBus: 0)
            self.tapInstalled = false
        }
        if self.engine.inputNode.isVoiceProcessingEnabled {
            try? self.engine.inputNode.setVoiceProcessingEnabled(false)
        }
    }
}
