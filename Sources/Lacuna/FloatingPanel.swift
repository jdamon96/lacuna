import AppKit
import SwiftUI
import LacunaCore

final class PassivePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class SuggestionState: ObservableObject {
    @Published var instruction = ""
    @Published var phraseNumber = 0
    @Published var phraseCount = 0
    @Published var options: [String] = []
    @Published var selected = 0
    @Published var message = ""
    @Published var loading = false
    @Published var isInserting = false
    @Published var canInsert = true
    @Published var maximumPanelHeight: CGFloat = 490
    var choose: ((Int) -> Void)?
    var dismiss: (() -> Void)?
    var copySelected: (() -> Void)?
    var regenerate: (() -> Void)?
    var navigate: ((_ direction: Int, _ jump: Bool) -> Void)?
}

private struct SuggestionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        // An option remains readable and copyable even when insertion is disabled.
        configuration.label.opacity(configuration.isPressed ? 0.8 : 1)
    }
}

private struct SuggestionRow: View {
    @ObservedObject var state: SuggestionState
    let index: Int
    let option: String
    let width: CGFloat

    var body: some View {
        Button {
            guard !state.isInserting else { return }
            if state.canInsert { state.choose?(index) }
            else { state.selected = index }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Text("\(index + 1)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .frame(width: 22, height: 22)
                    .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                Text(option).font(.system(size: 14)).lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(11).contentShape(Rectangle())
            .background(index == state.selected ? Color.indigo.opacity(0.11) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(index == state.selected ? Color.indigo.opacity(0.25) : .clear, lineWidth: 1))
        }.buttonStyle(SuggestionButtonStyle())
        .disabled(state.isInserting)
        .accessibilityLabel("Option \(index + 1): \(option)")
        .frame(width: width)
    }
}

private final class SuggestionDocument: NSView {
    override var isFlipped: Bool { true }
}

/// Own the scroll view so keyboard events can scroll it without making the panel
/// key or moving the insertion point out of the user's editor.
final class SuggestionScrollView: NSScrollView {
    private let document = SuggestionDocument()
    private var rows: [NSHostingView<SuggestionRow>] = []
    private var options: [String] = []
    private var state: SuggestionState?
    private var rowWidth: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        scrollerStyle = .overlay
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .none
        documentView = document
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(state: SuggestionState) {
        self.state = state
        state.navigate = { [weak self] direction, jump in self?.navigate(direction: direction, jump: jump) }
        guard options != state.options else { return }
        options = state.options
        rows.forEach { $0.removeFromSuperview() }
        rows = options.enumerated().map { index, option in
            let row = NSHostingView(rootView: SuggestionRow(state: state, index: index, option: option, width: max(1, contentSize.width)))
            document.addSubview(row)
            return row
        }
        rowWidth = 0
        needsLayout = true
        layoutSubtreeIfNeeded()
        contentView.scroll(to: .zero)
        reflectScrolledClipView(contentView)
    }

    override func layout() {
        super.layout()
        layoutRows(width: max(1, contentSize.width))
    }

    func fittingHeight(for width: CGFloat) -> CGFloat {
        layoutRows(width: width)
        return min(330, document.frame.height)
    }

    private func layoutRows(width: CGFloat) {
        guard let state else { return }
        guard width != rowWidth else { return }
        rowWidth = width
        var y: CGFloat = 0
        for (index, row) in rows.enumerated() {
            row.rootView = SuggestionRow(state: state, index: index, option: options[index], width: width)
            let height = ceil(row.fittingSize.height)
            row.frame = NSRect(x: 0, y: y, width: width, height: height)
            y += height + 6
        }
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(0, y - 6))
    }

    func navigate(direction: Int, jump: Bool = false) {
        layoutSubtreeIfNeeded()
        guard let state else { return }
        let position = SuggestionNavigation.move(
            selected: state.selected, offset: contentView.bounds.minY,
            viewportHeight: contentView.bounds.height,
            rows: rows.map { Double($0.frame.minY)...Double($0.frame.maxY) },
            direction: direction, jump: jump)
        state.selected = position.selected
        contentView.scroll(to: NSPoint(x: 0, y: position.offset))
        reflectScrolledClipView(contentView)
    }
}

