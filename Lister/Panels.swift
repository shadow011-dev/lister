import SwiftUI

// MARK: - Sidebar (today's captures)

struct SidebarView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        List(selection: $store.selected) {
            ForEach(groups, id: \.self) { g in
            Section {
                ForEach(store.captures.filter { $0.group == g }) { c in
                    CaptureRow(capture: c,
                               selected: store.selected == c.id,
                               marks: store.measByImage[c.id]?.count ?? 0,
                               label: timeLabel(c.url))
                        .tag(c.id)
                        .contextMenu {
                            Button("Show in Finder") { store.reveal(c.url) }
                            Divider()
                            Button(c.external ? "Remove from List" : "Move to Trash", role: .destructive) {
                                store.trash(c.url)
                            }
                        }
                }
            } header: {
                HStack {
                    Text(title(g))
                    Spacer()
                    Text("\(store.captures.filter { $0.group == g }.count)")
                        .contentTransition(.numericText())
                }
            }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(Theme.glass ? .hidden : .automatic)
        .background { if Theme.glass { PanelBackground() } }
        .dropDestination(for: URL.self) { urls, _ in store.openImages(urls) }
        .safeAreaInset(edge: .top, spacing: 0) { brand }
        .overlay {
            if store.captures.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("No captures yet")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Press ⌘R to take one")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
        }
        .animation(Theme.spring, value: store.captures.isEmpty)
    }

    private var brand: some View {
        HStack(spacing: 8) {
            Image("Logo")
                .resizable()
                .interpolation(.high)
                .frame(width: 26, height: 26)
                .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
            Text("Lister")
                .font(.system(size: 15, weight: .bold, design: .rounded))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    /// Section order follows the list (newest first).
    private var groups: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for c in store.captures where !seen.contains(c.group) {
            seen.insert(c.group)
            out.append(c.group)
        }
        return out
    }

    private func title(_ g: String) -> String {
        if g == "Opened" { return "Opened" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: g) else { return g }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        let out = DateFormatter()
        out.dateFormat = "EEE d MMM"
        return out.string(from: d)
    }

    private func timeLabel(_ url: URL) -> String {
        // 20261119_142530.jpg -> 14:25:30
        let name = url.deletingPathExtension().lastPathComponent
        let parts = name.split(separator: "_")
        guard parts.count >= 2, parts[1].count >= 6, parts[0].count == 8 else { return name }
        let t = Array(parts[1])
        return "\(t[0])\(t[1]):\(t[2])\(t[3]):\(t[4])\(t[5])"
    }
}

private struct CaptureRow: View {
    let capture: Capture
    let selected: Bool
    let marks: Int
    let label: String
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let t = capture.thumb {
                    Image(nsImage: t)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 60, height: 45)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(selected ? Theme.accent : Theme.ink.opacity(0.08), lineWidth: selected ? 2 : 1))
            .shadow(color: .black.opacity(0.3), radius: hover ? 5 : 2, y: 1)
            .scaleEffect(hover ? 1.04 : 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 12.5, weight: .semibold, design: capture.external ? .default : .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    if capture.isAdjusted { badge("Adjusted", "slider.horizontal.3") }
                    if capture.isStacked { badge("Stacked", "square.stack.3d.up.fill") }
                    if marks > 0 { badge("\(marks)", "ruler") }
                }
            }
        }
        .padding(.vertical, 2)
        .onHover { h in withAnimation(Theme.quick) { hover = h } }
        .animation(Theme.spring, value: selected)
    }

    private func badge(_ text: String, _ icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8, weight: .bold))
            Text(text).font(.system(size: 9.5, weight: .semibold))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(Theme.ink.opacity(0.1)))
        .foregroundStyle(.secondary)
    }
}

// MARK: - Side panel (Camera | Adjust | Measure)

enum SideTab: String, CaseIterable, Identifiable {
    case camera = "Camera"
    case adjust = "Adjust"
    case measure = "Measure"
    case sample = "Sample"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .camera: return "camera.fill"
        case .adjust: return "slider.horizontal.3"
        case .measure: return "ruler.fill"
        case .sample: return "sparkle.magnifyingglass"
        }
    }
}

struct SidePanel: View {
    @EnvironmentObject var store: Store
    @Namespace private var ns

    private var tab: SideTab { store.sideTab }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
                .padding(12)

            Divider().opacity(0.5)

            ZStack {
                switch tab {
                case .camera:
                    CameraPanel().transition(panelTransition)
                case .adjust:
                    AdjustPanel().transition(panelTransition)
                case .measure:
                    MeasurePanel().transition(panelTransition)
                case .sample:
                    SamplePanel().transition(panelTransition)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PanelBackground())
        .clipped()
        .onChange(of: store.tool) { _, t in
            // Picking a measuring tool brings up the results.
            if t != .pan, tab != .measure { withAnimation(Theme.spring) { store.sideTab = .measure } }
        }
    }

