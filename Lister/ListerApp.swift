import SwiftUI

@main
struct ListerApp: App {
    @StateObject private var store = Store()
    @StateObject private var cam = CameraControl()
    @StateObject private var adj = AdjustControl()
    @StateObject private var look = Look()
    @StateObject private var lights = LightController()
    @StateObject private var sampler = SampleControl()
    @StateObject private var voice = VoiceControl()

    var body: some Scene {
        WindowGroup("Lister") {
            ContentView()
                .environmentObject(store)
                .environmentObject(cam)
                .environmentObject(adj)
                .environmentObject(look)
                .environmentObject(lights)
                .environmentObject(sampler)
                .environmentObject(voice)
                .frame(minWidth: 1100, minHeight: 680)
                .preferredColorScheme(look.dark ? .dark : .light)
                .tint(Theme.accent)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Image…") { store.openPanel() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Open Folder of Images…") { store.openFolderPanel() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }

            CommandMenu("Image") {
                Button("Capture") { Task { await store.capture() } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(store.busy)
                Button(store.live ? "Stop Live View" : "Start Live View") { store.live.toggle() }
                    .keyboardShortcut("l", modifiers: .command)
                Button(lights.isOn ? "Turn LEDs Off" : "Turn LEDs On") { lights.toggle() }
                    .keyboardShortcut("b", modifiers: .command)
                Toggle("LEDs On While Capturing", isOn: $lights.autoCapture)
                Button(voice.listening ? "Stop Voice Capture" : "Start Voice Capture (say “capture”)") { voice.toggle() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Divider()
                Button("Detect Sample") { sampler.analyzeNow() }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(!store.canMeasure)
                Divider()
                Button("Export Annotated Image…") {
                    if let cg = adj.displayCG ?? store.shownCG { store.exportAnnotated(cg) }
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!store.canMeasure)
                Button("Copy Results") { store.copyResults() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(store.measurements.isEmpty)
            }

            CommandMenu("Theme") {
                Button(look.dark ? "Switch to Light Mode" : "Switch to Dark Mode") {
                    withAnimation(.easeInOut(duration: 0.35)) { look.dark.toggle() }
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                Divider()
                ForEach(Palette.allCases) { p in
                    Button(look.palette == p ? "✓ \(p.name)" : p.name) {
                        withAnimation(.easeInOut(duration: 0.4)) { look.palette = p }
                    }
                }
            }

            CommandMenu("Tools") {
                ForEach(Tool.allCases) { t in
                    Button(t.title) { store.tool = t }
                        .keyboardShortcut(t.key, modifiers: .command)
                }
                Divider()
                Button("Undo Last Measurement") { store.undoLast() }
                    .keyboardShortcut("z", modifiers: [.command, .option])
                Button("Delete Selected Measurement") { store.deleteSelected() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(store.selectedID == nil)
            }
        }
    }
}