private struct SuggestionList: NSViewRepresentable {
    @ObservedObject var state: SuggestionState

    func makeNSView(context: Context) -> SuggestionScrollView {
        let scroll = SuggestionScrollView(frame: .zero)
        scroll.update(state: state)
        return scroll
    }
    func updateNSView(_ scroll: SuggestionScrollView, context: Context) {
        scroll.update(state: state)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SuggestionScrollView, context: Context) -> NSSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 398
        let maximumHeight = proposal.height.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 330
        return NSSize(width: width, height: min(maximumHeight, nsView.fittingHeight(for: max(1, width))))
    }
}

struct SuggestionView: View {
    @ObservedObject var state: SuggestionState

    private var suggestionHeight: CGFloat {
        // Reserve enough room for the entire insertion status and its copy action.
        // The list compresses instead of pushing its keyboard footer off-screen.
        let instruction = min(32, textHeight(state.instruction))
        let status = state.message.isEmpty ? 0 : textHeight(state.message) + 44
        let chrome = 20 + instruction + 32 + 36 + (state.isInserting ? 17 : 14)
        return min(330, max(60, state.maximumPanelHeight - chrome - status))
    }

    private func textHeight(_ text: String) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return ceil((text as NSString).boundingRect(
            with: NSSize(width: 398, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 13)]).height)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Text("{ }").font(.system(size: 17, weight: .semibold, design: .monospaced)).foregroundStyle(.indigo)
                Text("Lacuna").font(.system(size: 14, weight: .semibold))
                if state.phraseCount > 1 {
                    Text("Phrase \(state.phraseNumber) of \(state.phraseCount)")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { state.dismiss?() } label: {
                    Text("esc").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }.buttonStyle(.plain).accessibilityLabel("Dismiss suggestions")
            }
            Text(state.instruction).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
            if state.loading && state.options.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Finding the words…").font(.system(size: 13))
                }.padding(.vertical, 14)
            }
            if !state.options.isEmpty {
                if !state.message.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(state.message).font(.system(size: 13))
                            .fixedSize(horizontal: false, vertical: true)
                        Button { state.copySelected?() } label: {
                            HStack(spacing: 8) {
                                Text("Copy selected")
                                Text("⌘C").foregroundStyle(.secondary)
                            }
                        }.controlSize(.small).disabled(state.isInserting)
                    }
                }
                // Keep this view in place while status changes so AppKit retains
                // its document, selected option, and current reading position.
                SuggestionList(state: state).frame(maxHeight: suggestionHeight)
                HStack(spacing: 8) {
                    if state.isInserting {
                        ProgressView().controlSize(.mini)
                        Text("Inserting…")
                    } else {
                        Text(state.canInsert
                             ? "1–3 insert  ·  ↑↓ read  ·  tab next  ·  ↵ accept"
                             : "↑↓ read  ·  ⌘C copy  ·  esc dismiss")
                    }
                    Spacer(minLength: 0)
                    Button { state.regenerate?() } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.clockwise")
                            Text("⌘R")
                        }
                    }.buttonStyle(.plain).disabled(state.isInserting)
                        .help("New suggestions (⌘R)")
                        .accessibilityLabel("New suggestions")
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            } else if !state.message.isEmpty {
                Text(state.message).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).padding(.vertical, 8)
            }
        }
        .padding(16).frame(width: 430, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(.primary.opacity(0.12), lineWidth: 1))
    }
}

final class FloatingPanel {
    let state = SuggestionState()
    private let panel: PassivePanel
    private var anchor: CGRect?
    var isVisible: Bool { panel.isVisible }

