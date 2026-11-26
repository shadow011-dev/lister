import SwiftUI
import AppKit

// MARK: - Look and motion
//
// One place for Lister's colours, card style, buttons and the custom slider,
// so every panel looks and moves the same way.

/// The five colour themes you can pick in Settings.
enum Palette: String, CaseIterable, Identifiable {
    case scarlet, white, ocean, aurora, emerald, gold
    var id: String { rawValue }

    var name: String {
        switch self {
        case .scarlet: return "Crimson"
        case .white: return "White"
        case .ocean: return "Ocean"
        case .aurora: return "Aurora"
        case .emerald: return "Emerald"
        case .gold: return "Gold"
        }
    }

    /// The theme colour as picked for dark mode.
    var baseAccent: Color {
        switch self {
        case .white: return Color(white: 0.96)
        case .scarlet: return Color(red: 0.659, green: 0.133, blue: 0.098)   // #A82219, from your reference picture
        case .ocean: return Color(red: 0.20, green: 0.56, blue: 1.00)
        case .aurora: return Color(red: 0.62, green: 0.40, blue: 1.00)
        case .emerald: return Color(red: 0.13, green: 0.74, blue: 0.52)
        case .gold: return Color(red: 0.96, green: 0.62, blue: 0.14)
        }
    }

    var baseAccent2: Color {
        switch self {
        case .white: return Color(white: 0.76)
        case .scarlet: return Color(red: 0.612, green: 0.129, blue: 0.106)   // #9C211B
        case .ocean: return Color(red: 0.22, green: 0.84, blue: 0.95)
        case .aurora: return Color(red: 1.00, green: 0.42, blue: 0.78)
        case .emerald: return Color(red: 0.52, green: 0.90, blue: 0.42)
        case .gold: return Color(red: 0.94, green: 0.40, blue: 0.16)
        }
    }

    /// Three soft colours floating behind the glass.
    var glow: [Color] {
        switch self {
        case .white: return [Color(white: 0.9), Color(white: 0.7), Color(white: 0.5)]
        case .scarlet: return [Color(red: 0.66, green: 0.13, blue: 0.10), Color(red: 0.55, green: 0.11, blue: 0.08),
                             Color(red: 0.62, green: 0.18, blue: 0.55)]
        case .ocean: return [Color(red: 0.10, green: 0.40, blue: 0.95), Color(red: 0.10, green: 0.80, blue: 0.90),
                             Color(red: 0.30, green: 0.20, blue: 0.80)]
        case .aurora: return [Color(red: 0.55, green: 0.25, blue: 0.95), Color(red: 0.95, green: 0.30, blue: 0.70),
                              Color(red: 0.20, green: 0.45, blue: 0.95)]
        case .emerald: return [Color(red: 0.05, green: 0.65, blue: 0.45), Color(red: 0.45, green: 0.85, blue: 0.30),
                               Color(red: 0.05, green: 0.45, blue: 0.60)]
        case .gold: return [Color(red: 0.95, green: 0.60, blue: 0.10), Color(red: 0.90, green: 0.30, blue: 0.15),
                            Color(red: 0.75, green: 0.45, blue: 0.10)]
        }
    }
}

extension Palette {
    /// In light mode every theme is darkened so it reads well on white; White turns black.
    func accent(dark: Bool) -> Color {
        if self == .white { return dark ? baseAccent : Color(white: 0.08) }
        return dark ? baseAccent : Palette.shade(baseAccent, 0.72)
    }

    func accent2(dark: Bool) -> Color {
        if self == .white { return dark ? baseAccent2 : Color(white: 0.30) }
        return dark ? baseAccent2 : Palette.shade(baseAccent2, 0.72)
    }

    /// Text and icons on top of the theme colour.
    func onAccent(dark: Bool) -> Color { self == .white && dark ? .black : .white }

    static func shade(_ c: Color, _ k: Double) -> Color {
        guard let n = NSColor(c).usingColorSpace(.sRGB) else { return c }
        return Color(red: Double(n.redComponent) * k, green: Double(n.greenComponent) * k,
                     blue: Double(n.blueComponent) * k)
    }
}

