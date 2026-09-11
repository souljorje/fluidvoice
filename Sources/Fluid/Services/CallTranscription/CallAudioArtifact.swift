import Foundation

enum CallAudioSource: Sendable, Equatable {
    case microphone
    case system
}

struct CapturedAudioTrack: Sendable {
    let source: CallAudioSource
    let url: URL
    let startOffsetSeconds: Double
}

struct CapturedCallAudio: Sendable {
    let directoryURL: URL
    let fileName: String
    let tracks: [CapturedAudioTrack]

    var timelineAnchorSeconds: Double {
        self.tracks.map(\.startOffsetSeconds).min() ?? 0
    }

    func relativeStart(for track: CapturedAudioTrack) -> Double {
        max(0, track.startOffsetSeconds - self.timelineAnchorSeconds)
    }

    func remove() {
        CallCaptureSession.removeRecordingDirectory(at: self.directoryURL)
    }
}