    init() {
        panel = PassivePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true; panel.level = .popUpMenu
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: SuggestionView(state: state))
    }
    func show(instruction: String, anchor: CGRect?, loading: Bool = false, options: [String] = [], message: String = "",
              phraseNumber: Int = 0, phraseCount: Int = 0) {
        state.instruction = instruction; state.loading = loading; state.options = options
        state.phraseNumber = phraseNumber; state.phraseCount = phraseCount
        state.message = message; state.selected = 0; state.isInserting = false; state.canInsert = true
        self.anchor = anchor
        refreshLayout()
        panel.orderFrontRegardless()
    }
    func setInserting(_ inserting: Bool) {
        state.isInserting = inserting
        refreshLayout()
    }
    func showInsertionError(_ message: String, canInsert: Bool) {
        state.message = message; state.canInsert = canInsert; state.isInserting = false
        refreshLayout()
        panel.orderFrontRegardless()
    }
    func hide() { panel.orderOut(nil) }
    func reanchor(_ anchor: CGRect?) {
        guard self.anchor != anchor else { return }
        self.anchor = anchor
        position()
    }
    private func refreshLayout() {
        position()
        DispatchQueue.main.async { [weak self] in self?.position() }
    }
    private func position() {
        guard let view = panel.contentView else { return }
        let converted = anchor.map(Self.appKitRect)
        let screen = NSScreen.screens.first { screen in converted.map { screen.frame.intersects($0) } ?? screen.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1000, height: 800)
        let maximumHeight = min(490, max(125, visible.height - 24))
        if state.maximumPanelHeight != maximumHeight { state.maximumPanelHeight = maximumHeight }
        view.layoutSubtreeIfNeeded()
        let height = min(maximumHeight, max(125, view.fittingSize.height))
        let rect = converted ?? CGRect(x: visible.midX - 215, y: visible.midY + 130, width: 1, height: 20)
        let x = min(max(visible.minX + 12, rect.minX), visible.maxX - 442)
        var y = rect.minY - height - 8
        if y < visible.minY + 12 { y = min(rect.maxY + 8, visible.maxY - height - 12) }
        y = max(visible.minY + 12, y)
        panel.setFrame(CGRect(x: x, y: y, width: 430, height: height), display: true)
    }
    static func appKitRect(_ ax: CGRect) -> CGRect {
        // AX uses the top-left of the main display; AppKit uses its bottom-left.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: ax.minX, y: primaryHeight - ax.maxY, width: ax.width, height: ax.height)
    }
}

private final class BraceHighlightView: NSView {
    struct Fragment {
        let frame: CGRect
        let style: BraceHighlight.Style
    }
    var fragments: [Fragment] = []
    var fieldFrame: CGRect?
    var badgeFrame: CGRect?
    var badgeTitle = ""

    static let badgeAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11, weight: .medium),
        .foregroundColor: NSColor.labelColor
    ]

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let fieldFrame {
            let path = NSBezierPath(roundedRect: fieldFrame.insetBy(dx: 0.75, dy: 0.75), xRadius: 6, yRadius: 6)
            NSColor.systemIndigo.withAlphaComponent(0.45).setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
        for fragment in fragments {
            let rect = fragment.frame
            switch fragment.style {
            case .opening:
                NSColor.systemIndigo.withAlphaComponent(0.8).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
            case .complete, .active:
                let active = fragment.style == .active
                let lineWidth: CGFloat = active ? 1.5 : 1
                let path = NSBezierPath(roundedRect: rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2), xRadius: 4, yRadius: 4)
                NSColor.systemIndigo.withAlphaComponent(active ? 0.14 : 0.08).setFill()
                path.fill()
                NSColor.systemIndigo.withAlphaComponent(active ? 0.85 : 0.5).setStroke()
                path.lineWidth = lineWidth
                path.stroke()
            }
        }
        if let badgeFrame {
            NSColor.windowBackgroundColor.withAlphaComponent(0.97).setFill()
            let path = NSBezierPath(roundedRect: badgeFrame, xRadius: 5, yRadius: 5)
            path.fill()
            NSColor.systemIndigo.withAlphaComponent(0.55).setStroke()
            path.lineWidth = 1
            path.stroke()
            (badgeTitle as NSString).draw(at: CGPoint(x: badgeFrame.minX + 7, y: badgeFrame.minY + 4),
                                         withAttributes: Self.badgeAttributes)
        }
    }
}

