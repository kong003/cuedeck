import AppKit
import AVFoundation

/// A display the video can be sent to.
struct ScreenInfo: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    let size: CGSize
    let isMain: Bool   // the display with the menu bar

    var menuLabel: String {
        "\(name) (\(Int(size.width))×\(Int(size.height)))\(isMain ? " · main" : "")"
    }

    static func all() -> [ScreenInfo] {
        NSScreen.screens.enumerated().compactMap { index, screen in
            guard let id = screen.displayID else { return nil }
            return ScreenInfo(id: id, name: screen.localizedName,
                              size: screen.frame.size, isMain: index == 0)
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// Borderless, click-through, never-key window covering one display.
private final class OutputWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class OutputView: NSView {
    override var isOpaque: Bool { true }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.sublayers?.forEach { $0.frame = bounds }
        CATransaction.commit()
    }
}

/// Manages the fullscreen video output. The window exists only while at
/// least one cue with video is playing; when the last video layer is removed
/// the window is closed, so nothing stays on the output display.
@MainActor
final class VideoOutput {
    private var window: OutputWindow?
    private var layers: [AVPlayerLayer] = []
    private(set) var displayID: CGDirectDisplayID?

    var isOpen: Bool { window != nil }

    /// The display to use from now on. An open window moves immediately.
    func setDisplay(_ id: CGDirectDisplayID?) {
        displayID = id
        if let w = window, let screen = targetScreen() {
            w.setFrame(screen.frame, display: true)
        }
    }

    private func targetScreen() -> NSScreen? {
        if let id = displayID, let s = NSScreen.screens.first(where: { $0.displayID == id }) { return s }
        // Fallback: any display other than the main one, else the main one.
        return NSScreen.screens.count > 1 ? NSScreen.screens[1] : NSScreen.screens.first
    }

    /// Adds a player layer on top of any existing ones, opening the window
    /// on the output display if needed.
    func attach(_ layer: AVPlayerLayer) {
        let w = window ?? makeWindow()
        guard let host = w.contentView?.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = host.bounds
        host.addSublayer(layer)
        CATransaction.commit()
        layers.append(layer)
        if !w.isVisible { w.orderFrontRegardless() }
    }

    /// Removes a player layer; closes the window if it was the last one.
    func detach(_ layer: AVPlayerLayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeFromSuperlayer()
        CATransaction.commit()
        layers.removeAll { $0 === layer }
        if layers.isEmpty { close() }
    }

    func close() {
        layers.forEach { $0.removeFromSuperlayer() }
        layers.removeAll()
        window?.orderOut(nil)
        window?.close()
        window = nil
    }

    /// Call when displays are added or removed.
    func screensChanged() {
        guard let w = window else { return }
        if let screen = targetScreen() {
            w.setFrame(screen.frame, display: true)
        } else {
            close()
        }
    }

    private func makeWindow() -> OutputWindow {
        let frame = targetScreen()?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 720)
        let w = OutputWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.setFrame(frame, display: false)
        w.isReleasedWhenClosed = false
        w.backgroundColor = .black
        w.isOpaque = true
        w.hasShadow = false
        w.ignoresMouseEvents = true          // clicks go to whatever is underneath
        w.level = .screenSaver               // above the menu bar and the Dock
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        w.isExcludedFromWindowsMenu = true
        w.animationBehavior = .none
        w.title = "CueDeck Output"

        let view = OutputView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.autoresizingMask = [.width, .height]
        w.contentView = view
        window = w
        return w
    }
}
