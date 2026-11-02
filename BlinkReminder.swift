import SwiftUI
import UserNotifications
import AppKit
import Combine
import ServiceManagement
import AVFoundation
import CoreMediaIO
import CoreGraphics
import OSLog

private let logger = Logger(subsystem: "com.agamtech.blinkreminder", category: "app")

/// Pure decision helper (mirrored in Tests.swift): only a *scheduled* fire may be
/// skipped for idleness. A manual trigger proves the user is present, so it
/// always presents (unless paused).
func shouldSkipBreakForIdle(manual: Bool, resetOnIdle: Bool, idleSeconds: TimeInterval, threshold: TimeInterval) -> Bool {
    !manual && resetOnIdle && idleSeconds >= threshold
}

/// Unbuffered stdout write: print() block-buffers when redirected to a file,
/// which loses output if the process is killed. The self-test must be visible.
func uitestLog(_ message: String) {
    print(message)
    fflush(stdout)
}

private enum HeadsUp {
    static let categoryID = "BREAK_HEADSUP"
    static let startNowID = "START_NOW"
    static let snooze1mID = "SNOOZE_1M"
    static let snooze5mID = "SNOOZE_5M"
    static let leadTime: TimeInterval = 30
}

@main
struct BlinkReminderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

// MARK: - UserDefaults keys (type-safe)

enum AppDefaults {
    static let motivationEnabled = "MotivationEnabled"
    static let langEnglish = "LangEnglish"
    static let langHindi = "LangHindi"
    static let langNepali = "LangNepali"
    static let firstRun = "FirstRun"
    static let strictMode = "StrictMode"
    static let maxSkipsPerHour = "MaxSkipsPerHour"
    static let autoPauseForCamera = "AutoPauseForCamera"
    static let resetOnIdle = "ResetOnIdle"
    static let idleThreshold = "IdleThreshold"
    static let breakDuration = "BreakDuration"
    static let interval = "BreakInterval"
    static let overlayEnabled = "OverlayEnabled"
    static let soundEnabled = "SoundEnabled"

    static func register() {
        UserDefaults.standard.register(defaults: [
            motivationEnabled: true,
            langEnglish: true,
            langHindi: false,
            langNepali: false,
            firstRun: true,
            strictMode: false,
            maxSkipsPerHour: -1, // -1 = Unlimited
            autoPauseForCamera: true,
            // Off by default: the idle API misreports on some systems, where a
            // default-on reset silently eats every break. Opt in via Advanced.
            resetOnIdle: false,
            idleThreshold: 60.0,
            breakDuration: 20.0,
            interval: 20 * 60,
            overlayEnabled: true,
            soundEnabled: true,
        ])
    }
}

// MARK: - Break sounds (system sounds only, no new deps)

/// Plays short system alert sounds for break events. NSSound is AppKit
/// (already imported). Single choke point for the user toggle + main-thread
/// hop so call sites stay one-liners. Never crashes headless (nil → log).
enum BreakSound {
    private static var retained: NSSound?

    static func play(named name: String, reason: String) {
        guard UserDefaults.standard.bool(forKey: AppDefaults.soundEnabled) else { return }
        guard Thread.isMainThread else {
            DispatchQueue.main.async { play(named: name, reason: reason) }
            return
        }
        let sound: NSSound? = NSSound(named: name)
            ?? NSSound(contentsOfFile: "/System/Library/Sounds/\(name).aiff", byReference: true)
        guard let sound else {
            logger.error("Break sound missing: \(name) (\(reason))")
            return
        }
        // Retain: a local would deallocate mid-play and truncate the audio.
        retained = sound
        if sound.play() {
            logger.info("Playing sound: \(name) (\(reason))")
        } else {
            logger.error("Break sound play failed: \(name) (\(reason))")
        }
    }
}

// MARK: - Quotes

struct Quotes {
    static let english = [
        "Look at something 20 feet away.",
        "Take a deep breath and relax.",
        "Blink often to keep your eyes hydrated.",
        "Stretch your neck and shoulders.",
        "Drink some water.",
        "Your eyes need rest to stay sharp.",
        "Focus on something distant.",
        "Relax your jaw and shoulders.",
        "Give your mind a moment of silence.",
        "Stare out the window and pretend you're in a music video.",
        "Your monitor misses you, but it needs space.",
        "A quick blink is a tiny nap for your eyes.",
        "Hydrate before you dy-drate! (Wait, just drink water).",
        "The pixels will be here when you get back.",
        "Is that a bird? Is that a plane? No, it's just a break.",
        "If you can read this, you're not looking 20 feet away!",
        "Rumor has it, blinking makes you 1% more awesome.",
        "Stretch like a cat. No one is watching. Probably."
    ]

    static let hindi = [
        "Tension nahi lene ka, break lene ka!",
        "Ae Circuit, isko bol break lene ko!",
        "Bhidu, aankhein hai toh jahaan hai. Relax kar!",
        "Load nahi lene ka, mast rehne ka.",
        "Kya re bhidu, thak gaya kya?",
        "Jadoo ki jhappi... for your eyes.",
        "All Izz Well!",
        "Utha le re baba, utha le... mereko nahi, is laptop ko utha le!",
        "Yeh Baburao ka style hai! Break toh banta hai.",
        "Dene wala jab bhi deta, deta chappar faad ke... toh break bhi chappar faad ke le!",
        "Khopdi tod saale ka! Break nahi lega toh?",
        "Mast joke maara re! Ab break le."
    ]

    static let nepali = [
        "Sathi, aankha ko jyoti nai thulo kura ho. Ekchin aaram gara.",
        "Mero naam Rajesh Hamal, ra ma bhanchu: Break leu!",
        "Herne katha hoina, herne byatha ho. Aankha lai aaram deu!",
        "Eh... aankha dukhyo bhane maile ke garne? Break leu na!",
        "Aankha futla hai! Ekchin aaram garnu pardaina?",
        "Tyo monitor lai katti hereko? Maile ta break liye hai!",
        "Namaste! Sanchai hunuhuncha? Aankha lai ali aaram chaincha hai.",
        "Desh banauna gaaro cha, tara aankha jogauna sajilo cha. Break linus!",
        "Gaaun ma huda ta hariyali herinthyo, yaha ta screen matra. Ekchin baaira herau!"
    ]

