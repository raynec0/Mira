import Foundation
import UIKit
import UserNotifications
import BackgroundTasks
import AVFoundation
import Speech
import NaturalLanguage
import LocalAuthentication

// MARK: - 通知

enum NotificationService {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func post(title: String, body: String, conversationID: UUID? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(240))
        content.sound = .default
        if let conversationID {
            content.userInfo = ["conversationID": conversationID.uuidString]
            content.threadIdentifier = conversationID.uuidString
        }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    static func schedule(title: String, body: String, at date: Date, conversationID: UUID?) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let conversationID { content.userInfo = ["conversationID": conversationID.uuidString] }
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        try await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "reminder-\(UUID().uuidString)", content: content, trigger: trigger))
    }
}

// MARK: - 例程调度

@MainActor
final class RoutineScheduler {
    static let shared = RoutineScheduler()
    nonisolated static let refreshID = "com.raynec.mira.refresh"
    private var runningRoutines = Set<UUID>()
    private var store: AppStore { AppStore.shared }

    nonisolated static func registerBackgroundTask() {
        _ = BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshID, using: nil) { task in
            handle(task)
        }
    }

    nonisolated private static func handle(_ task: BGTask) {
        let work = Task { @MainActor in
            await RoutineScheduler.shared.runDue()
            RoutineScheduler.shared.scheduleBackgroundRefresh()
        }
        task.expirationHandler = { work.cancel() }
        Task {
            await work.value
            task.setTaskCompleted(success: true)
        }
    }

    private func occurrence(of r: Routine, dayOffset: Int, from now: Date) -> Date? {
        let cal = Calendar.current
        guard let day = cal.date(byAdding: .day, value: dayOffset, to: now) else { return nil }
        let weekday = cal.component(.weekday, from: day)
        let iso = weekday == 1 ? 7 : weekday - 1
        guard r.weekdays.contains(iso) else { return nil }
        return cal.date(bySettingHour: r.hour, minute: r.minute, second: 0, of: day)
    }

    func lastOccurrence(of r: Routine, before now: Date = Date()) -> Date? {
        for offset in 0..<8 {
            if let t = occurrence(of: r, dayOffset: -offset, from: now), t <= now { return t }
        }
        return nil
    }

    func nextOccurrence(of r: Routine, after now: Date = Date()) -> Date? {
        for offset in 0..<8 {
            if let t = occurrence(of: r, dayOffset: offset, from: now), t > now { return t }
        }
        return nil
    }

    func dueRoutines(now: Date = Date()) -> [Routine] {
        store.routines.filter { r in
            guard r.enabled, let occ = lastOccurrence(of: r, before: now) else { return false }
            if now.timeIntervalSince(occ) > 6 * 3600 { return false }
            if let last = r.lastRun, last >= occ { return false }
            return true
        }
    }

    func runDue() async {
        for r in dueRoutines() where !runningRoutines.contains(r.id) {
            runningRoutines.insert(r.id)
            await AgentEngine.shared.runRoutine(r)
            runningRoutines.remove(r.id)
        }
    }

    func nextRunText() -> String? {
        let candidate = store.routines.filter { $0.enabled }
            .compactMap { r in nextOccurrence(of: r).map { (r, $0) } }
            .min { $0.1 < $1.1 }
        guard let next = candidate else { return nil }
        return "\(next.0.title) · \(RelativeTime.chatHeader(next.1))"
    }

    func reschedule() async {
        await scheduleNotifications()
        scheduleBackgroundRefresh()
    }

    func scheduleBackgroundRefresh() {
        let next = store.routines.filter { $0.enabled }.compactMap { nextOccurrence(of: $0) }.min()
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshID)
        request.earliestBeginDate = next ?? Date().addingTimeInterval(3600)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshID)
        try? BGTaskScheduler.shared.submit(request)
    }

    func scheduleNotifications() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let old = pending.map { $0.identifier }.filter { $0.hasPrefix("routine-") }
        center.removePendingNotificationRequests(withIdentifiers: old)
        for r in store.routines where r.enabled && r.notify {
            for d in r.weekdays where (1...7).contains(d) {
                var comps = DateComponents()
                comps.weekday = d == 7 ? 1 : d + 1
                comps.hour = r.hour
                comps.minute = r.minute
                let content = UNMutableNotificationContent()
                content.title = "⏰ \(r.title)"
                content.body = "例程正在运行，点按查看结果。"
                content.sound = .default
                var info: [String: String] = ["routineID": r.id.uuidString]
                if let cid = r.conversationID { info["conversationID"] = cid.uuidString }
                content.userInfo = info
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
                try? await center.add(UNNotificationRequest(identifier: "routine-\(r.id.uuidString)-\(d)", content: content, trigger: trigger))
            }
        }
    }
}