    private var panelTransition: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(x: 22)),
                    removal: .opacity.combined(with: .offset(x: -22)))
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(SideTab.allCases) { t in
                let on = tab == t
                Button {
                    withAnimation(Theme.spring) { store.sideTab = t }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: t.icon).font(.system(size: 10, weight: .bold))
                        Text(t.rawValue)
                            .font(.system(size: 11.5, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(on ? Theme.onAccent : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background {
                        if on {
                            Capsule()
                                .fill(Theme.gradient)
                                .matchedGeometryEffect(id: "tab", in: ns)
                                .shadow(color: Theme.accent.opacity(0.4), radius: 7, y: 2)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(PressStyle())
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.ink.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Theme.ink.opacity(0.06), lineWidth: 1))
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var cam: CameraControl
    @EnvironmentObject var look: Look
    @Environment(\.dismiss) private var dismiss
    @State private var result = ""
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Theme.gradient)
                        .frame(width: 32, height: 32)
                    Image(systemName: "iphone.gen3")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.onAccent)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Phone camera").font(.system(size: 16, weight: .bold))
                    Text("IP Webcam on your phone").font(.caption).foregroundStyle(.secondary)
                }
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    Card(title: "Address", icon: "network") {
                        TextField("http://phone-address:8080", text: $store.phoneURL)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.well))
                        HStack(spacing: 6) {
                            Button("Example") { store.phoneURL = "http://192.168.1.100:8080" }
                            Button("USB (adb)") { store.phoneURL = "http://localhost:8080" }
                            Spacer()
                        }
                        .buttonStyle(PillStyle())
                        HStack(spacing: 8) {
                            Button(testing ? "Testing…" : "Test connection") {
                                testing = true
                                result = ""
                                Task {
                                    result = await store.testConnection()
                                    testing = false
                                }
                            }
                            .buttonStyle(PillStyle(prominent: true))
                            .disabled(testing)
                            Text(result)
                                .font(.caption)
                                .foregroundStyle(result.hasPrefix("Failed") ? Color.orange : Color.secondary)
                                .lineLimit(2)
                                .transition(.opacity)
                        }
                        .animation(Theme.quick, value: result)
                    }

                    Card(title: "Appearance", icon: "paintpalette.fill") {
                        Picker("", selection: Binding(get: { look.dark },
                                                      set: { v in withAnimation(.easeInOut(duration: 0.35)) { look.dark = v } })) {
                            Label("Dark", systemImage: "moon.fill").tag(true)
                            Label("Light", systemImage: "sun.max.fill").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        HStack(spacing: 6) {
                            ForEach(Palette.allCases) { p in
                                swatch(p)
                            }
                        }
                    }

                    LEDSettings()

                    Card(title: "Capture", icon: "camera.fill") {
                        Picker("Photo mode", selection: $store.photoPath) {
                            Text("Photo").tag("/photo.jpg")
                            Text("Autofocus, then photo").tag("/photoaf.jpg")
                        }
                        .pickerStyle(.segmented)
                        Toggle("Use the front camera", isOn: Binding(get: { cam.front }, set: { cam.setFront($0) }))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .font(.system(size: 12.5))
                    }
                }
                .padding(.vertical, 2)
                .frame(width: 436, alignment: .topLeading)
            }
            .frame(width: 436)
            .frame(maxHeight: 560)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(PillStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480)
        .background(Backdrop(dim: 0.2))
        .id(look.key)
    }

    private func swatch(_ p: Palette) -> some View {
        let on = look.palette == p
        return Button {
            withAnimation(.easeInOut(duration: 0.4)) { look.palette = p }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [p.accent(dark: look.dark), p.accent2(dark: look.dark)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 38, height: 38)
                        .overlay(Circle().strokeBorder(Theme.ink.opacity(0.12), lineWidth: 0.5))
                        .shadow(color: p.accent(dark: look.dark).opacity(on ? 0.6 : 0.2), radius: on ? 10 : 4, y: 2)
                    if on {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(p.onAccent(dark: look.dark))
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .overlay(Circle().strokeBorder(on ? Theme.accent : Theme.ink.opacity(0.15), lineWidth: on ? 2 : 1).padding(-4))
                .scaleEffect(on ? 1.06 : 1)
                Text(p.name)
                    .font(.system(size: 11, weight: on ? .bold : .medium))
                    .foregroundStyle(on ? Color.primary : Color.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}
