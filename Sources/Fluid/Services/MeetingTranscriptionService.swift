import Combine
import Foundation
import UniformTypeIdentifiers

/// UI-facing coordinator for transcribing a user-selected file.
@MainActor
final class MeetingTranscriptionService: ObservableObject {
    typealias TranscriptionError = AudioFileTranscriptionEngine.TranscriptionError

    @Published var isTranscribing = false
    @Published var progress = 0.0
    @Published var currentStatus = ""
    @Published var error: String?
    @Published var result: TranscriptionResult?

    static let supportedFileExtensions = AudioFileTranscriptionEngine.supportedFileExtensions
    static let allowedContentTypes: [UTType] = AudioFileTranscriptionEngine.allowedContentTypes
    static let supportedFormatsDescription = AudioFileTranscriptionEngine.supportedFormatsDescription
    static let dropErrorCopy = AudioFileTranscriptionEngine.dropErrorCopy

    private let engine: AudioFileTranscriptionEngine

    init(asrService: ASRService) {
        self.engine = AudioFileTranscriptionEngine(asrService: asrService)
    }

    func transcribeFile(_ fileURL: URL) async throws -> TranscriptionResult {
        let settings = SettingsStore.shared
        let expectedSpeakerCount = settings.fileTranscriptionExpectedSpeakerCount
        let options = AudioFileTranscriptionOptions(
            speakerLabelsEnabled: settings.fileTranscriptionSpeakerLabelsEnabled,
            expectedSpeakerCount: expectedSpeakerCount > 0 ? expectedSpeakerCount : nil
        )
        self.isTranscribing = true
        self.error = nil
        self.progress = 0

        defer {
            self.isTranscribing = false
            self.progress = 0
        }

        do {
            let result = try await self.engine.transcribeFile(
                fileURL,
                options: options,
                progressHandler: { [weak self] status, progress in
                    self?.currentStatus = status
                    self?.progress = progress
                }
            )
            AnalyticsService.shared.recordUsage(
                mode: .meeting,
                transcriptionModel: settings.selectedSpeechModel.analyticsDescriptor
            )
            self.result = result
            FileTranscriptionHistoryStore.shared.addEntry(result)
            return result
        } catch let error as TranscriptionError {
            throw error
        } catch {
            let wrappedError = TranscriptionError.transcriptionFailed(error.localizedDescription)
            throw wrappedError
        }
    }

    nonisolated func exportToText(_ result: TranscriptionResult, to destinationURL: URL) throws {
        try result.textExport.write(to: destinationURL, atomically: true, encoding: .utf8)
    }

    nonisolated func exportToJSON(_ result: TranscriptionResult, to destinationURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let jsonData = try encoder.encode(result)
        try jsonData.write(to: destinationURL)
    }

    func reset() {
        self.result = nil
        self.error = nil
        self.currentStatus = ""
        self.progress = 0
    }
}