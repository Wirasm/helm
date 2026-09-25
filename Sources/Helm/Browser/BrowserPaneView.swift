import AppKit
import SwiftUI

/// A browser pane: a thin address bar over the shared browser's current tab.
struct BrowserPaneView: View {
    @ObservedObject var model: BrowserPaneModel
    /// Whether the bench says this pane holds the keyboard. Same contract as a terminal's:
    /// acted on only when it becomes true, so a pane that merely appears never takes focus.
    let holdsKeyboard: Bool

    @State private var address = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider()
            ZStack {
                BrowserSurface(model: model, holdsKeyboard: holdsKeyboard)
                if model.status != .connected {
                    notice
                }
            }
        }
        .background(Color.surface)
        .onChange(of: model.tabs.current?.url) { _, url in
            if !addressFocused { address = url ?? "" }
        }
    }

    private var bar: some View {
        HStack(spacing: 6) {
            Button {
                model.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .help("Back")
            Button {
                model.goForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .help("Forward")
            Button {
                model.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Reload")
            TextField("Address", text: $address)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Color.textPrimary)
                .focused($addressFocused)
                .onSubmit {
                    model.navigate(to: address)
                    addressFocused = false
                }
            tabMenu
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.textMuted)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .disabled(model.status != .connected)
    }

    /// Every tab in the shared browser. The pane follows the newest on its own; this is for
    /// going somewhere else by hand.
    private var tabMenu: some View {
        Menu {
            ForEach(model.tabs.tabs) { tab in
                Button {
                    model.show(tab: tab.targetId)
                } label: {
                    if tab.targetId == model.tabs.showing {
                        Label(tab.title.isEmpty ? tab.url : tab.title, systemImage: "checkmark")
                    } else {
                        Text(tab.title.isEmpty ? tab.url : tab.title)
                    }
                }
            }
            Divider()
            Button("New Tab") { model.newTab() }
        } label: {
            Text(model.tabs.tabs.count == 1 ? "1 tab" : "\(model.tabs.tabs.count) tabs")
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("The shared browser's tabs")
    }

    @ViewBuilder
    private var notice: some View {
        VStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 22))
                .foregroundStyle(Color.textFaint)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Color.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .textSelection(.enabled)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.surface)
    }

    private var message: String {
        switch model.status {
        case let .waiting(why): why
        case .setup:
            "The shared browser is open in its own window for setup. Quit that window (⌘Q) "
                + "when you are done, and it comes back here."
        case .connecting: "Connecting to the shared browser…"
        case .connected: ""
        }
    }
}

// MARK: - The surface

/// Hosts the pane-owned `BrowserSurfaceView` and keeps the model pointed at it.
struct BrowserSurface: NSViewRepresentable {
    let model: BrowserPaneModel
    let holdsKeyboard: Bool

    func makeNSView(context _: Context) -> BrowserSurfaceView {
        let view = BrowserSurfaceView()
        view.model = model
        model.surface = view
        return view
    }

    func updateNSView(_ view: BrowserSurfaceView, context _: Context) {
        view.model = model
        view.claimsKeyboard = holdsKeyboard
    }
}

/// Where the tab is drawn and where the operator's hands go in.
///
/// A plain layer showing the latest screencast frame, aspect-fit. Input is mapped back from
/// the drawn rectangle to the page's CSS pixels (`BrowserGeometry`). Keys go through AppKit's
/// own text input (`interpretKeyEvents`), so the text a key types — dead keys, ⌥-characters,
/// any layout — is the operator's, and editing keys arrive as the commands his key bindings
/// name (`BrowserEditingCommand`).
final class BrowserSurfaceView: NSView, @preconcurrency NSTextInputClient {
    /// Where input goes: the pane's model, or a recorder in a test.
    weak var model: (any BrowserInputSink)?

    /// helm's intent that this pane own the keyboard. Acted on only on `false → true` and when
    /// the view gains a window — `FocusClaimingTerminalView`'s rule, for its reason: a claim
    /// that ran on every render would steal focus from the address bar.
    var claimsKeyboard = false {
        didSet {
            guard claimsKeyboard, !oldValue else { return }
            claimKeyboard()
        }
    }

    /// The clipboard ⌘C/⌘V use. The general one in the app; a private one in a test, which
    /// must not touch the operator's clipboard.
    var pasteboard: NSPasteboard = .general

