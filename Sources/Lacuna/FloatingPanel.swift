import AppKit
import SwiftUI

final class PassivePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class SuggestionState: ObservableObject {
    @Published var instruction = ""
    @Published var options: [String] = []
    @Published var selected = 0
    @Published var message = ""
    @Published var loading = false
    var choose: ((Int) -> Void)?
    var dismiss: (() -> Void)?
}

struct SuggestionView: View {
    @ObservedObject var state: SuggestionState
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Text("{ }").font(.system(size: 17, weight: .semibold, design: .monospaced)).foregroundStyle(.indigo)
                Text("Lacuna").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { state.dismiss?() } label: {
                    Text("esc").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }.buttonStyle(.plain).accessibilityLabel("Dismiss suggestions")
            }
            Text(state.instruction).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
            if state.loading {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Finding the words…").font(.system(size: 13))
                }.padding(.vertical, 14)
            } else if !state.message.isEmpty {
                Text(state.message).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(Array(state.options.enumerated()), id: \.offset) { index, option in
                            Button { state.choose?(index) } label: {
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
                            }.buttonStyle(.plain)
                            .accessibilityLabel("Option \(index + 1): \(option)")
                        }
                    }
                }.frame(maxHeight: 330)
                Text("1–3 to insert  ·  ↑↓ to choose  ·  ↵ to accept")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
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
    func show(instruction: String, anchor: CGRect?, loading: Bool = false, options: [String] = [], message: String = "") {
        state.instruction = instruction; state.loading = loading; state.options = options
        state.message = message; state.selected = 0; self.anchor = anchor
        position()
        panel.orderFrontRegardless()
        DispatchQueue.main.async { [weak self] in self?.position() }
    }
    func hide() { panel.orderOut(nil) }
    private func position() {
        guard let view = panel.contentView else { return }
        view.layoutSubtreeIfNeeded()
        let height = min(490, max(125, view.fittingSize.height))
        let converted = anchor.map(Self.appKitRect)
        let screen = NSScreen.screens.first { screen in converted.map { screen.frame.intersects($0) } ?? screen.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1000, height: 800)
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

final class BraceHighlight {
    private let panel: PassivePanel
    init() {
        panel = PassivePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.backgroundColor = .clear; panel.isOpaque = false
        panel.ignoresMouseEvents = true; panel.hasShadow = false; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let view = NSView(); view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.systemIndigo.withAlphaComponent(0.08).cgColor
        view.layer?.borderColor = NSColor.systemIndigo.withAlphaComponent(0.5).cgColor
        view.layer?.borderWidth = 1; view.layer?.cornerRadius = 4
        panel.contentView = view
    }
    func show(_ rect: CGRect) {
        guard rect.width > 0, rect.height > 0, rect.height < 180 else { hide(); return }
        panel.setFrame(FloatingPanel.appKitRect(rect).insetBy(dx: -2, dy: -2), display: true)
        panel.orderFrontRegardless()
    }
    func hide() { panel.orderOut(nil) }
}