/// Holds the chosen theme. Views are rebuilt when it changes (see ContentView).
final class Look: ObservableObject {
    @Published var palette: Palette = Theme.palette {
        didSet {
            Theme.palette = palette
            UserDefaults.standard.set(palette.rawValue, forKey: "palette")
        }
    }
    @Published var dark: Bool = Theme.dark {
        didSet {
            Theme.dark = dark
            UserDefaults.standard.set(dark, forKey: "darkMode")
        }
    }

    /// Changes whenever the look changes.
    var key: String { palette.rawValue + (dark ? "-dark" : "-light") }
}

enum Theme {
    static var palette: Palette = Palette(rawValue: UserDefaults.standard.string(forKey: "palette") ?? "") ?? .scarlet
    /// Gradient glass is switched off (v007). The code paths stay so it can come back later.
    static let glass = false

    static var dark: Bool = UserDefaults.standard.object(forKey: "darkMode") as? Bool ?? true

    static var accent: Color { palette.accent(dark: dark) }
    static var accent2: Color { palette.accent2(dark: dark) }
    /// Text/icons on the accent colour.
    static var onAccent: Color { palette.onAccent(dark: dark) }
    /// White on dark, black on light: used for faint fills and lines.
    static var ink: Color { dark ? .white : .black }
    /// Sunken background for text fields, histograms and plots.
    static var well: Color { dark ? Color.black.opacity(0.28) : Color.black.opacity(0.065) }
    /// Raised surface for buttons/tiles that sit on the panel (white tiles in light mode).
    static func raised(hover: Bool = false) -> Color {
        dark ? Color.white.opacity(hover ? 0.09 : 0.055) : Color.white.opacity(hover ? 0.75 : 1)
    }
    /// Thin outline; a little stronger in light mode so white shapes stay visible.
    static func line(_ darkOpacity: Double = 0.07) -> Color {
        dark ? Color.white.opacity(darkOpacity) : Color.black.opacity(max(darkOpacity, 0.1))
    }
    static var window: Color { dark ? Color(white: 0.09) : Color(white: 0.93) }
    static var panel: Color { dark ? Color(white: 0.11) : Color(white: 0.955) }
    static let mark = Color(red: 1.00, green: 0.84, blue: 0.30)
    static let markSelected = Color(red: 0.38, green: 0.86, blue: 1.00)

