// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
import SwiftUI
import AppKit
import HoldfastCore
import UserNotifications

enum LengthMode: String, CaseIterable, Identifiable {
    case duration, until
    var id: String { rawValue }
}

enum HelperStatus: Equatable {
    case checking, notInstalled, notRunning, outdated, ready
}

enum AppSection: String, CaseIterable, Identifiable {
    case block, profiles, schedules, stats
    var id: String { rawValue }

    var title: String {
        switch self {
        case .block: return "Block"
        case .profiles: return "Profiles"
        case .schedules: return "Schedules"
        case .stats: return "Stats"
        }
    }

    var symbol: String {
        switch self {
        case .block: return "shield.lefthalf.filled"
        case .profiles: return "list.bullet.rectangle"
        case .schedules: return "calendar.badge.clock"
        case .stats: return "chart.bar.xaxis"
        }
    }
}

enum Pref {
    static let maxBlockMinutes = "maxBlockMinutes"
    static let clearCaches = "clearCaches"
    static let allowLocalNetworks = "allowLocalNetworks"
    static let evaluateCommonSubdomains = "evaluateCommonSubdomains"
    static let includeLinkedDomains = "includeLinkedDomains"
    static let playEndSound = "playEndSound"
    static let endSoundName = "endSoundName"
    static let notifyOnEnd = "notifyOnEnd"
    static let suppressLongBlockWarning = "suppressLongBlockWarning"
    static let firstBlockStarted = "firstBlockStarted"

    static let lengthMode = "ui.lengthMode"
    static let hours = "ui.hours"
    static let minutes = "ui.minutes"
    static let untilMinutes = "ui.untilMinutes"
    static let selectedProfile = "ui.selectedProfile"

    static let soundNames = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]
}

@MainActor
@Observable
final class AppModel {
    var section: AppSection = .block
    private(set) var state = DaemonState()
    private(set) var now = Date()
    private(set) var helper: HelperStatus = .checking

    var profiles: [Profile]
    var selectedProfileID: UUID?

    var lengthMode: LengthMode
    var hours: Int
    var minutes: Int
    var untilTime: Date