    static func getActiveQuotes() -> [String] {
        let defaults = UserDefaults.standard
        var quotes: [String] = []

        if defaults.bool(forKey: AppDefaults.langEnglish) {
            quotes.append(contentsOf: english)
        }
        if defaults.bool(forKey: AppDefaults.langHindi) {
            quotes.append(contentsOf: hindi)
        }
        if defaults.bool(forKey: AppDefaults.langNepali) {
            quotes.append(contentsOf: nepali)
        }

        if quotes.isEmpty {
            quotes.append(contentsOf: english)
        }

        return quotes
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem?
    var timer: Timer?
    var headsUpTimer: Timer?
    var cameraUsageMonitor: Timer?
    var idleMonitor: Timer?
    var manualPauseResumeTimer: Timer?
    var interval: TimeInterval = 20 * 60
    var overlayEnabled = true
    var overlayWindows: [OverlayWindow] = []
    var previouslyActiveApp: NSRunningApplication?
    var skipTimestamps: [Date] = []
    var nextFireDate: Date?
    var lastHeadsUpID: String?
    /// Remaining countdown preserved across sleep/wake (nil = no suspend).
    var suspendedRemaining: TimeInterval?

    var isManuallyPaused = false
    var isAutoPausedForVideoCall = false
    var manualPauseUntil: Date?

    var idleThreshold: TimeInterval {
        get {
            let stored = UserDefaults.standard.double(forKey: AppDefaults.idleThreshold)
            return stored > 0 ? stored : 60
        }
        set {
            UserDefaults.standard.set(newValue, forKey: AppDefaults.idleThreshold)
        }
    }

    var breakDurationSeconds: Int {
        get {
            let stored = UserDefaults.standard.double(forKey: AppDefaults.breakDuration)
            let value = stored > 0 ? Int(stored) : 20
            return value
        }
        set {
            UserDefaults.standard.set(Double(newValue), forKey: AppDefaults.breakDuration)
        }
    }

    var isPaused: Bool {
        isManuallyPaused || isAutoPausedForVideoCall
    }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        AppDefaults.register()

        // Restore persisted preferences (in-memory defaults would silently
        // reset the user's choices on every relaunch).
        let storedInterval = UserDefaults.standard.double(forKey: AppDefaults.interval)
        if storedInterval > 0 {
            interval = storedInterval
        }
        overlayEnabled = UserDefaults.standard.bool(forKey: AppDefaults.overlayEnabled)

        if UserDefaults.standard.bool(forKey: AppDefaults.firstRun) {
            enableLaunchAtLogin()
            UserDefaults.standard.set(false, forKey: AppDefaults.firstRun)
        }

        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()

        setupMenu()
        setupNotificationCategories()
        requestNotificationPermission()
        startVideoCallMonitoring()
        startIdleMonitoring()

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(self, selector: #selector(suspendTimer), name: NSWorkspace.willSleepNotification, object: nil)
        workspaceCenter.addObserver(self, selector: #selector(resumeTimer), name: NSWorkspace.didWakeNotification, object: nil)
        workspaceCenter.addObserver(self, selector: #selector(suspendTimer), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspaceCenter.addObserver(self, selector: #selector(resumeTimer), name: NSWorkspace.screensDidWakeNotification, object: nil)

        startTimer()
        logger.info("BlinkReminder launched. Interval: \(self.interval)s, resetOnIdle: \(UserDefaults.standard.bool(forKey: AppDefaults.resetOnIdle))")

        if CommandLine.arguments.contains("--test-overlay") {
            runOverlaySelfTest()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        cleanup()
    }

    deinit {
        cleanup()
    }

    private func cleanup() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        timer?.invalidate()
        timer = nil
        headsUpTimer?.invalidate()
        headsUpTimer = nil
        cameraUsageMonitor?.invalidate()
        cameraUsageMonitor = nil
        idleMonitor?.invalidate()
        idleMonitor = nil
        manualPauseResumeTimer?.invalidate()
        manualPauseResumeTimer = nil
        nextFireDate = nil
        overlayWindows.forEach {
            $0.contentView = nil
            $0.close()
        }
        overlayWindows.removeAll()
        previouslyActiveApp = nil
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    // MARK: Notifications

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        DispatchQueue.main.async { [weak self] in
            guard let self else { completionHandler(); return }
            switch action {
            case HeadsUp.startNowID:
                logger.info("Heads-up: Start now tapped")
                self.clearHeadsUpState()
                self.triggerBreakNow()
            case HeadsUp.snooze1mID:
                logger.info("Heads-up: snooze +1m")
                self.deferBreak(by: 60)
            case HeadsUp.snooze5mID:
                logger.info("Heads-up: snooze +5m")
                self.deferBreak(by: 5 * 60)
            default:
                // Banner tapped directly or dismissed: drop the stale heads-up
                // ID so a later break can't clear the wrong notification.
                self.clearHeadsUpState()
            }
            completionHandler()
        }
    }

    func setupNotificationCategories() {
        let startNow = UNNotificationAction(identifier: HeadsUp.startNowID, title: "Start now", options: [])
        let snooze1m = UNNotificationAction(identifier: HeadsUp.snooze1mID, title: "Snooze 1 min", options: [])
        let snooze5m = UNNotificationAction(identifier: HeadsUp.snooze5mID, title: "Snooze 5 min", options: [])
        let category = UNNotificationCategory(identifier: HeadsUp.categoryID, actions: [startNow, snooze1m, snooze5m], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    // MARK: - Menu

    func setupMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let headerItem = NSMenuItem(title: "Blink Reminder v\(version)", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        // Countdown item (tag 9001). Refreshed on menu open (menuWillOpen); no background polling.
        let countdownItem = NSMenuItem(title: "Next break in --:--", action: nil, keyEquivalent: "")
        countdownItem.tag = 9001
        countdownItem.isEnabled = false
        menu.addItem(countdownItem)

        menu.addItem(NSMenuItem.separator())

        // Critical path
        let intervalMenu = NSMenuItem(title: "Interval", action: nil, keyEquivalent: "")
        let intervalSub = NSMenu()
        let intervals: [(String, TimeInterval)] = [
            ("5 Minutes", 5 * 60),
            ("10 Minutes", 10 * 60),
            ("20 Minutes", 20 * 60),
            ("30 Minutes", 30 * 60),
            ("60 Minutes", 60 * 60),
        ]
        for (title, time) in intervals {
            let item = NSMenuItem(title: title, action: #selector(changeInterval(_:)), keyEquivalent: "")
            item.representedObject = time as NSNumber
            item.state = (time == interval) ? .on : .off
            intervalSub.addItem(item)
        }
        intervalMenu.submenu = intervalSub
        menu.addItem(intervalMenu)

        let durationMenu = NSMenuItem(title: "Break Duration", action: nil, keyEquivalent: "")
        let durationSub = NSMenu()
        let currentDuration = breakDurationSeconds
        for (title, seconds) in [("15 Seconds", 15), ("20 Seconds", 20), ("30 Seconds", 30), ("60 Seconds", 60)] {
            let item = NSMenuItem(title: title, action: #selector(changeBreakDuration(_:)), keyEquivalent: "")
            item.representedObject = seconds as NSNumber
            item.state = (seconds == currentDuration) ? .on : .off
            durationSub.addItem(item)
        }
        durationMenu.submenu = durationSub
        menu.addItem(durationMenu)

        let overlayItem = NSMenuItem(title: "Use Screen Overlay", action: #selector(toggleOverlay(_:)), keyEquivalent: "")
        overlayItem.state = overlayEnabled ? .on : .off
        menu.addItem(overlayItem)

        let pauseForMenu = NSMenuItem(title: "Pause For", action: nil, keyEquivalent: "")
        let pauseForSubMenu = NSMenu()
        pauseForSubMenu.addItem(NSMenuItem(title: "15 Minutes", action: #selector(pauseFor15Minutes), keyEquivalent: ""))
        pauseForSubMenu.addItem(NSMenuItem(title: "30 Minutes", action: #selector(pauseFor30Minutes), keyEquivalent: ""))
        pauseForSubMenu.addItem(NSMenuItem(title: "1 Hour", action: #selector(pauseFor1Hour), keyEquivalent: ""))
        pauseForMenu.submenu = pauseForSubMenu
        menu.addItem(pauseForMenu)

        menu.addItem(NSMenuItem(title: "Pause", action: #selector(togglePause(_:)), keyEquivalent: "p"))
        menu.addItem(NSMenuItem(title: "Trigger Break Now", action: #selector(triggerBreakNow), keyEquivalent: "b"))

        menu.addItem(NSMenuItem.separator())

        // Non-critical: kept, moved out of the critical path.
        let settingsMenu = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let settingsSub = NSMenu()

        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launchItem.state = isLaunchAtLoginEnabled() ? .on : .off
        settingsSub.addItem(launchItem)

        let motivationItem = NSMenuItem(title: "Enable Motivation Text", action: #selector(toggleMotivation(_:)), keyEquivalent: "")
        motivationItem.state = UserDefaults.standard.bool(forKey: AppDefaults.motivationEnabled) ? .on : .off
        settingsSub.addItem(motivationItem)

        let soundItem = NSMenuItem(title: "Play Sounds", action: #selector(toggleSound(_:)), keyEquivalent: "")
        soundItem.state = UserDefaults.standard.bool(forKey: AppDefaults.soundEnabled) ? .on : .off
        settingsSub.addItem(soundItem)

        settingsSub.addItem(NSMenuItem.separator())
        let langHeader = NSMenuItem(title: "Languages:", action: nil, keyEquivalent: "")
        langHeader.isEnabled = false
        settingsSub.addItem(langHeader)
        for (title, key) in [("English", AppDefaults.langEnglish), ("Hindi", AppDefaults.langHindi), ("Nepali", AppDefaults.langNepali)] {
            let item = NSMenuItem(title: title, action: #selector(toggleLanguage(_:)), keyEquivalent: "")
            item.representedObject = key as NSString
            item.state = UserDefaults.standard.bool(forKey: key) ? .on : .off
            settingsSub.addItem(item)
        }
        settingsMenu.submenu = settingsSub
        menu.addItem(settingsMenu)

        let advancedMenu = NSMenuItem(title: "Advanced", action: nil, keyEquivalent: "")
        let advancedSub = NSMenu()

        let strictItem = NSMenuItem(title: "Strict Mode", action: #selector(toggleStrictMode(_:)), keyEquivalent: "")
        strictItem.state = UserDefaults.standard.bool(forKey: AppDefaults.strictMode) ? .on : .off
        advancedSub.addItem(strictItem)

        let skipsItem = NSMenuItem(title: "Max Skips / Hour", action: nil, keyEquivalent: "")
        let skipsSub = NSMenu()
        let currentMaxSkips = UserDefaults.standard.integer(forKey: AppDefaults.maxSkipsPerHour)
        for (title, val) in [("No skips (0)", 0), ("1 Skip", 1), ("3 Skips", 3), ("5 Skips", 5), ("Unlimited", -1)] {
            let item = NSMenuItem(title: title, action: #selector(changeMaxSkips(_:)), keyEquivalent: "")
            item.tag = val
            item.state = (val == currentMaxSkips) ? .on : .off
            skipsSub.addItem(item)
        }
        skipsItem.submenu = skipsSub
        advancedSub.addItem(skipsItem)

        let autoPauseItem = NSMenuItem(title: "Auto-Pause for Video Call", action: #selector(toggleAutoPause(_:)), keyEquivalent: "")
        autoPauseItem.state = UserDefaults.standard.bool(forKey: AppDefaults.autoPauseForCamera) ? .on : .off
        advancedSub.addItem(autoPauseItem)

        let resetOnIdleItem = NSMenuItem(title: "Reset Timer When Idle", action: #selector(toggleResetOnIdle(_:)), keyEquivalent: "")
        resetOnIdleItem.state = UserDefaults.standard.bool(forKey: AppDefaults.resetOnIdle) ? .on : .off
        advancedSub.addItem(resetOnIdleItem)

        let idleMenu = NSMenuItem(title: "Idle Threshold", action: nil, keyEquivalent: "")
        let idleSub = NSMenu()
        let currentThreshold = Int(idleThreshold)
        for (title, seconds) in [("30 Seconds", 30.0), ("1 Minute", 60.0), ("2 Minutes", 120.0), ("5 Minutes", 300.0)] {
            let item = NSMenuItem(title: title, action: #selector(changeIdleThreshold(_:)), keyEquivalent: "")
            item.representedObject = seconds as NSNumber
            item.state = (Int(seconds) == currentThreshold) ? .on : .off
            idleSub.addItem(item)
        }
        idleMenu.submenu = idleSub
        advancedSub.addItem(idleMenu)

        advancedMenu.submenu = advancedSub
        menu.addItem(advancedMenu)

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem?.menu = menu
        refreshCountdownItem()
    }

    // MARK: - Launch at Login (macOS 13+, minimum deployment target)

    func isLaunchAtLoginEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
                sender.state = .off
            } else {
                try service.register()
                sender.state = .on
            }
        } catch {
            logger.error("Failed to toggle Launch at Login: \(error.localizedDescription)")
        }
    }

    func enableLaunchAtLogin() {
        let service = SMAppService.mainApp
        if service.status != .enabled {
            try? service.register()
        }
    }

    // MARK: - Menu actions

    @objc func changeInterval(_ sender: NSMenuItem) {
        let newInterval: TimeInterval?
        if let number = sender.representedObject as? NSNumber {
            newInterval = number.doubleValue
        } else if let direct = sender.representedObject as? TimeInterval {
            newInterval = direct
        } else {
            newInterval = nil
        }
        guard let newInterval, newInterval > 0 else { return }
        interval = newInterval
        UserDefaults.standard.set(newInterval, forKey: AppDefaults.interval)
        logger.info("Interval set to \(Int(newInterval))s")
        startTimer()
        updateMenuStates()
    }

    @objc func changeBreakDuration(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        let seconds = number.intValue
        guard seconds > 0 else { return }
        breakDurationSeconds = seconds
        logger.info("Break duration set to \(seconds)s")
        updateMenuStates()
    }

    @objc func changeMaxSkips(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: AppDefaults.maxSkipsPerHour)
        updateMenuStates()
    }

    @objc func toggleOverlay(_ sender: NSMenuItem) {
        overlayEnabled.toggle()
        UserDefaults.standard.set(overlayEnabled, forKey: AppDefaults.overlayEnabled)
        logger.info("OverlayEnabled set to \(self.overlayEnabled)")
        updateMenuStates()
    }

    @objc func toggleAutoPause(_ sender: NSMenuItem) {
        let current = UserDefaults.standard.bool(forKey: AppDefaults.autoPauseForCamera)
        UserDefaults.standard.set(!current, forKey: AppDefaults.autoPauseForCamera)
        sender.state = !current ? .on : .off
        checkVideoCallState()
    }

    @objc func toggleResetOnIdle(_ sender: NSMenuItem) {
        let current = UserDefaults.standard.bool(forKey: AppDefaults.resetOnIdle)
        UserDefaults.standard.set(!current, forKey: AppDefaults.resetOnIdle)
        sender.state = !current ? .on : .off
        logger.info("ResetOnIdle set to \(!current)")
        updateMenuStates()
    }

    @objc func changeIdleThreshold(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        idleThreshold = number.doubleValue
        logger.info("Idle threshold set to \(self.idleThreshold)s")
        updateMenuStates()
    }

    @objc func pauseFor15Minutes() {
        pauseForDuration(15 * 60)
    }

    @objc func pauseFor30Minutes() {
        pauseForDuration(30 * 60)
    }

    @objc func pauseFor1Hour() {
        pauseForDuration(60 * 60)
    }

    @objc func toggleMotivation(_ sender: NSMenuItem) {
        let current = UserDefaults.standard.bool(forKey: AppDefaults.motivationEnabled)
        UserDefaults.standard.set(!current, forKey: AppDefaults.motivationEnabled)
        sender.state = !current ? .on : .off
    }

    @objc func toggleSound(_ sender: NSMenuItem) {
        let current = UserDefaults.standard.bool(forKey: AppDefaults.soundEnabled)
        UserDefaults.standard.set(!current, forKey: AppDefaults.soundEnabled)
        sender.state = !current ? .on : .off
        logger.info("SoundEnabled set to \(!current)")
        // Immediate feedback when turning on.
        if !current {
            BreakSound.play(named: "Pop", reason: "sound-toggle-test")
        }
    }

    @objc func toggleLanguage(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        let current = UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.set(!current, forKey: key)
        sender.state = !current ? .on : .off
    }

    @objc func toggleStrictMode(_ sender: NSMenuItem) {
        let current = UserDefaults.standard.bool(forKey: AppDefaults.strictMode)
        UserDefaults.standard.set(!current, forKey: AppDefaults.strictMode)
        sender.state = !current ? .on : .off
    }

    @objc func togglePause(_ sender: NSMenuItem) {
        if isAutoPausedForVideoCall && !isManuallyPaused {
            return
        }
        if isManuallyPaused {
            clearManualPauseSchedule()
            isManuallyPaused = false
            logger.info("Manually resumed")
        } else {
            clearManualPauseSchedule()
            isManuallyPaused = true
            logger.info("Manually paused (indefinite)")
        }
        applyPauseState()
    }

    func pauseForDuration(_ duration: TimeInterval) {
        clearManualPauseSchedule()
        isManuallyPaused = true
        manualPauseUntil = Date().addingTimeInterval(duration)
        logger.info("Paused for \(Int(duration / 60))m")

        manualPauseResumeTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.clearManualPauseSchedule()
            self.isManuallyPaused = false
            self.applyPauseState()
        }
        if let manualPauseResumeTimer {
            RunLoop.main.add(manualPauseResumeTimer, forMode: .common)
        }
        applyPauseState()
    }

    func clearManualPauseSchedule() {
        manualPauseResumeTimer?.invalidate()
        manualPauseResumeTimer = nil
        manualPauseUntil = nil
    }

    func remainingManualPauseText() -> String? {
        guard let manualPauseUntil else { return nil }
        let remaining = manualPauseUntil.timeIntervalSinceNow
        guard remaining > 0 else { return nil }
        let remainingMinutes = Int(ceil(remaining / 60.0))
        return "\(remainingMinutes)m left"
    }

    /// Clears an expired timed pause. Returns true on the expiry transition so
    /// callers can restart the schedule (otherwise the app sits unpaused with
    /// no timer until some unrelated event fires).
    @discardableResult
    func refreshManualPauseIfExpired() -> Bool {
        guard isManuallyPaused, let manualPauseUntil else { return false }
        if Date() >= manualPauseUntil {
            clearManualPauseSchedule()
            isManuallyPaused = false
            logger.info("Timed pause expired, resuming schedule")
            return true
        }
        return false
    }

    /// Restarts the schedule when a timed pause just expired and nothing is
    /// running. Call after refreshManualPauseIfExpired() on paths that don't
    /// otherwise start the timer. Never arms underneath a live overlay —
    /// the overlay owns the next cycle and arms it on dismissal.
    func resumeScheduleIfPauseExpired(_ expired: Bool) {
        if expired, !isPaused, timer == nil, overlayWindows.isEmpty {
            startTimer()
        }
    }

    // MARK: - Countdown (on-demand; no background polling)

    /// NSMenuDelegate: refresh the countdown snapshot each time the menu opens.
    /// countdownTitle() computes from nextFireDate on demand, so no repeating
    /// 1s timer runs while the app idles.
    func menuWillOpen(_ menu: NSMenu) {
        resumeScheduleIfPauseExpired(refreshManualPauseIfExpired())
        refreshCountdownItem()
        updateMenuStates()
    }

    func countdownTitle() -> String {
        if isAutoPausedForVideoCall {
            return "Paused (Video Call)"
        }
        if isManuallyPaused {
            if let remaining = remainingManualPauseText() {
                return "Paused (\(remaining))"
            }
            return "Paused"
        }
        // Mid-break the next cycle arms on dismissal, so there is no
        // nextFireDate yet — show break state, not a misleading "Paused".
        if !overlayWindows.isEmpty {
            return "On break…"
        }
        guard let nextFireDate else { return "Next break in --:--" }
        let remaining = max(0, Int(ceil(nextFireDate.timeIntervalSinceNow)))
        let minutes = remaining / 60
        let seconds = remaining % 60
        return String(format: "Next break in %02d:%02d", minutes, seconds)
    }

    func refreshCountdownItem() {
        guard let menu = statusItem?.menu, let item = menu.item(withTag: 9001) else { return }
        item.title = countdownTitle()
    }

    func updateMenuStates() {
        guard let menu = statusItem?.menu else { return }

        if let intervalItem = menu.items.first(where: { $0.title == "Interval" }), let sub = intervalItem.submenu {
            for item in sub.items {
                let value: TimeInterval? = (item.representedObject as? NSNumber)?.doubleValue
                item.state = (value == interval) ? .on : .off
            }
        }

        if let durationItem = menu.items.first(where: { $0.title == "Break Duration" }), let sub = durationItem.submenu {
            let current = breakDurationSeconds
            for item in sub.items {
                let value = (item.representedObject as? NSNumber)?.intValue
                item.state = (value == current) ? .on : .off
            }
        }

        if let overlayItem = menu.items.first(where: { $0.title == "Use Screen Overlay" }) {
            overlayItem.state = overlayEnabled ? .on : .off
        }

        // Settings + Advanced submenus (non-critical path, logic preserved).
        if let settings = menu.items.first(where: { $0.title == "Settings" }), let sub = settings.submenu {
            for item in sub.items {
                switch item.title {
                case "Enable Motivation Text":
                    item.state = UserDefaults.standard.bool(forKey: AppDefaults.motivationEnabled) ? .on : .off
                case "Play Sounds":
                    item.state = UserDefaults.standard.bool(forKey: AppDefaults.soundEnabled) ? .on : .off
                case "English":
                    item.state = UserDefaults.standard.bool(forKey: AppDefaults.langEnglish) ? .on : .off
                case "Hindi":
                    item.state = UserDefaults.standard.bool(forKey: AppDefaults.langHindi) ? .on : .off
                case "Nepali":
                    item.state = UserDefaults.standard.bool(forKey: AppDefaults.langNepali) ? .on : .off
                case "Launch at Login":
                    item.state = isLaunchAtLoginEnabled() ? .on : .off
                default:
                    break
                }
            }
        }

        if let advanced = menu.items.first(where: { $0.title == "Advanced" }), let sub = advanced.submenu {
            for item in sub.items {
                switch item.title {
                case "Strict Mode":
                    item.state = UserDefaults.standard.bool(forKey: AppDefaults.strictMode) ? .on : .off
                case "Auto-Pause for Video Call":
                    item.state = UserDefaults.standard.bool(forKey: AppDefaults.autoPauseForCamera) ? .on : .off
                case "Reset Timer When Idle":
                    item.state = UserDefaults.standard.bool(forKey: AppDefaults.resetOnIdle) ? .on : .off
                default:
                    break
                }
                if item.title == "Max Skips / Hour", let skipSub = item.submenu {
                    let currentMax = UserDefaults.standard.integer(forKey: AppDefaults.maxSkipsPerHour)
                    for skip in skipSub.items {
                        skip.state = (skip.tag == currentMax) ? .on : .off
                    }
                }
                if item.title == "Idle Threshold", let idleSub = item.submenu {
                    let current = Int(idleThreshold)
                    for threshold in idleSub.items {
                        let value = (threshold.representedObject as? NSNumber)?.intValue
                        threshold.state = (value == current) ? .on : .off
                    }
                }
            }
        }

        if let pauseItem = menu.items.first(where: { $0.action == #selector(togglePause(_:)) }) {
            if isAutoPausedForVideoCall && !isManuallyPaused {
                pauseItem.title = "Paused (Video Call)"
            } else {
                pauseItem.title = isManuallyPaused ? "Resume" : "Pause"
            }
            pauseItem.state = isPaused ? .on : .off
            pauseItem.isEnabled = !(isAutoPausedForVideoCall && !isManuallyPaused)
        }

        refreshCountdownItem()
    }

    @objc func suspendTimer() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.suspendTimer() }
            return
        }
        // Preserve remaining time so wake resumes where sleep left off
        // instead of restarting a full interval. willSleep + screensDidSleep
        // both fire: only capture when a schedule exists, never clobber.
        if let nextFireDate {
            let remaining = nextFireDate.timeIntervalSinceNow
            suspendedRemaining = max(1, remaining)
        }
        timer?.invalidate()
        timer = nil
        headsUpTimer?.invalidate()
        headsUpTimer = nil
        nextFireDate = nil
        clearHeadsUpState()
        refreshCountdownItem()
        logger.info("Timer suspended (sleep)")
    }

    @objc func resumeTimer() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.resumeTimer() }
            return
        }
        refreshManualPauseIfExpired()
        if !isPaused, let remaining = suspendedRemaining {
            suspendedRemaining = nil
            logger.info("Timer resumed (wake) with \(Int(remaining))s remaining")
            startTimer(withDelay: remaining)
            updateMenuStates()
            return
        }
        suspendedRemaining = nil
        applyPauseState()
        logger.info("Timer resumed (wake)")
    }

    func requestNotificationPermission() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                logger.error("Notification permission error: \(error.localizedDescription)")
            } else {
                logger.info("Notification permission granted: \(granted)")
            }
        }
    }

    // MARK: - Break scheduling (single-shot + heads-up)

    func startTimer(withDelay delay: TimeInterval? = nil) {
        refreshManualPauseIfExpired()
        timer?.invalidate()
        timer = nil
        headsUpTimer?.invalidate()
        headsUpTimer = nil
        clearHeadsUpState()
        guard !isPaused else {
            nextFireDate = nil
            refreshCountdownItem()
            return
        }
        let delay = max(1, delay ?? interval)
        let fireDate = Date().addingTimeInterval(delay)
        nextFireDate = fireDate
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.triggerBreak()
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
        // 30s heads-up when there is room for one.
        if delay > HeadsUp.leadTime + 5 {
            let headsUpDelay = delay - HeadsUp.leadTime
            headsUpTimer = Timer.scheduledTimer(withTimeInterval: headsUpDelay, repeats: false) { [weak self] _ in
                self?.sendHeadsUp()
            }
            if let headsUpTimer {
                RunLoop.main.add(headsUpTimer, forMode: .common)
            }
        }
        refreshCountdownItem()
    }

    /// Timer-fired break (scheduled path): may be skipped when paused or idle.
    @objc func triggerBreak() {
        handleBreakFire(manual: false)
    }

    /// Manual break (menu item, heads-up action, self-test): restores the
    /// pre-P0 behavior of always presenting — the interaction proves the user
    /// is present, so paused/idle guards are bypassed.
    @objc func triggerBreakNow() {
        handleBreakFire(manual: true)
    }

    private func handleBreakFire(manual: Bool) {
        refreshManualPauseIfExpired()
        if manual {
            // Already showing: just bring it forward, don't tear down the
            // active break or restart its countdown.
            if !overlayWindows.isEmpty {
                logger.info("Manual break trigger ignored: overlay already showing")
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            logger.info("Manual break trigger (paused/idle guards bypassed, idle=\(Int(self.idleSeconds()))s)")
        } else {
            guard !isPaused else {
                logger.info("triggerBreak skipped: paused (manual=\(self.isManuallyPaused) camera=\(self.isAutoPausedForVideoCall))")
                return
            }
            let idle = idleSeconds()
            if shouldSkipBreakForIdle(manual: manual, resetOnIdle: UserDefaults.standard.bool(forKey: AppDefaults.resetOnIdle), idleSeconds: idle, threshold: idleThreshold) {
                logger.info("Skipping break: user idle (\(Int(idle))s >= \(Int(self.idleThreshold))s). Resetting timer.")
                startTimer()
                updateMenuStates()
                return
            }
        }
        clearHeadsUpState()
        if overlayEnabled {
            // Consume the fired cycle: cancel the pending single-shot so the
            // menu doesn't show a stale countdown mid-break. The NEXT cycle
            // arms on dismissal (rescheduleAfterBreak), i.e. a full interval
            // AFTER the break completes — not interval-minus-20s from its start.
            timer?.invalidate()
            timer = nil
            headsUpTimer?.invalidate()
            headsUpTimer = nil
            nextFireDate = nil
            refreshCountdownItem()
            logger.info("triggerBreak: presenting overlay")
            showOverlay()
            // Headless fallback: no screens → no dismissal will ever come,
            // so don't leave the app timer-less.
            if overlayWindows.isEmpty {
                logger.error("Overlay failed to present, rescheduling")
                startTimer()
            }
        } else {
            logger.info("triggerBreak: overlay disabled, sending notification")
            sendNotification()
            // No overlay to dismiss, so the next cycle starts at fire time.
            startTimer()
        }
        updateMenuStates()
    }

    /// Arms the next full interval after a break completes (natural expiry or
    /// Skip). Snooze/pause/camera paths schedule differently or not at all,
    /// so they dismiss with scheduleNext:false instead of coming here.
    func rescheduleAfterBreak() {
        guard !isPaused else {
            logger.info("Break ended while paused — no reschedule")
            updateMenuStates()
            return
        }
        logger.info("Break completed — next break in \(Int(self.interval))s")
        startTimer()
        updateMenuStates()
    }

    /// Headless UI self-test (`--test-overlay`): presents the overlay via the
    /// manual path, reports windows/visible/screens to stdout, then quits.
    /// SKIP only when there is no GUI session. (Manual triggers bypass pause,
    /// so paused state must NOT gate the verdict.)
    /// Lets anyone verify the overlay on a real Mac without build tools:
    /// `/Applications/BlinkReminder.app/Contents/MacOS/BlinkReminder --test-overlay`
    func runOverlaySelfTest() {
        uitestLog("UI-TEST: starting overlay self-test")
        logger.info("UI-TEST: starting overlay self-test")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            let screens = NSScreen.screens.count
            uitestLog("UI-TEST: screens=\(screens) paused=\(self.isPaused) overlayEnabled=\(self.overlayEnabled) idle=\(Int(self.idleSeconds()))s threshold=\(Int(self.idleThreshold))s resetOnIdle=\(UserDefaults.standard.bool(forKey: AppDefaults.resetOnIdle))")
            self.triggerBreakNow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self else { return }
                let count = self.overlayWindows.count
                let visible = self.overlayWindows.filter { $0.isVisible }.count
                uitestLog("UI-TEST: windows=\(count) visible=\(visible)")
                if screens == 0 {
                    uitestLog("UI-TEST SKIP (no GUI session, no screens)")
                } else if count > 0 && visible == count {
                    uitestLog("UI-TEST PASS (overlay presented on \(count) screen(s))")
                } else {
                    uitestLog("UI-TEST FAIL (windows=\(count) visible=\(visible) screens=\(screens) paused=\(self.isPaused))")
                }
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - 30s heads-up with snooze (P0-2)

    func sendHeadsUp() {
        refreshManualPauseIfExpired()
        guard !isPaused else {
            logger.info("Heads-up skipped: paused")
            return
        }
        guard overlayWindows.isEmpty else { return }
        // No heads-up when the overlay is off: the scheduled break already
        // notifies once, a second banner would double-notify one break.
        guard overlayEnabled else { return }
        if shouldSkipBreakForIdle(manual: false, resetOnIdle: UserDefaults.standard.bool(forKey: AppDefaults.resetOnIdle), idleSeconds: idleSeconds(), threshold: idleThreshold) {
            logger.info("Skipping heads-up: user idle. Resetting timer.")
            startTimer()
            updateMenuStates()
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Break in 30s"
        content.body = "Look away soon. It starts on time unless you snooze."
        content.sound = .default
        content.categoryIdentifier = HeadsUp.categoryID
        let identifier = UUID().uuidString
        lastHeadsUpID = identifier
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.error("Heads-up scheduling failed: \(error.localizedDescription)")
            }
        }
    }

    func clearHeadsUpState() {
        let center = UNUserNotificationCenter.current()
        if let lastHeadsUpID {
            center.removeDeliveredNotifications(withIdentifiers: [lastHeadsUpID])
            center.removePendingNotificationRequests(withIdentifiers: [lastHeadsUpID])
        }
        lastHeadsUpID = nil
    }

    /// Snooze means "come back in X from NOW" — the next fire is now+extra,
    /// never interval+extra. Invalidates any pending cycle and arms exactly
    /// `extra` (clamped >= 1s by startTimer).
    func deferBreak(by extra: TimeInterval) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.deferBreak(by: extra) }
            return
        }
        // A snooze tap while paused must not pretend to reschedule:
        // startTimer() early-returns when paused, silently dropping it.
        guard !isPaused else {
            logger.warning("Snooze +\(Int(extra))s ignored: app is paused (manual=\(self.isManuallyPaused) camera=\(self.isAutoPausedForVideoCall))")
            updateMenuStates()
            return
        }
        // Stale heads-up tap arriving while an overlay is up: close it first
        // (without arming a full interval) so the snooze isn't overwritten
        // when the overlay later dismisses.
        if !overlayWindows.isEmpty {
            logger.info("Deferring with overlay showing — dismissing first")
            dismissOverlayAndRestoreFocus(scheduleNext: false)
        }
        clearHeadsUpState()
        logger.info("Deferring break by \(Int(extra))s (next fire in \(Int(extra))s, not interval+\(Int(extra))s)")
        startTimer(withDelay: extra)
        updateMenuStates()
    }

    /// Overlay snooze button: dismiss now, come back in 5 minutes from now.
    func snoozeBreakForFiveMinutes() {
        // Check pause BEFORE dismissing: otherwise the overlay vanishes and
        // the snooze is dropped — the worst outcome (no break, no timer).
        guard !isPaused else {
            logger.warning("Overlay snooze ignored: app is paused (overlay stays up)")
            updateMenuStates()
            return
        }
        BreakSound.play(named: "Pop", reason: "snooze")
        dismissOverlayAndRestoreFocus(scheduleNext: false)
        deferBreak(by: 5 * 60)
    }

    // MARK: - Idle detection

    /// Seconds since the last keyboard/mouse/tablet event in this session.
    /// Must query kCGAnyInputEventType (~0); .null measures null events and
    /// misreports (Apple: "to get the elapsed time since the previous input
    /// event — keyboard, mouse, or tablet — specify kCGAnyInputEventType").
    func idleSeconds() -> TimeInterval {
        let anyInput = CGEventType(rawValue: ~UInt32(0)) ?? .null
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    func startIdleMonitoring() {
        idleMonitor?.invalidate()
        checkIdleAndResetIfNeeded()
        idleMonitor = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.checkIdleAndResetIfNeeded()
        }
        if let idleMonitor {
            RunLoop.main.add(idleMonitor, forMode: .common)
        }
    }

    /// While the user is away, keep postponing the break so it fires a full
    /// interval *after they return*, and never pops an overlay onto an empty desk.
    /// Latched per idle episode: resets once when idleness begins, not every
    /// 5s, so the countdown doesn't slide and the log doesn't spam.
    var idleResetLatched = false

    func checkIdleAndResetIfNeeded() {
        resumeScheduleIfPauseExpired(refreshManualPauseIfExpired())
        guard !isPaused else { return }
        guard UserDefaults.standard.bool(forKey: AppDefaults.resetOnIdle) else { return }
        guard overlayWindows.isEmpty else { return }
        let idle = idleSeconds()
        guard idle >= idleThreshold else {
            idleResetLatched = false
            return
        }
        guard !idleResetLatched else { return }
        idleResetLatched = true
        logger.info("User idle for \(Int(idle))s — resetting break timer.")
        startTimer()
        updateMenuStates()
    }

    // MARK: - Video-call auto-pause

    func startVideoCallMonitoring() {
        checkVideoCallState()
        cameraUsageMonitor?.invalidate()
        cameraUsageMonitor = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.checkVideoCallState()
        }
        if let cameraUsageMonitor {
            RunLoop.main.add(cameraUsageMonitor, forMode: .common)
        }
    }

    func checkVideoCallState() {
        let pauseExpired = refreshManualPauseIfExpired()

        let autoPauseEnabled = UserDefaults.standard.bool(forKey: AppDefaults.autoPauseForCamera)
        if !autoPauseEnabled {
            if isAutoPausedForVideoCall {
                isAutoPausedForVideoCall = false
                logger.info("Camera auto-pause disabled, resuming")
                applyPauseState()
            } else {
                resumeScheduleIfPauseExpired(pauseExpired)
            }
            updateMenuStates()
            return
        }

        let isCameraRunning = isAnyCameraRunningCMIO() || isAnyCaptureDeviceInUse()

        guard isAutoPausedForVideoCall != isCameraRunning else {
            resumeScheduleIfPauseExpired(pauseExpired)
            updateMenuStates()
            return
        }
        isAutoPausedForVideoCall = isCameraRunning
        if isAutoPausedForVideoCall {
            logger.info("Camera in use — auto-pausing breaks")
            dismissOverlayAndRestoreFocus(scheduleNext: false)
        } else {
            logger.info("Camera released — resuming breaks")
        }
        applyPauseState()
    }

    func isAnyCaptureDeviceInUse() -> Bool {
        var discoveryDeviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .externalUnknown
        ]
        if #available(macOS 14.0, *) {
            discoveryDeviceTypes.append(.deskViewCamera)
            discoveryDeviceTypes.append(.continuityCamera)
            discoveryDeviceTypes.append(.external)
        }

        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: discoveryDeviceTypes,
            mediaType: .video,
            position: .unspecified
        )

        return discoverySession.devices.contains(where: { $0.isInUseByAnotherApplication })
    }

    private func isAnyCameraRunningCMIO() -> Bool {
        var propertyAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )

        var dataSize: UInt32 = 0
        var dataUsed: UInt32 = 0
        var status = CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &propertyAddress, 0, nil, &dataSize)
        if status != noErr || dataSize == 0 { return false }

        let deviceCount = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        var deviceIDs = [CMIOObjectID](repeating: 0, count: deviceCount)

        status = CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &propertyAddress, 0, nil, dataSize, &dataUsed, &deviceIDs)
        if status != noErr { return false }

        for deviceID in deviceIDs {
            var classAddr = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIOObjectPropertyClass),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            var classID = UInt32(0)
            let classSize = UInt32(MemoryLayout.size(ofValue: classID))
            var classUsed: UInt32 = 0
            let classStatus = CMIOObjectGetPropertyData(deviceID, &classAddr, 0, nil, classSize, &classUsed, &classID)
            if classStatus != noErr { continue }
            if classID != kCMIODeviceClassID { continue }

            var runningAddr = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            var isRunning: UInt32 = 0
            let isRunningSize = UInt32(MemoryLayout.size(ofValue: isRunning))
            var isRunningUsed: UInt32 = 0
            let runStatus = CMIOObjectGetPropertyData(deviceID, &runningAddr, 0, nil, isRunningSize, &isRunningUsed, &isRunning)
            if runStatus == noErr && isRunning != 0 {
                return true
            }
        }
        return false
    }

    func applyPauseState() {
        if isPaused {
            timer?.invalidate()
            timer = nil
            headsUpTimer?.invalidate()
            headsUpTimer = nil
            nextFireDate = nil
            clearHeadsUpState()
            dismissOverlayAndRestoreFocus(scheduleNext: false)
        } else if overlayWindows.isEmpty {
            startTimer()
        } else {
            // Live overlay owns the next cycle (arms on dismissal) — don't
            // arm a concurrent timer underneath it (e.g. wake during a break).
            refreshCountdownItem()
        }

        updateStatusIcon()
        updateMenuStates()
    }

    /// Natural countdown expiry: completion chime once, then dismiss +
    /// reschedule. The hadOverlay check dedupes N-screen expiry (each screen's
    /// view crosses zero in the same second; only the winner chimes).
    func completeBreakNaturally() {
        if !overlayWindows.isEmpty {
            BreakSound.play(named: "Hero", reason: "break-end")
        }
        dismissOverlayAndRestoreFocus()
    }

    func updateStatusIcon() {
        guard let button = statusItem?.button else { return }

        if isPaused {
            button.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "Blink Reminder (Paused)")
            button.image?.isTemplate = true
            if isAutoPausedForVideoCall && !isManuallyPaused {
                button.setAccessibilityLabel("Blink Reminder (Paused for video call)")
            } else {
                button.setAccessibilityLabel("Blink Reminder (Paused)")
            }
            return
        }

        button.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "Blink Reminder")
        button.image?.isTemplate = true
    }

    // MARK: - Overlay + focus restore

    /// Closes every overlay window and returns keyboard focus to the app the
    /// user was in before the break — like Time Out / Stretchly / Big Stretch do.
    /// Safe to call multiple times and from any overlay dismissal path.
    /// When scheduleNext is true (natural expiry / Skip), arms the next full
    /// interval after completion. Snooze, pause, and camera paths pass false
    /// because they schedule differently (5m) or not at all (paused).
    func dismissOverlayAndRestoreFocus(scheduleNext: Bool = true) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.dismissOverlayAndRestoreFocus(scheduleNext: scheduleNext) }
            return
        }
        guard !overlayWindows.isEmpty || previouslyActiveApp != nil else { return }

        // Multi-screen safety: N views cross zero in the same second and all
        // call onDismiss. Only the first (non-empty) call may reschedule.
        let hadOverlay = !overlayWindows.isEmpty

        logger.info("Dismissing \(self.overlayWindows.count) overlay window(s)")
        // Release the SwiftUI hosting views before closing: close() alone may
        // not synchronously fire onDisappear, leaking per-window timers.
        overlayWindows.forEach {
            $0.contentView = nil
            $0.close()
        }
        overlayWindows.removeAll()

        let previous = previouslyActiveApp
        previouslyActiveApp = nil

        // Capture before deactivating: deactivation itself can flip
        // frontmostApplication and would force the hide path every time.
        let stillOurs = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
        NSApp.deactivate()

        // Only restore when the user is still sitting in our overlay. If they
        // Cmd-Tabbed elsewhere mid-break, yanking them back would steal focus
        // from where they chose to be.
        if stillOurs,
            let previous,
            !previous.isTerminated,
            previous.bundleIdentifier != Bundle.main.bundleIdentifier,
            let bundleID = previous.bundleIdentifier {
            logger.info("Restoring focus to \(bundleID)")
            DispatchQueue.main.async {
                if !previous.isTerminated {
                    previous.activate(options: [.activateAllWindows])
                }
            }
        } else {
            if !stillOurs {
                logger.info("Focus restore skipped: user already moved to another app")
            }
            NSApp.hide(nil)
        }

        // Next cycle arms HERE (completion), not at fire time: a full interval
        // after the user returns. Guarded so pause/camera/snooze dismissals
        // (scheduleNext:false) and duplicate multi-screen calls never restart.
        if scheduleNext, hadOverlay {
            rescheduleAfterBreak()
        }
    }

    /// Presents the break overlay. Runs synchronously when already on the main
    /// thread; hops to main only when called from a background thread.
    /// (The next cycle arms on dismissal, not here — see handleBreakFire.)
    func showOverlay() {
        if Thread.isMainThread {
            presentOverlayNow()
        } else {
            DispatchQueue.main.async { [weak self] in self?.presentOverlayNow() }
        }
    }

    private func presentOverlayNow() {
        dispatchPrecondition(condition: .onQueue(.main))

        let screenCount = NSScreen.screens.count
        let idle = idleSeconds()
        logger.info("showOverlay: screens=\(screenCount) overlayEnabled=\(self.overlayEnabled) paused=\(self.isPaused) idle=\(Int(idle))s threshold=\(Int(self.idleThreshold))s")
        guard screenCount > 0 else {
            logger.error("showOverlay: no screens available, cannot present overlay")
            return
        }

        if self.overlayWindows.isEmpty {
            if let front = NSWorkspace.shared.frontmostApplication,
               front.bundleIdentifier != Bundle.main.bundleIdentifier {
                self.previouslyActiveApp = front
            }
        }

        self.overlayWindows.forEach {
            $0.contentView = nil
            $0.close()
        }
        self.overlayWindows.removeAll()

        let enabled = UserDefaults.standard.bool(forKey: AppDefaults.motivationEnabled)
        let quotes = enabled ? Quotes.getActiveQuotes() : []
        // One quote per break so all screens agree (views must not each roll).
        let breakQuotes: [String]
        if let quote = quotes.randomElement() {
            breakQuotes = [quote]
        } else {
            breakQuotes = []
        }
        let isStrict = UserDefaults.standard.bool(forKey: AppDefaults.strictMode)
        let maxSkips = UserDefaults.standard.integer(forKey: AppDefaults.maxSkipsPerHour)
        let breakDuration = self.breakDurationSeconds

        let now = Date()
        self.skipTimestamps = self.skipTimestamps.filter { now.timeIntervalSince($0) < 3600 }
        let canSkip = (maxSkips == -1) || (self.skipTimestamps.count < maxSkips)

        for screen in NSScreen.screens {
            let window = OverlayWindow(frame: screen.frame)
            let view = OverlayView(
                onDismiss: { [weak self] in self?.dismissOverlayAndRestoreFocus() },
                onNaturalEnd: { [weak self] in self?.completeBreakNaturally() },
                onSkipAction: { [weak self] in
                    self?.skipTimestamps.append(Date())
                    if let self {
                        logger.info("Skip recorded (\(self.skipTimestamps.count) this hour window)")
                    }
                    BreakSound.play(named: "Bottle", reason: "skip")
                },
                onSnoozeAction: { [weak self] in self?.snoozeBreakForFiveMinutes() },
                quotes: breakQuotes,
                isStrict: isStrict,
                canSkip: canSkip,
                breakDuration: breakDuration
            )
            window.contentView = NSHostingView(rootView: view)
            // Float above normal windows; set before ordering to avoid flicker.
            window.level = .floating
            window.makeKeyAndOrderFront(nil)
            self.overlayWindows.append(window)
        }

        NSApp.activate(ignoringOtherApps: true)
        logger.info("Overlay shown on \(self.overlayWindows.count) window(s)")
        if self.overlayWindows.isEmpty {
            logger.error("showOverlay: no overlay windows created despite \(screenCount) screen(s)")
        } else {
            BreakSound.play(named: "Glass", reason: "break-start")
        }
    }

    func sendNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Time to Blink!"
        content.body = "Rest your eyes for \(breakDurationSeconds) seconds."
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        logger.info("Sent fallback notification (duration \(self.breakDurationSeconds)s)")
    }
}

