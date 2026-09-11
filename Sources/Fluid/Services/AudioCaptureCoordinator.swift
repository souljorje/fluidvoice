import Foundation

/// Serializes microphone-owning workflows that share audio hardware and ASR providers.
@MainActor
final class AudioCaptureCoordinator {
    enum Owner {
        case call
        case dictation
    }

    static let shared = AudioCaptureCoordinator()

    private(set) var owner: Owner?

    init() {}

    func reserve(for requestedOwner: Owner) -> Bool {
        guard self.owner == nil else { return false }
        self.owner = requestedOwner
        return true
    }

    func release(for releasingOwner: Owner) {
        guard self.owner == releasingOwner else { return }
        self.owner = nil
    }
}