// MARK: - 语音输入

@MainActor
final class SpeechRecognizer: ObservableObject {
    @Published var transcript = ""
    @Published var isRecording = false
    @Published var errorMessage: String?

    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func toggle() {
        if isRecording { stop() } else { Task { await start() } }
    }

    func start() async {
        errorMessage = nil
        let speechOK = await Self.requestSpeechAuthorization()
        let micOK = await AVAudioApplication.requestRecordPermission()
        guard speechOK, micOK else {
            errorMessage = "需要麦克风和语音识别权限"
            return
        }
        let localeID = Locale.preferredLanguages.first ?? "zh-CN"
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)) ?? SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
              recognizer.isAvailable else {
            errorMessage = "语音识别当前不可用"
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let engine = AVAudioEngine()
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            Self.installTap(engine: engine, request: request)
            engine.prepare()
            try engine.start()
            self.engine = engine
            self.request = request
            transcript = ""
            isRecording = true
            task = Self.makeTask(recognizer: recognizer, request: request) { [weak self] text, isFinal in
                Task { @MainActor in
                    guard let self else { return }
                    if let text, !text.isEmpty { self.transcript = text }
                    if isFinal { self.stop() }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            stop()
        }
    }

    func stop() {
        guard engine != nil || task != nil else {
            isRecording = false
            return
        }
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        engine = nil
        request = nil
        task = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated private static func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in c.resume(returning: status == .authorized) }
        }
    }

    nonisolated private static func installTap(engine: AVAudioEngine, request: SFSpeechAudioBufferRecognitionRequest) {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
    }

    nonisolated private static func makeTask(recognizer: SFSpeechRecognizer,
                                             request: SFSpeechAudioBufferRecognitionRequest,
                                             handler: @escaping @Sendable (String?, Bool) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            handler(result?.bestTranscription.formattedString, (result?.isFinal ?? false) || error != nil)
        }
    }
}

// MARK: - 朗读

@MainActor
final class Speaker {
    static let shared = Speaker()
    private let synthesizer = AVSpeechSynthesizer()

    var isSpeaking: Bool { synthesizer.isSpeaking }

    func speak(_ text: String) {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let clean = text.replacingOccurrences(of: "[*#`>|_]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(clean)
        let lang = recognizer.dominantLanguage?.rawValue ?? "zh-Hans"
        let voiceLang: String
        switch lang {
        case "zh-Hans": voiceLang = "zh-CN"
        case "zh-Hant": voiceLang = "zh-TW"
        case "en": voiceLang = "en-US"
        case "ja": voiceLang = "ja-JP"
        default: voiceLang = lang
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: clean)
        utterance.voice = AVSpeechSynthesisVoice(language: voiceLang)
        synthesizer.speak(utterance)
    }

    func stop() { synthesizer.stopSpeaking(at: .immediate) }
}

// MARK: - 锁

@MainActor
final class LockManager: ObservableObject {
    static let shared = LockManager()
    @Published var isLocked: Bool
    private var authenticating = false

    init() {
        isLocked = AppStore.shared.settings.biometricLock
    }

    func lockIfEnabled() {
        if AppStore.shared.settings.biometricLock { isLocked = true }
    }

    func unlock() async {
        guard isLocked, !authenticating else { return }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            isLocked = false
            return
        }
        authenticating = true
        defer { authenticating = false }
        do {
            if try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "解锁 Mira") {
                isLocked = false
            }
        } catch {
            // 保持锁定，用户可再次点按解锁
        }
    }
}