// MARK: - Overlay Window

// Window recipe restored from the pre-P0 working build: a nonactivating
// floating panel ordered front per screen. (The P0 rewrite's borderless +
// .screenSaver combo never presented.)
final class OverlayWindow: NSPanel {
    init(frame: NSRect) {
        super.init(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
}

// MARK: - Overlay View (P0-3 minimal redesign)

private struct ProgressRing: View {
    var progress: Double // 1.0 -> 0.0

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 4)
            Circle()
                .trim(from: 0, to: max(0, min(1, progress)))
                .stroke(.primary, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

struct OverlayView: View {
    var onDismiss: () -> Void
    /// Natural countdown expiry (plays the completion chime). Skip uses
    /// onSkipAction + onDismiss so it gets its own dismiss sound instead.
    var onNaturalEnd: () -> Void
    var onSkipAction: () -> Void
    var onSnoozeAction: () -> Void
    var quotes: [String]
    var isStrict: Bool
    var canSkip: Bool
    var breakDuration: Int

    @State private var timeLeft: Int?
    @State private var timer: Timer.TimerPublisher = Timer.publish(every: 1, on: .main, in: .common)
    @State private var connectedTimer: Cancellable?
    @State private var isBreathing = false
    @State private var motivationText = ""
    @State private var isActive = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var total: Int { max(1, breakDuration) }
    private var remaining: Int { timeLeft ?? total }
    private var progress: Double { Double(remaining) / Double(total) }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
            Color.primary.opacity(0.08)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Image(systemName: "eye.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Text("Rest your eyes")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)

                if !motivationText.isEmpty {
                    Text(motivationText)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                ZStack {
                    ProgressRing(progress: progress)
                        .frame(width: 120, height: 120)
                    Text("\(remaining)")
                        .font(.system(size: 64, weight: .heavy, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .accessibilityLabel("Time remaining: \(remaining) seconds")
                }
                .frame(width: 140, height: 140)

                Circle()
                    .fill(.secondary)
                    .frame(width: 8, height: 8)
                    .scaleEffect(isBreathing ? 1.4 : 1.0)
                    .opacity(isBreathing ? 0.5 : 1.0)
                    .accessibilityHidden(true)
                    .onAppear {
                        guard !reduceMotion else { return }
                        withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
                            isBreathing = true
                        }
                    }

                if !isStrict && canSkip {
                    HStack(spacing: 16) {
                        Button {
                            onSkipAction()
                            onDismiss()
                        } label: {
                            Text("Skip")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)

                        Button {
                            onSnoozeAction()
                        } label: {
                            Text("Snooze +5m")
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent)
                        .clipShape(Capsule())
                    }
                    .padding(.top, 4)
                } else {
                    Text(isStrict ? "Strict Mode On" : "Skip Limit Reached")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: 480)
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .onAppear {
            isActive = true
            if timeLeft == nil {
                timeLeft = total
            }
            if motivationText.isEmpty {
                motivationText = quotes.randomElement() ?? ""
            }
            logger.info("OverlayView shown, countdown from \(self.total)s")
            connectedTimer = timer.connect()
        }
        .onDisappear {
            isActive = false
            connectedTimer?.cancel()
            connectedTimer = nil
            logger.info("OverlayView dismissed")
        }
        .onReceive(timer) { _ in
            guard isActive else { return }
            guard var left = timeLeft else { return }
            if left > 0 {
                left -= 1
                timeLeft = left
                logger.debug("Overlay countdown: \(left)s left")
                if left <= 0 {
                    onNaturalEnd()
                }
            } else {
                onNaturalEnd()
            }
        }
    }
}