    static var gradient: LinearGradient {
        LinearGradient(colors: [accent, accent2], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var card: Color { dark ? Theme.ink.opacity(0.045) : Color.white }
    static var stroke: Color { ink.opacity(dark ? 0.07 : 0.08) }

    /// Glass edge: bright at the top, fading out at the bottom.
    static var edge: LinearGradient {
        LinearGradient(colors: dark ? [Theme.ink.opacity(0.08), Theme.ink.opacity(0.05)]
                                    : [Color.black.opacity(0.07), Color.black.opacity(0.10)],
                       startPoint: .top, endPoint: .bottom)
    }

    /// Width of the right-hand panel. Its content is laid out at exactly this width,
    /// so a long label can never push the panel wider (that was the v008 jitter).
    static let panelWidth: CGFloat = 304

    static let spring = Animation.spring(response: 0.38, dampingFraction: 0.82)
    static let bouncy = Animation.spring(response: 0.28, dampingFraction: 0.62)
    static let quick = Animation.easeOut(duration: 0.18)
}

// MARK: - Glass backdrop
//
// Soft blobs of the theme colours drifting slowly behind frosted panels.
// With glass off it is a plain dark background.

struct Backdrop: View {
    var dim: Double = 0
    @State private var drift = false

    var body: some View {
        if Theme.glass {
            GeometryReader { g in
                let w = g.size.width, h = g.size.height
                let c = Theme.palette.glow
                ZStack {
                    Color(red: 0.04, green: 0.04, blue: 0.06)
                    Circle().fill(c[0]).frame(width: w * 0.7, height: w * 0.7)
                        .offset(x: drift ? -w * 0.25 : -w * 0.1, y: drift ? -h * 0.2 : -h * 0.35)
                    Circle().fill(c[1]).frame(width: w * 0.55, height: w * 0.55)
                        .offset(x: drift ? w * 0.3 : w * 0.15, y: drift ? h * 0.25 : h * 0.05)
                    Circle().fill(c[2]).frame(width: w * 0.6, height: w * 0.6)
                        .offset(x: drift ? w * 0.05 : w * 0.25, y: drift ? h * 0.45 : h * 0.3)
                }
                .frame(width: w, height: h)
                .blur(radius: 90)
                .opacity(0.55)
                .overlay(Color.black.opacity(0.25 + dim))
                .clipped()
            }
            .ignoresSafeArea()
            .onAppear {
                withAnimation(.easeInOut(duration: 14).repeatForever(autoreverses: true)) { drift = true }
            }
        } else {
            Theme.window.ignoresSafeArea()
        }
    }
}

/// Panel background: frosted glass over the backdrop, or solid.
struct PanelBackground: View {
    var body: some View {
        if Theme.glass {
            Rectangle().fill(.ultraThinMaterial).opacity(0.85)
        } else {
            Theme.panel
        }
    }
}

// MARK: - Panel scrolling
//
// The real cause of the side-panel flicker: a vertical ScrollView on macOS may lay
// its content out at the content's *natural* width (the longest sentence on one
// line) instead of the panel width. The content then spilled past the edge and its
// width changed with every redraw. Here the visible width is measured first and the
// content is pinned to exactly that width, so it can only wrap, never widen.

struct PanelScroll<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { g in
            ScrollView(.vertical, showsIndicators: false) {
                content
                    .padding(padding)
                    .frame(width: max(g.size.width, 1), alignment: .topLeading)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
    }
}

// MARK: - Card

struct Card<Content: View>: View {
    var title: String? = nil
    var icon: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                HStack(spacing: 6) {
                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(Theme.accent)
                    }
                    Text(title.uppercased())
                        .font(.system(size: 10.5, weight: .semibold))
                        .tracking(0.9)
                        .foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card)
            .shadow(color: .black.opacity(Theme.dark ? 0 : 0.05), radius: Theme.dark ? 0 : 3, y: Theme.dark ? 0 : 1))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.edge, lineWidth: 1))
    }
}

// MARK: - Buttons

/// Gentle shrink when pressed.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(Theme.bouncy, value: configuration.isPressed)
    }
}

/// Capsule button. `prominent` fills it with the accent gradient.
struct PillStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .foregroundStyle(prominent ? Theme.onAccent : Color.primary)
            .background(
                Capsule().fill(prominent
                               ? AnyShapeStyle(Theme.gradient)
                               : AnyShapeStyle(Theme.ink.opacity(configuration.isPressed ? 0.15 : 0.08)))
            )
            .overlay(Capsule().strokeBorder(prominent ? Theme.ink.opacity(0.18) : Theme.line(0.07), lineWidth: 1))
            .shadow(color: prominent && enabled ? Theme.accent.opacity(0.35) : .clear,
                    radius: prominent && enabled ? 8 : 0, y: prominent && enabled ? 3 : 0)
            .opacity(enabled ? 1 : 0.38)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(Theme.bouncy, value: configuration.isPressed)
            .animation(Theme.quick, value: enabled)
    }
}

/// Big square toggle used for Light, Focus lock, Night, Invert…
struct Tile: View {
    let title: String
    let icon: String
    let on: Bool
    var height: CGFloat = 64
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .symbolEffect(.bounce, value: on)
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .foregroundStyle(on ? Theme.onAccent : Color.primary.opacity(0.85))
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(on ? AnyShapeStyle(Theme.gradient)
                             : AnyShapeStyle(Theme.raised(hover: hover)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(on ? Theme.ink.opacity(0.2) : Theme.line(0.06), lineWidth: 1)
            )
            .shadow(color: on ? Theme.accent.opacity(0.4) : .clear, radius: on ? 10 : 0, y: on ? 4 : 0)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressStyle())
        .onHover { h in withAnimation(Theme.quick) { hover = h } }
        .animation(Theme.spring, value: on)
    }
}

// MARK: - Slider
//
// A custom slider: the system one is tiny and grey on macOS. Click anywhere on
// the track to jump there (with a spring), drag for fine control.