    var isBusy = false
    var errorMessage: String?

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let profileStore = ProfileStore()
    #if DEBUG
    /// Dev hook (debug builds only): `-stateFile <path>` points the app at a sample or dev-daemon state file.
    @ObservationIgnored private let stateStore = StateStore(path: UserDefaults.standard.string(forKey: "stateFile") ?? SC.stateFilePath)
    #else
    @ObservationIgnored private let stateStore = StateStore()
    #endif
    @ObservationIgnored private let client = DaemonClient()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastStateModified: Date?
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var notificationEnd: Date?
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        let d = UserDefaults.standard
        d.register(defaults: [
            Pref.maxBlockMinutes: 1440, Pref.clearCaches: true, Pref.allowLocalNetworks: true,
            Pref.evaluateCommonSubdomains: true, Pref.includeLinkedDomains: true, Pref.playEndSound: false,
            Pref.endSoundName: "Glass", Pref.notifyOnEnd: true, Pref.hours: 1, Pref.minutes: 0,
            Pref.untilMinutes: 17 * 60,
        ])
        let loadedProfiles = ProfileStore().load()
        profiles = loadedProfiles
        #if DEBUG
        // Dev hook (debug builds only): `-section stats` opens on that screen.
        section = d.string(forKey: "section").flatMap(AppSection.init(rawValue:)) ?? .block
        #endif
        selectedProfileID = d.string(forKey: Pref.selectedProfile).flatMap(UUID.init) ?? loadedProfiles.first?.id
        lengthMode = LengthMode(rawValue: d.string(forKey: Pref.lengthMode) ?? "") ?? .duration
        hours = d.integer(forKey: Pref.hours)
        minutes = d.integer(forKey: Pref.minutes)
        let um = d.integer(forKey: Pref.untilMinutes)
        untilTime = Calendar.current.date(bySettingHour: um / 60, minute: um % 60, second: 0, of: Date()) ?? Date()
    }

    // MARK: Lifecycle

    func start() {
        guard timer == nil else { return }
        reloadState(force: true)
        Task { await refreshHelperStatus() }
        requestNotificationPermission()

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(SC.configurationChangedNotification), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadState(force: true) }
        }
    }

    private func tick() {
        now = Date()
        tickCount += 1
        if tickCount % 2 == 0 { reloadState(force: false) }
        if tickCount % 15 == 0, helper != .ready || state.activeBlock == nil { Task { await refreshHelperStatus() } }
    }

    // MARK: Derived values

    /// The running block, as recorded by the daemon. It stays "running" (at 00:00:00) until the daemon has
    /// removed the rules, which can take a moment, or longer while it confirms the time after a reboot.
    var activeBlock: ActiveBlock? { state.activeBlock }

    var selectedProfile: Profile? { profiles.first { $0.id == selectedProfileID } ?? profiles.first }

    var maxBlockMinutes: Int {
        let v = defaults.integer(forKey: Pref.maxBlockMinutes)
        return v > 0 ? v : 1440
    }

    var plannedLength: BlockLength {
        switch lengthMode {
        case .duration:
            return .duration(minutes: hours * 60 + minutes)
        case .until:
            let c = Calendar.current.dateComponents([.hour, .minute], from: untilTime)
            return .until(hour: c.hour ?? 0, minute: c.minute ?? 0)
        }
    }

    var plannedEnd: Date { plannedLength.endDate(from: now) }
    var plannedSeconds: TimeInterval { plannedEnd.timeIntervalSince(now) }

    var lengthProblem: String? {
        if plannedSeconds < 60 { return "Pick a length of at least one minute." }
        if Int(plannedSeconds / 60) > maxBlockMinutes {
            return "That's longer than your \(Format.duration(TimeInterval(maxBlockMinutes) * 60)) limit. You can raise it in Settings."
        }
        return nil
    }

    var plannedEndDescription: String {
        let end = plannedEnd, cal = Calendar.current
        let day = cal.isDateInToday(end) ? "today" : cal.isDateInTomorrow(end) ? "tomorrow" : end.formatted(.dateTime.weekday(.wide).month().day())
        return "Ends \(day) at \(end.formatted(date: .omitted, time: .shortened)) · \(Format.duration(plannedSeconds)) from now"
    }

    var canStart: Bool {
        guard !isBusy, activeBlock == nil, lengthProblem == nil, let profile = selectedProfile else { return false }
        return !profile.isEmpty
    }

    var stats: BlockStats { BlockStats.compute(history: state.history, active: activeBlock, now: now) }

    // MARK: State

    func reloadState(force: Bool) {
        let modified = (try? FileManager.default.attributesOfItem(atPath: stateStore.path)[.modificationDate]) as? Date
        if !force, modified == lastStateModified { return }
        lastStateModified = modified

        let previous = state.activeBlock
        state = stateStore.load()
        now = Date()

        if let previous, state.activeBlock == nil, previous.displayEnd <= now.addingTimeInterval(2) {
            blockDidEnd(previous)
        }
        scheduleEndNotification()
    }

    private func blockDidEnd(_ block: ActiveBlock) {
        if block.options.playEndSound { NSSound(named: NSSound.Name(block.options.endSoundName))?.play() }
    }

    func refreshHelperStatus() async {
        guard HelperInstaller.isInstalled else { helper = .notInstalled; return }
        if let bundled = bundledHelperURL, HelperInstaller.isOutdated(comparedTo: bundled) { helper = .outdated; return }
        do {
            _ = try await client.version()
            helper = .ready
        } catch {
            helper = .notRunning
        }
    }

    var bundledHelperURL: URL? { Bundle.main.url(forAuxiliaryExecutable: "holdfastd") }

    /// Settings button: (re)install the helper on its own.
    func installHelper() async {
        isBusy = true
        defer { isBusy = false }
        _ = await ensureHelper(force: true, right: nil)
    }

    /// Makes sure the privileged helper is installed, current and answering, installing or updating it
    /// (one admin prompt) if not. Starting a block, saving a schedule, etc. call this first, so there is no
    /// separate "set up" step. Returns false if it couldn't be made ready (the user is told why, unless they
    /// simply cancelled the prompt).
    private func ensureHelper(force: Bool = false, right: String? = SC.modifyRight) async -> Bool {
        if !force {
            await refreshHelperStatus()
            if helper == .ready { return true }
        }
        guard let bundled = bundledHelperURL else {
            errorMessage = "The helper isn't bundled with this build. Use Scripts/build-app.sh to build Holdfast.app."
            return false
        }
        // Authenticate once, up front, for the right the caller is about to need, then install with that same
        // authorization session and hand it on to the privileged call. Skipped if the right isn't registered yet
        // (first-ever install): the daemon creates it on first launch.
        var session: SCAuthorization.Ticket?
        if let right, SCAuthorization.isRegistered(right) {
            do { session = try SCAuthorization.obtain(right: right) } catch { report(error); return false }
        }
        do {
            try await HelperInstaller.install(bundledHelper: bundled, authorization: session)
        } catch {
            report(error)
            return false
        }
        client.preauthorize(session)
        // The new daemon needs a moment to register with launchd and set up its authorization rights.
        for _ in 0..<12 {
            await refreshHelperStatus()
            if helper == .ready { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        errorMessage = "The helper was installed but isn't responding yet. Try again in a moment."
        return false
    }

    /// Cancelling an admin prompt is a choice, not an error: stay quiet.
    private func report(_ error: Error) {
        if let sc = error as? SCError, sc.code == .notAuthorized, sc.detail?.lowercased().contains("cancel") == true { return }
        errorMessage = error.localizedDescription
    }

    func uninstallHelper() async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await HelperInstaller.uninstall()
            await refreshHelperStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Persistence of UI choices

    func saveLengthChoice() {
        defaults.set(lengthMode.rawValue, forKey: Pref.lengthMode)
        defaults.set(hours, forKey: Pref.hours)
        defaults.set(minutes, forKey: Pref.minutes)
        let c = Calendar.current.dateComponents([.hour, .minute], from: untilTime)
        defaults.set((c.hour ?? 0) * 60 + (c.minute ?? 0), forKey: Pref.untilMinutes)
    }

    func selectProfile(_ id: UUID) {
        selectedProfileID = id
        defaults.set(id.uuidString, forKey: Pref.selectedProfile)
    }

    func setDuration(totalMinutes: Int) {
        hours = totalMinutes / 60
        minutes = totalMinutes % 60
        lengthMode = .duration
        saveLengthChoice()
    }

    func setUntil(hour: Int, minute: Int) {
        untilTime = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? untilTime
        lengthMode = .until
        saveLengthChoice()
    }

    // MARK: Profiles

    func saveProfiles() { profileStore.save(profiles) }

    func updateProfile(_ profile: Profile) {
        guard let i = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[i] = profile
        saveProfiles()
    }

    @discardableResult
    func addProfile(named name: String = "New Profile") -> Profile {
        let profile = Profile(name: name)
        profiles.append(profile)
        saveProfiles()
        selectProfile(profile.id)
        return profile
    }

    func duplicateProfile(_ profile: Profile) {
        var copy = profile
        copy.id = UUID()
        copy.name += " Copy"
        profiles.append(copy)
        saveProfiles()
    }

    func deleteProfile(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        if profiles.isEmpty { profiles = [Profile(name: "My Blocklist")] }
        if selectedProfileID == id { selectProfile(profiles[0].id) }
        saveProfiles()
    }

    // MARK: Actions

    func currentOptions() -> BlockOptions {
        var o = BlockOptions()
        o.clearCaches = defaults.bool(forKey: Pref.clearCaches)
        o.allowLocalNetworks = defaults.bool(forKey: Pref.allowLocalNetworks)
        o.evaluateCommonSubdomains = defaults.bool(forKey: Pref.evaluateCommonSubdomains)
        o.includeLinkedDomains = defaults.bool(forKey: Pref.includeLinkedDomains)
        o.playEndSound = defaults.bool(forKey: Pref.playEndSound)
        o.endSoundName = defaults.string(forKey: Pref.endSoundName) ?? "Glass"
        return o
    }

    /// Starts a block with the selected profile. `minutes` overrides the length picker (menu bar quick-start).
    func startBlock(minutes quickMinutes: Int? = nil) async {
        guard let profile = selectedProfile, !isBusy else { return }
        if quickMinutes == nil, let problem = lengthProblem { errorMessage = problem; return }
        // Used for the confirmation text only: the real end time is computed once the helper is ready,
        // so time spent at the admin prompts doesn't eat into the block.
        let endEstimate = quickMinutes.map { Date().addingTimeInterval(TimeInterval($0) * 60) } ?? plannedEnd
        guard confirmStart(profile: profile, end: endEstimate) else { return }

        isBusy = true
        defer { isBusy = false }
        guard await ensureHelper(right: SC.startRight) else { return }
        let end = quickMinutes.map { Date().addingTimeInterval(TimeInterval($0) * 60) } ?? plannedLength.endDate(from: Date())
        do {
            let request = BlockRequest(entries: profile.entries, isAllowlist: profile.isAllowlist, endDate: end,
                                       apps: profile.apps, options: currentOptions(), profileName: profile.name)
            try await client.startBlock(request)
            defaults.set(true, forKey: Pref.firstBlockStarted)
            helper = .ready
            reloadState(force: true)
        } catch {
            report(error)
        }
    }

    func addSites(_ text: String) async {
        let entries = text.split(whereSeparator: { $0.isNewline || $0 == "," || $0 == " " }).map(String.init)
        guard !entries.isEmpty else { return }
        await modify { try await self.client.addToBlock(BlockAddition(entries: entries)) }
    }

    func extend(byMinutes extra: Int) async {
        guard let block = state.activeBlock else { return }
        let newEnd = block.endDate.addingTimeInterval(TimeInterval(extra) * 60)
        await modify { try await self.client.extendBlock(to: newEnd) }
    }

    func saveSchedules(_ schedules: [Schedule]) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        guard await ensureHelper() else { return false }
        do {
            try await client.saveSchedules(schedules)
            reloadState(force: true)
            return true
        } catch {
            report(error)
            return false
        }
    }

    private func modify(_ work: @escaping () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await work()
            reloadState(force: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Confirmations

    private func runningBlockedApps(_ profile: Profile) -> [String] {
        let ids = Set(profile.apps.map(\.bundleID))
        return NSWorkspace.shared.runningApplications
            .filter { app in app.bundleIdentifier.map(ids.contains) ?? false }
            .compactMap(\.localizedName)
    }

    private func confirmStart(profile: Profile, end: Date) -> Bool {
        var paragraphs: [String] = []
        let minutes = Int(end.timeIntervalSinceNow / 60)
        let isFirst = !defaults.bool(forKey: Pref.firstBlockStarted)
        let warnLong = !defaults.bool(forKey: Pref.suppressLongBlockWarning) && (minutes >= 2880 || (isFirst && minutes >= 480))
        if warnLong {
            paragraphs.append("Once you start, you can't turn the block off until the timer ends in \(Format.duration(end.timeIntervalSinceNow)), even if you blocked a site you need. Consider a shorter block first to check your list.")
        }
        let running = runningBlockedApps(profile)
        if !running.isEmpty {
            paragraphs.append("These blocked apps are open and will be force-quit right away, so unsaved work in them will be lost: \(running.joined(separator: ", ")).")
        }
        guard !paragraphs.isEmpty else { return true }

        let alert = NSAlert()
        alert.messageText = warnLong ? "That's a long block!" : "Start the block?"
        alert.informativeText = paragraphs.joined(separator: "\n\n")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Start Block")
        if warnLong { alert.showsSuppressionButton = true }
        let response = alert.runModal()
        if warnLong, alert.suppressionButton?.state == .on { defaults.set(true, forKey: Pref.suppressLongBlockWarning) }
        return response == .alertSecondButtonReturn
    }

    // MARK: Notifications

    private var canNotify: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    private func requestNotificationPermission() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// A local notification fires at the block's end even if the app has been quit.
    private func scheduleEndNotification() {
        guard canNotify else { return }
        let center = UNUserNotificationCenter.current()
        guard let block = state.activeBlock, block.displayEnd > Date(), defaults.bool(forKey: Pref.notifyOnEnd) else {
            center.removePendingNotificationRequests(withIdentifiers: ["block-end"])
            notificationEnd = nil
            return
        }
        guard notificationEnd != block.displayEnd else { return }
        notificationEnd = block.displayEnd

        let content = UNMutableNotificationContent()
        content.title = "Block finished"
        content.body = "Your block has ended. Nice work staying focused."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, block.displayEnd.timeIntervalSinceNow), repeats: false)
        center.add(UNNotificationRequest(identifier: "block-end", content: content, trigger: trigger))
    }
}
