import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var cam: CameraControl
    @EnvironmentObject var adj: AdjustControl
    @EnvironmentObject var look: Look
    @EnvironmentObject var lights: LightController
    @EnvironmentObject var sampler: SampleControl
    @EnvironmentObject var voice: VoiceControl
    @State private var showSettings = false
    @State private var showPanel = true

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .id(look.key)
                .transition(.opacity)
                .navigationSplitViewColumnWidth(min: 170, ideal: 210, max: 280)
        } detail: {
            detail
                .id(look.key)
                .transition(.opacity)
        }
        .sheet(isPresented: $showSettings, onDismiss: {
            Task { await cam.refresh() }
        }) {
            SettingsView()
        }
        .task {
            cam.attach(store)
            adj.attach(store)
            sampler.attach(store, adj)
            voice.attach(store)
            store.lights = lights
            lights.autoConnect()
            await cam.refresh()
        }
    }

    // Rebuilt whenever the theme changes (Theme colours are read while drawing).
    private var detail: some View {
        ViewerView()
            .background(Backdrop())
            .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
            // The right-hand panel lives in the system inspector column. macOS owns its
            // width, so nothing inside the panel can make it grow or shrink while you work.
            .inspector(isPresented: $showPanel) {
                SidePanel()
                    .inspectorColumnWidth(min: 290, ideal: Theme.panelWidth, max: 400)
            }
            .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                liveButton
                LEDButton()
                LEDAutoButton()
                captureButton
                VoiceButton()

                Button {
                    withAnimation(.easeInOut(duration: 0.35)) { look.dark.toggle() }
                } label: {
                    Label(look.dark ? "Light mode" : "Dark mode", systemImage: look.dark ? "sun.max.fill" : "moon.fill")
                }
                .help(look.dark ? "Switch to light mode (⇧⌘D)" : "Switch to dark mode (⇧⌘D)")

                Menu {
                    Button("Open Images…") { store.openPanel() }
                    Button("Open Folder of Images…") { store.openFolderPanel() }
                } label: {
                    Label("Open", systemImage: "photo.on.rectangle.angled")
                }
                .help("Open pictures or a whole folder of pictures in Lister (⌘O, ⇧⌘O)")

                Button { store.openFolder() } label: {
                    Label("Folder", systemImage: "folder")
                }
                .help("Open today's capture folder")

                Button { showSettings = true } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Phone address, capture and appearance settings (⌘,)")
                .keyboardShortcut(",", modifiers: .command)

                Button {
                    withAnimation(Theme.spring) { showPanel.toggle() }
                } label: {
                    Label("Panel", systemImage: "sidebar.right")
                }
                .help(showPanel ? "Hide the side panel (⌥⌘0)" : "Show the side panel (⌥⌘0)")
                .keyboardShortcut("0", modifiers: [.command, .option])
            }
        }
    }

    // MARK: Toolbar

    private var liveButton: some View {
        Button {
            withAnimation(Theme.spring) { store.live.toggle() }
        } label: {
            HStack(spacing: 6) {
                LiveDot(active: store.live)
                Text("Live").font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(Capsule().fill(store.live ? Color.red.opacity(0.2) : Theme.ink.opacity(0.07)))
            .overlay(Capsule().strokeBorder(store.live ? Color.red.opacity(0.55) : Theme.ink.opacity(0.08), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .help("Live view from the phone (⌘L)")
        .animation(Theme.spring, value: store.live)
    }

    private var captureButton: some View {
        Button {
            Task { await store.capture() }
        } label: {
            HStack(spacing: 6) {
                if store.busy {
                    ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                } else {
                    Image(systemName: "camera.fill").font(.system(size: 11, weight: .bold))
                }
                Text(store.busy ? "Capturing" : "Capture").font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(Theme.onAccent)
            .frame(width: 106, height: 26)
            .background(Capsule().fill(Theme.gradient))
            .overlay(Capsule().strokeBorder(Theme.ink.opacity(0.2), lineWidth: 1))
            .shadow(color: Theme.accent.opacity(0.45), radius: 6, y: 2)
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .disabled(store.busy)
        .help("Take a full-resolution photo (⌘R)")
        .animation(Theme.spring, value: store.busy)
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack(spacing: 10) {
            if store.busy { ProgressView().controlSize(.small) }
            if voice.listening {
                chip(voice.heard.isEmpty ? "Say “capture”" : "Heard: \(voice.heard)", "mic.fill")
            }
            if store.lapseOn {
                chip("Time-lapse \(store.lapseDone)/\(Int(store.lapseTotal))", "timer")
            }
            Text(store.status)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .contentTransition(.opacity)
                .animation(Theme.quick, value: store.status)
            Spacer()
            if !store.imageInfo.isEmpty {
                chip(store.imageInfo, "aspectratio")
            }
            chip(store.umPerPixel > 0
                 ? (store.activePreset?.name ?? String(format: "%.4f µm/px", store.umPerPixel))
                 : "px (no scale)",
                 "ruler")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.glass ? AnyShapeStyle(Material.ultraThinMaterial) : AnyShapeStyle(Material.bar))
    }

    private func chip(_ text: String, _ icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold))
            Text(text).font(.system(size: 10.5, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(Theme.ink.opacity(0.06)))
    }
}