struct LSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    /// Where the coloured fill starts from (e.g. 0 for an exposure slider that goes -4…+4).
    var origin: Double? = nil

    @Environment(\.isEnabled) private var enabled
    @State private var dragging = false
    @State private var hovering = false

    private let thumb: CGFloat = 18

    private func fraction(_ v: Double) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0, v.isFinite else { return 0 }
        return CGFloat((min(max(v, range.lowerBound), range.upperBound) - range.lowerBound) / span)
    }

    var body: some View {
        GeometryReader { g in
            let w = max(g.size.width - thumb, 1)
            let x = thumb / 2 + fraction(value) * w
            let o = thumb / 2 + fraction(origin ?? range.lowerBound) * w
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.ink.opacity((hovering || dragging ? 0.12 : 0.08) + (Theme.dark ? 0 : 0.04)))
                    .frame(height: 5)
                Capsule()
                    .fill(Theme.gradient)
                    .frame(width: max(abs(x - o), 0), height: 5)
                    .offset(x: min(x, o))
                Circle()
                    .fill(Color.white)
                    .frame(width: thumb, height: thumb)
                    .overlay(Circle().strokeBorder(Color.black.opacity(Theme.dark ? 0 : 0.2), lineWidth: Theme.dark ? 0 : 1))
                    .shadow(color: .black.opacity(Theme.dark ? 0.3 : 0.35), radius: Theme.dark ? 2 : 3, y: 1)
                    .overlay(Circle().strokeBorder(Theme.accent.opacity(dragging ? 0.9 : 0), lineWidth: 2))
                    .scaleEffect(dragging ? 1.18 : (hovering ? 1.06 : 1))
                    .offset(x: x - thumb / 2)
            }
            .frame(width: g.size.width, height: g.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        guard enabled else { return }
                        if !dragging { dragging = true }
                        let f = min(max((v.location.x - thumb / 2) / w, 0), 1)
                        var nv = range.lowerBound + Double(f) * (range.upperBound - range.lowerBound)
                        if let s = step, s > 0 { nv = (nv / s).rounded() * s }
                        nv = min(max(nv, range.lowerBound), range.upperBound)
                        if nv != value { value = nv }
                    }
                    .onEnded { _ in dragging = false }
            )
        }
        .frame(height: 22)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 }
        .animation(Theme.bouncy, value: dragging)
        .animation(Theme.quick, value: hovering)
    }
}

/// Title, value on the right, slider underneath.
struct SliderRow: View {
    let title: String
    let value: String
    @Binding var v: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    var origin: Double? = nil
    var note: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let note {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text(value)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            LSlider(value: $v, range: range, step: step, origin: origin)
        }
    }
}

// MARK: - Small pieces

/// A dot that breathes while active (used for LIVE).
struct LiveDot: View {
    let active: Bool
    var size: CGFloat = 7

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Circle()
                .fill(active ? Color.red : Color.secondary)
                .frame(width: size, height: size)
                .opacity(active ? 0.55 + 0.45 * cos(t * 4) : 1)
                .shadow(color: active ? .red.opacity(0.7) : .clear, radius: 4)
        }
    }
}

/// Banner that drops in over the image for a couple of seconds.
struct Toast: Equatable {
    let id = UUID()
    let text: String
    let icon: String
    var isError = false
}

struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(toast.isError ? Color.orange : Theme.accent2)
            Text(toast.text)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.ink.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }
}

/// A row that slides its content open with a turning chevron.
struct Reveal<Content: View>: View {
    let title: String
    @Binding var open: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(Theme.spring) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text(title).font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                VStack(alignment: .leading, spacing: 14) { content }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

/// Picker row with the label on the left and a compact menu on the right.
struct MenuRow: View {
    let title: String
    let options: [String]
    let selection: String
    var label: (String) -> String = { $0.capitalized }
    let onPick: (String) -> Void

    var body: some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .medium))
            Spacer()
            Menu {
                ForEach(options, id: \.self) { o in
                    Button {
                        onPick(o)
                    } label: {
                        if o == selection { Label(label(o), systemImage: "checkmark") } else { Text(label(o)) }
                    }
                }
            } label: {
                Text(selection.isEmpty ? "—" : label(selection))
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}
