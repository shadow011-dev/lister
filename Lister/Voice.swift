import SwiftUI
import AppKit
import AVFoundation
import Speech

// MARK: - Microphone

/// Owns the audio engine. Lives outside any actor because the tap runs on the audio thread.
final class MicEngine: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var lastLevelTime: CFTimeInterval = 0
    private(set) var running = false
    /// Called about ten times a second with a 0...1 loudness (on the audio thread).
    var onLevel: (@Sendable (Float) -> Void)?

    func setRequest(_ r: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); request = r; lock.unlock()
    }

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "Lister", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No microphone found."])
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.lock(); let r = self.request; self.lock.unlock()
            r?.append(buffer)
            let now = ProcessInfo.processInfo.systemUptime
            if now - self.lastLevelTime > 0.1 {
                self.lastLevelTime = now
                self.onLevel?(MicEngine.level(buffer))
            }
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    func stop() {
        if running {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        running = false
        setRequest(nil)
    }

    private static func level(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        if n == 0 { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += ch[i] * ch[i] }
        let rms = (sum / Float(n)).squareRoot()
        return min(1, rms * 8)
    }
}

// MARK: - Voice capture

/// Listens through the Mac's microphone and takes a photo whenever it hears "capture".
@MainActor
final class VoiceControl: ObservableObject {
    @Published var listening = false
    @Published var starting = false
    /// The last few words that were heard (shown in the status bar).
    @Published var heard = ""
    @Published var level: Float = 0

    /// Words and phrases that take a photo.
    static let words = "capture, snap, take photo, take picture"
    private static let pattern = try? NSRegularExpression(
        pattern: "\\b(capture|snap|take (a )?(photo|picture))\\b", options: [.caseInsensitive])

    private weak var store: Store?
    private let mic = MicEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var seen = 0
    private var lastTrigger = Date.distantPast
    private var taskStart = Date()
    private var quickFailures = 0

    func attach(_ s: Store) { store = s }

    func toggle() {
        if listening || starting { stop() } else { Task { await start() } }
    }

    // MARK: Start / stop

    func start() async {
        guard !listening, !starting, let store else { return }
        starting = true
        defer { starting = false }

        let speech = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard speech == .authorized else {
            store.notify("Allow Lister under System Settings → Privacy & Security → Speech Recognition.",
                         icon: "mic.slash.fill", error: true)
            return
        }
        let micOK = await AVCaptureDevice.requestAccess(for: .audio)
        guard micOK else {
            store.notify("Allow Lister under System Settings → Privacy & Security → Microphone.",
                         icon: "mic.slash.fill", error: true)
            return
        }

        let rec = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let rec, rec.isAvailable else {
            store.notify("Speech recognition is not available right now.", icon: "mic.slash.fill", error: true)
            return
        }
        recognizer = rec

        mic.onLevel = { [weak self] v in
            Task { @MainActor in self?.level = v }
        }
        do {
            try mic.start()
        } catch {
            store.notify("Microphone failed: \(error.localizedDescription)", icon: "mic.slash.fill", error: true)
            return
        }
        quickFailures = 0
        heard = ""
        listening = true
        beginTask()
        store.notify("Listening. Say “capture” to take a photo.", icon: "mic.fill")
    }

    func stop() {
        listening = false
        generation += 1
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        mic.stop()
        level = 0
        heard = ""
    }

    // MARK: Recognition

    private func beginTask() {
        guard listening, let rec = recognizer else { return }
        generation += 1
        let gen = generation
        seen = 0
        taskStart = Date()

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .confirmation
        req.contextualStrings = ["capture", "snap", "take photo", "take picture"]
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        mic.setRequest(req)

        task = VoiceControl.startTask(rec, req) { [weak self] text, final, failed in
            Task { @MainActor in self?.handle(text: text, final: final, failed: failed, gen: gen) }
        }
    }

    /// Starts recognition outside the main actor, because the speech framework calls back on its own queue.
    nonisolated private static func startTask(
        _ rec: SFSpeechRecognizer,
        _ req: SFSpeechAudioBufferRecognitionRequest,
        handler: @escaping @Sendable (String?, Bool, Bool) -> Void
    ) -> SFSpeechRecognitionTask {
        rec.recognitionTask(with: req) { result, error in
            handler(result?.bestTranscription.formattedString, result?.isFinal ?? false, error != nil)
        }
    }

    /// Ends the current recognition and starts a fresh one (clears the transcript).
    private func restart(after delay: Double = 0.25) {
        generation += 1
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        mic.setRequest(nil)
        let gen = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.listening, gen == self.generation else { return }
            self.beginTask()
        }
    }

    private func handle(text: String?, final: Bool, failed: Bool, gen: Int) {
        guard gen == generation, listening else { return }

        if let text, !text.isEmpty {
            quickFailures = 0
            let words = text.split(separator: " ").suffix(4).joined(separator: " ")
            heard = words
            let count = VoiceControl.pattern?.numberOfMatches(
                in: text, options: [], range: NSRange(text.startIndex..., in: text)) ?? 0
            if count > seen {
                seen = count
                trigger()
                return
            }
        }

        if final || failed {
            // Recognition tasks end after a minute or on silence; just start another.
            if Date().timeIntervalSince(taskStart) < 1.5 { quickFailures += 1 }
            if quickFailures >= 5 {
                stop()
                store?.notify("Speech recognition keeps failing. Turn on Dictation in System Settings → Keyboard, then try again.",
                              icon: "mic.slash.fill", error: true)
                return
            }
            restart(after: quickFailures > 0 ? 0.8 : 0.25)
        }
    }

    private func trigger() {
        guard let store else { return }
        let now = Date()
        // Ignore repeats while a photo is being taken and for a moment afterwards.
        if store.busy || now.timeIntervalSince(lastTrigger) < 2.5 {
            restart()
            return
        }
        lastTrigger = now
        NSSound(named: "Tink")?.play()
        Task { @MainActor in await store.capture() }
        restart()
    }
}

// MARK: - Toolbar button

struct VoiceButton: View {
    @EnvironmentObject var voice: VoiceControl

    var body: some View {
        Button { voice.toggle() } label: {
            HStack(spacing: 6) {
                ZStack {
                    if voice.listening {
                        Circle()
                            .fill(Color.red.opacity(0.35))
                            .frame(width: 8 + CGFloat(voice.level) * 12, height: 8 + CGFloat(voice.level) * 12)
                            .animation(.easeOut(duration: 0.12), value: voice.level)
                    }
                    Image(systemName: voice.listening ? "mic.fill" : "mic")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(voice.listening ? Color.red : Theme.ink)
                }
                .frame(width: 20, height: 20)
                Text(voice.listening ? "Listening" : "Voice").font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(Capsule().fill(voice.listening ? Color.red.opacity(0.2) : Theme.ink.opacity(0.07)))
            .overlay(Capsule().strokeBorder(voice.listening ? Color.red.opacity(0.55) : Theme.ink.opacity(0.08), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .disabled(voice.starting)
        .help(voice.listening
              ? "Microphone is on. Click to stop listening (⇧⌘M)"
              : "Turn on the microphone and say “capture” to take a photo (⇧⌘M)")
        .animation(Theme.spring, value: voice.listening)
    }
}