final class BraceHighlight {
    enum Style { case opening, complete, active }
    struct Region {
        let rects: [CGRect]
        let style: Style
    }
    struct FieldIndicator {
        let frame: CGRect
        let title: String
    }
    private let panel: PassivePanel
    private let view = BraceHighlightView()
    init() {
        panel = PassivePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.backgroundColor = .clear; panel.isOpaque = false
        panel.ignoresMouseEvents = true; panel.hasShadow = false; panel.hidesOnDeactivate = false
        // A caret move may hide and reopen this window in the same display
        // cycle. AppKit's default order animation can leave that cue fading out.
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = view
    }
    func show(_ rects: [CGRect], style: Style = .complete) {
        show(regions: [Region(rects: rects, style: style)])
    }
    func show(regions: [Region], fieldIndicator: FieldIndicator? = nil) {
        let fragments = regions.flatMap { region in region.rects.compactMap { rect -> BraceHighlightView.Fragment? in
            guard rect.origin.x.isFinite, rect.origin.y.isFinite,
                  rect.width.isFinite, rect.height.isFinite,
                  rect.width > 0, rect.height > 0, rect.height < 180 else { return nil }
            let frame = FloatingPanel.appKitRect(rect)
            let contour: CGRect
            switch region.style {
            case .opening:
                // A quiet underline acknowledges an unfinished expression.
                contour = CGRect(x: frame.minX - 1, y: frame.minY - 2,
                                 width: max(7, frame.width + 2), height: 2)
            case .complete, .active:
                contour = frame.insetBy(dx: -2, dy: -2)
            }
            return BraceHighlightView.Fragment(frame: contour, style: region.style)
        } }
        var fieldFrame: CGRect?
        var badgeFrame: CGRect?
        if let indicator = fieldIndicator {
            let frame = indicator.frame
            if frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite,
               frame.width > 0, frame.height > 0 {
                let converted = FloatingPanel.appKitRect(frame)
                fieldFrame = converted.insetBy(dx: -2, dy: -2)
                let size = (indicator.title as NSString).size(withAttributes: BraceHighlightView.badgeAttributes)
                // Attach a separate field-level cue above the field; don't draw
                // a guessed text highlight when the editor exposes no glyph bounds.
                let visible = NSScreen.screens.first(where: { $0.frame.intersects(converted) })?.visibleFrame
                badgeFrame = Self.fieldBadgeFrame(for: converted,
                                                 size: CGSize(width: ceil(size.width) + 14, height: ceil(size.height) + 8),
                                                 visibleFrame: visible)
            }
        }
        let frames = fragments.map(\.frame) + [fieldFrame, badgeFrame].compactMap { $0 }
        guard let first = frames.first else { hide(); return }
        let bounds = frames.dropFirst().reduce(first) { $0.union($1) }
        panel.setFrame(bounds, display: false)
        // One passive window draws all phrases, each with its own style. Gaps
        // between words, lines, and separate expressions stay transparent.
        view.fragments = fragments.map {
            BraceHighlightView.Fragment(frame: $0.frame.offsetBy(dx: -bounds.minX, dy: -bounds.minY), style: $0.style)
        }
        view.fieldFrame = fieldFrame?.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
        view.badgeFrame = badgeFrame?.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
        view.badgeTitle = fieldIndicator?.title ?? ""
        view.needsDisplay = true
        panel.orderFrontRegardless()
    }
    static func fieldBadgeFrame(for field: CGRect, size: CGSize, visibleFrame: CGRect?) -> CGRect {
        var badge = CGRect(x: field.minX, y: field.maxY + 5, width: size.width, height: size.height)
        guard let visibleFrame else { return badge }
        if badge.maxY > visibleFrame.maxY { badge.origin.y = field.minY - badge.height - 5 }
        badge.origin.x = max(visibleFrame.minX, min(badge.minX, visibleFrame.maxX - badge.width))
        badge.origin.y = max(visibleFrame.minY, min(badge.minY, visibleFrame.maxY - badge.height))
        return badge
    }
    func hide() { panel.orderOut(nil) }
}