    private var currentFrame: BrowserFrame?
    private var markedText = ""
    /// The key being interpreted, while `interpretKeyEvents` runs.
    private var pendingKey: NSEvent?
    private var pendingHandled = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
    }

    required init?(coder _: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func show(_ frame: BrowserFrame) {
        currentFrame = frame
        layer?.contents = frame.image
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        claimKeyboard()
        reportViewport()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reportViewport()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        reportViewport()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                owner: self))
    }

    private func reportViewport() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        model?.viewportChanged(size: bounds.size, scale: window?.backingScaleFactor ?? 2)
    }

    private func claimKeyboard() {
        guard claimsKeyboard, let window, window.firstResponder !== self else { return }
        if !window.makeFirstResponder(self) {
            NSLog(
                "helm: browser pane could not take the keyboard — %@ refused to resign",
                String(describing: window.firstResponder))
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        send(event, type: "mousePressed", button: "left")
    }
    override func mouseUp(with event: NSEvent) {
        send(event, type: "mouseReleased", button: "left")
    }
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        send(event, type: "mousePressed", button: "right")
    }
    override func rightMouseUp(with event: NSEvent) {
        send(event, type: "mouseReleased", button: "right")
    }
    override func mouseDragged(with event: NSEvent) {
        send(event, type: "mouseMoved", button: "left")
    }
    override func mouseMoved(with event: NSEvent) {
        send(event, type: "mouseMoved", button: "none")
    }

    override func scrollWheel(with event: NSEvent) {
        guard let point = pagePoint(event) else { return }
        // DOM wheel deltas are positive when content moves up (scrolling down); AppKit's
        // scrolling deltas are the other sign.
        model?.mouse(
            .init(
                type: "mouseWheel", x: point.x, y: point.y,
                modifiers: Self.modifiers(event.modifierFlags).rawValue,
                deltaX: -event.scrollingDeltaX, deltaY: -event.scrollingDeltaY))
    }

    private func send(_ event: NSEvent, type: String, button: String) {
        guard let point = pagePoint(event) else { return }
        // Which buttons are down *after* this event, as a DOM `buttons` bitmask.
        let held = type == "mouseReleased" ? 0 : (button == "left" ? 1 : button == "right" ? 2 : 0)
        model?.mouse(
            .init(
                type: type, x: point.x, y: point.y, button: button, buttons: held,
                clickCount: type == "mouseMoved" ? 0 : event.clickCount,
                modifiers: Self.modifiers(event.modifierFlags).rawValue))
    }

    private func pagePoint(_ event: NSEvent) -> CGPoint? {
        guard let frame = currentFrame else { return nil }
        return BrowserGeometry.pagePoint(
            convert(event.locationInWindow, from: nil), in: bounds.size,
            image: CGSize(width: frame.image.width, height: frame.image.height),
            page: frame.pageSize)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let modifiers = Self.modifiers(event.modifierFlags)
        if modifiers.contains(.meta) || modifiers.contains(.control) {
            // A ⌘- or ⌃-combination no menu claimed. It types nothing; the page sees the key.
            sendKey(
                event, type: "rawKeyDown", text: nil,
                commands: Self.metaCommand(event, modifiers).map { [$0] })
            return
        }
        pendingKey = event
        pendingHandled = false
        interpretKeyEvents([event])
        // A key AppKit neither typed with nor bound to a command (F5, a bare arrow with no
        // binding) still reaches the page — unless it started a composition.
        if !pendingHandled, markedText.isEmpty {
            sendKey(event, type: "rawKeyDown", text: nil, commands: nil)
        }
        pendingKey = nil
    }

    override func keyUp(with event: NSEvent) {
        sendKey(event, type: "keyUp", text: nil, commands: nil)
    }

    private func sendKey(_ event: NSEvent, type: String, text: String?, commands: [String]?) {
        let key = BrowserKey(
            macKeyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers, text: text)
        model?.key(
            .init(
                type: type, modifiers: Self.modifiers(event.modifierFlags).rawValue, key: key.key,
                code: key.code, windowsVirtualKeyCode: key.windowsVirtualKeyCode,
                nativeVirtualKeyCode: key.nativeVirtualKeyCode, text: text, unmodifiedText: text,
                autoRepeat: type == "keyUp" ? nil : event.isARepeat, commands: commands))
    }

    /// The editing commands ⌘-keys stand for on a Mac, for the ones no menu item takes first.
    private static func metaCommand(_ event: NSEvent, _ modifiers: BrowserModifiers) -> String? {
        guard modifiers.contains(.meta) else { return nil }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a": return "selectAll"
        case "z": return modifiers.contains(.shift) ? "redo" : "undo"
        default: return nil
        }
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> BrowserModifiers {
        var m: BrowserModifiers = []
        if flags.contains(.option) { m.insert(.alt) }
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.command) { m.insert(.meta) }
        if flags.contains(.shift) { m.insert(.shift) }
        return m
    }

    // MARK: Edit menu

    @objc func copy(_: Any?) {
        Task { @MainActor [weak self] in
            guard let self, let text = await model?.selectedText(), !text.isEmpty else { return }
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }

    @objc func cut(_ sender: Any?) {
        copy(sender)
        model?.key(Self.command("deleteBackward", key: "Backspace", code: "Backspace", vk: 8))
    }

    @objc func paste(_: Any?) {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        model?.insertText(text)
    }

    @objc override func selectAll(_: Any?) {
        model?.key(Self.command("selectAll", key: "a", code: "KeyA", vk: 65, meta: true))
    }

    private static func command(
        _ name: String, key: String, code: String, vk: Int, meta: Bool = false
    ) -> BrowserPaneModel.KeyEvent {
        .init(
            type: "rawKeyDown", modifiers: meta ? BrowserModifiers.meta.rawValue : 0, key: key,
            code: code, windowsVirtualKeyCode: vk, nativeVirtualKeyCode: 0, commands: [name])
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange _: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedText = ""
        guard !text.isEmpty else { return }
        if let event = pendingKey, !pendingHandled, text.count == 1 {
            pendingHandled = true
            sendKey(event, type: "keyDown", text: text, commands: nil)
        } else {
            // A composition committing, or several characters from one press.
            pendingHandled = true
            model?.insertText(text)
        }
    }

    override func doCommand(by selector: Selector) {
        guard let event = pendingKey else { return }
        pendingHandled = true
        let command = BrowserEditingCommand.name(forSelector: NSStringFromSelector(selector))
        // Enter types a carriage return, as a browser's own Enter does — forms submit on it.
        let text = BrowserKey.enterText(macKeyCode: event.keyCode)
        sendKey(
            event, type: text == nil ? "rawKeyDown" : "keyDown", text: text,
            commands: command.map { [$0] })
    }

    func setMarkedText(_ string: Any, selectedRange _: NSRange, replacementRange _: NSRange) {
        markedText = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        pendingHandled = true
    }

    func unmarkText() { markedText = "" }
    func hasMarkedText() -> Bool { !markedText.isEmpty }
    func markedRange() -> NSRange {
        markedText.isEmpty
            ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: 0, length: markedText.utf16.count)
    }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(
        forProposedRange _: NSRange, actualRange _: NSRangePointer?
    )
        -> NSAttributedString?
    { nil }
    func characterIndex(for _: NSPoint) -> Int { NSNotFound }
    func firstRect(forCharacterRange _: NSRange, actualRange _: NSRangePointer?) -> NSRect {
        window?.convertToScreen(convert(bounds, to: nil)) ?? .zero
    }
}

