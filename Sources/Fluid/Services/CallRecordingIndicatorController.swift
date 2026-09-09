import AppKit
import Combine

/// A deliberately tiny, indicator-only status item shown while call capture is active.
/// It has no menu or actions, so the existing FluidVoice menu remains the single control surface.
@MainActor
final class CallRecordingIndicatorController {
    private var statusItem: NSStatusItem?
    private var cancellable: AnyCancellable?

    init(callTranscriptionService: CallTranscriptionService) {
        self.cancellable = callTranscriptionService.$isRecording
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] isRecording in
                self?.setVisible(isRecording)
            }
    }

    func hide() {
        self.setVisible(false)
    }

    private func setVisible(_ visible: Bool) {
        if visible {
            guard self.statusItem == nil else { return }

            let item = NSStatusBar.system.statusItem(withLength: 14)
            item.isVisible = true
            if let button = item.button {
                button.image = Self.recordingDotImage()
                button.imagePosition = .imageOnly
                button.imageScaling = .scaleNone
                button.toolTip = "FluidVoice is recording a call"
            }
            self.statusItem = item
            return
        }

        guard let item = self.statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.statusItem = nil
    }

    private static func recordingDotImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 6, height: 6)).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
