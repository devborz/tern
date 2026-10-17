import AppKit

/// The small square button at the end of a status line that copies the
/// command's output. Placed by `SessionTerminalView` over the status line's
/// reserved cells.
final class CopyOutputButton: NSButton {
    /// The command whose output this button copies.
    var commandID: UUID?
    var onCopy: ((UUID) -> Bool)?

    private var isHovered = false {
        didSet { needsDisplay = true }
    }
    private var resetIcon: DispatchWorkItem?

    init() {
        super.init(frame: .zero)
        isBordered = false
        title = ""
        imagePosition = .imageOnly
        toolTip = "Copy Output"
        setAccessibilityLabel("Copy Output")
        wantsLayer = true
        target = self
        action = #selector(copyOutput)
        showIcon("square.on.square")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.cornerRadius = 4
        layer.backgroundColor = isHovered ? NSColor.quaternaryLabelColor.cgColor : NSColor.clear.cgColor
        contentTintColor = isHovered ? .labelColor : .secondaryLabelColor
    }

    override func setFrameSize(_ newSize: NSSize) {
        let resized = newSize != frame.size
        super.setFrameSize(newSize)
        if resized {
            showIcon(resetIcon == nil ? "square.on.square" : "checkmark")
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    @objc private func copyOutput() {
        guard let commandID, onCopy?(commandID) == true else {
            NSSound.beep()
            return
        }
        // A checkmark for a moment confirms the copy.
        resetIcon?.cancel()
        let reset = DispatchWorkItem { [weak self] in
            self?.resetIcon = nil
            self?.showIcon("square.on.square")
        }
        resetIcon = reset
        showIcon("checkmark")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: reset)
    }

    private func showIcon(_ symbolName: String) {
        let pointSize = max(7, min(frame.width, frame.height) * 0.55)
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
    }
}
