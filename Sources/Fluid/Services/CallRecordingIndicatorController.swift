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

            let item = NSStatusBar.system.statusItem(withLength: 10)
            if let button = item.button {
                button.attributedTitle = NSAttributedString(
                    string: "●",
                    attributes: [
                        .foregroundColor: NSColor.systemRed,
                        .font: NSFont.systemFont(ofSize: 7, weight: .semibold),
                    ]
                )
                button.toolTip = "FluidVoice is recording a call"
            }
            self.statusItem = item
            return
        }

        guard let item = self.statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        self.statusItem = nil
    }
}