/// What the surface sends its input to — the seam `BrowserSurfaceTests` records at, so the
/// whole path from an `NSEvent` to the CDP event is tested without a browser.
@MainActor
protocol BrowserInputSink: AnyObject {
    func mouse(_ params: BrowserPaneModel.MouseEvent)
    func key(_ params: BrowserPaneModel.KeyEvent)
    func insertText(_ text: String)
    func selectedText() async -> String?
    func viewportChanged(size: CGSize, scale: CGFloat)
}

/// Where a point in the pane lands on the page.
enum BrowserGeometry {
    /// The frame is drawn aspect-fit and centred (`contentsGravity = .resizeAspect`); a point
    /// outside the drawn image is outside the page. `view` is in flipped (top-left) points.
    static func pagePoint(
        _ point: CGPoint, in view: CGSize, image: CGSize, page: CGSize
    ) -> CGPoint? {
        guard view.width > 0, view.height > 0, image.width > 0, image.height > 0 else { return nil }
        let scale = min(view.width / image.width, view.height / image.height)
        let drawn = CGSize(width: image.width * scale, height: image.height * scale)
        let origin = CGPoint(x: (view.width - drawn.width) / 2, y: (view.height - drawn.height) / 2)
        let u = (point.x - origin.x) / drawn.width
        let v = (point.y - origin.y) / drawn.height
        guard (0...1).contains(u), (0...1).contains(v) else { return nil }
        return CGPoint(x: u * page.width, y: v * page.height)
    }
}

// MARK: - The tab

/// A browser pane's tab: the page it is showing, so two glances tell the operator where an
/// agent has got to without selecting the pane.
struct BrowserTabLabel: View {
    @ObservedObject var model: BrowserPaneModel
    let name: String?
    let isSelected: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "globe")
                .font(.system(size: 9))
                .foregroundStyle(model.status == .connected ? Color.accent : Color.textMuted)
            Text(name ?? label)
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.textMuted)
            .disabled(!canClose)
            .opacity(canClose ? 1 : 0.3)
            .help(
                canClose
                    ? "Close the pane (the browser keeps running)"
                    : "The last pane cannot be closed")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.selection : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .onTapGesture(perform: onSelect)
    }

    private var label: String {
        guard let tab = model.tabs.current else { return "Browser" }
        if !tab.title.isEmpty { return tab.title }
        return URL(string: tab.url)?.host() ?? tab.url
    }
}
