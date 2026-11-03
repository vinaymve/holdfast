// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
import Foundation
import HoldfastCore

// holdfast-cli — command-line front end for the Holdfast helper.

let usage = """
Usage: holdfast-cli <command> [options]

Commands:
  status                       Show the running block and next schedule
  start                        Start a block (asks for your admin password)
      --duration <2h|90m|1:30>   how long (a bare number is minutes)
      --until <17:30|5pm>        or: until the next time the clock reads this
      --site <host>              site to block (repeatable; host, host:port, ip/mask)
      --sites-file <path>        file with one entry per line
      --profile <name>           use a saved profile from the app
      --app </Applications/X.app>  app to block (repeatable)
      --allowlist                treat sites as an allowlist (block everything else)
  add                          Add sites/apps to the running block (--site / --app)
  extend <2h|30m>              Make the running block longer
  schedules                    List recurring schedules
  history                      Show completed blocks
  install | uninstall          Install or remove the privileged helper (asks for your admin password)
  ping                         Check that the helper is installed and responding
  version

"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())

func take(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag) else { return nil }
    guard i + 1 < args.count else { fail("\(flag) needs a value") }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}

func takeAll(_ flag: String) -> [String] {
    var values: [String] = []
    while let v = take(flag) { values.append(v) }
    return values
}

func takeFlag(_ flag: String) -> Bool {
    guard let i = args.firstIndex(of: flag) else { return false }
    args.remove(at: i)
    return true
}

#if DEBUG
// Development only: talk to an unprivileged dev daemon, without admin authorization.
let devService = take("--dev-service")
let devState = take("--dev-state")
#else
let devService: String? = nil
let devState: String? = nil
#endif
let client = devService.map { DaemonClient(serviceName: $0, privileged: false, requireAuthorization: false) } ?? DaemonClient()
let store = StateStore(path: devState ?? SC.stateFilePath)

guard let command = args.first else {
    print(usage)
    exit(0)
}
args.removeFirst()

func run(_ work: @escaping () async throws -> Void) -> Never {
    var failure: Error?
    let done = DispatchSemaphore(value: 0)
    Task {
        do { try await work() } catch { failure = error }
        done.signal()
    }
    done.wait()
    if let failure { fail(failure.localizedDescription) }
    exit(0)
}

func resolveApps(_ paths: [String]) -> [BlockedApp] {
    paths.map { path in
        guard let app = BlockedApp(appURL: URL(fileURLWithPath: path)) else { fail("\(path) is not an application bundle") }
        return app
    }
}

func readEntries(sites: [String], file: String?) -> [String] {
    var entries = sites
    if let file {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { fail("couldn't read \(file)") }
        entries += text.split(whereSeparator: \.isNewline).map(String.init)
    }
    return entries.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
}

func describe(_ block: ActiveBlock, now: Date = Date()) -> String {
    let kind = block.isAllowlist ? "allowlist" : "blocklist"
    let df = DateFormatter()
    df.dateStyle = .medium
    df.timeStyle = .short
    var lines = ["Block running: \(Format.clock(block.remaining(at: now))) left (ends \(df.string(from: block.displayEnd)))"]
    lines.append("  \(block.entries.count) site(s) as \(kind), \(block.apps.count) app(s)" + (block.profileName.map { ", profile '\($0)'" } ?? ""))
    lines.append("  started by: \(block.source.label)")
    return lines.joined(separator: "\n")
}

switch command {
case "version", "--version":
    print("holdfast-cli \(SC.version)")

case "ping":
    print(HelperInstaller.isInstalled ? "Helper binary: installed" : "Helper binary: not installed")
    run {
        let version = try await client.version()
        print("Helper responded: version \(version) (this CLI is \(SC.version))")
    }

case "status":
    let state = store.load()
    if let block = state.activeBlock {
        print(describe(block))
    } else {
        print("No block is running.")
    }
    let now = Date()
    let next = state.schedules.compactMap { s in s.nextStart(after: now).map { (s, $0) } }.min { $0.1 < $1.1 }
    if let (schedule, start) = next {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        print("Next schedule: '\(schedule.name)' at \(df.string(from: start))")
    }

case "start":
    let sites = takeAll("--site")
    let file = take("--sites-file")
    let profileName = take("--profile")
    let apps = takeAll("--app")
    var allowlist = takeFlag("--allowlist")
    let durationText = take("--duration")
    let untilText = take("--until")

    let length: BlockLength
    switch (durationText, untilText) {
    case (let d?, nil):
        guard let minutes = DurationParser.minutes(from: d) else { fail("couldn't understand duration '\(d)'") }
        length = .duration(minutes: minutes)
    case (nil, let u?):
        guard let t = TimeOfDay.parse(u) else { fail("couldn't understand time '\(u)'") }
        length = .until(hour: t.hour, minute: t.minute)
    default:
        fail("give exactly one of --duration or --until")
    }

    var entries = readEntries(sites: sites, file: file)
    var blockedApps = resolveApps(apps)
    if let profileName {
        guard let profile = ProfileStore().load().first(where: { $0.name.caseInsensitiveCompare(profileName) == .orderedSame }) else {
            fail("no profile named '\(profileName)'")
        }
        entries += profile.entries
        blockedApps += profile.apps
        allowlist = allowlist || profile.isAllowlist
    }

    let end = length.endDate(from: Date())
    let request = BlockRequest(entries: entries, isAllowlist: allowlist, endDate: end, apps: blockedApps, profileName: profileName)
    print("Starting block until \(end.formatted(date: .abbreviated, time: .shortened)) (\(Format.duration(end.timeIntervalSinceNow)))…")
    run {
        try await client.startBlock(request)
        print("Block started. It cannot be turned off until it ends.")
    }

case "add":
    let entries = readEntries(sites: takeAll("--site"), file: take("--sites-file"))
    let apps = resolveApps(takeAll("--app"))
    guard !entries.isEmpty || !apps.isEmpty else { fail("nothing to add; use --site or --app") }
    run {
        try await client.addToBlock(BlockAddition(entries: entries, apps: apps))
        print("Added to the running block.")
    }

case "extend":
    guard let text = args.first, let minutes = DurationParser.minutes(from: text) else { fail("usage: extend <2h|30m>") }
    guard let block = store.load().activeBlock else { fail("no block is running") }
    let newEnd = block.endDate.addingTimeInterval(TimeInterval(minutes) * 60)
    run {
        try await client.extendBlock(to: newEnd)
        print("Block now ends \(newEnd.formatted(date: .abbreviated, time: .shortened)).")
    }

case "schedules":
    let schedules = store.load().schedules
    if schedules.isEmpty { print("No schedules. Create them in the app.") }
    let names = Calendar.current.shortWeekdaySymbols
    for s in schedules {
        let days = s.weekdays.sorted().map { names[$0 - 1] }.joined(separator: " ")
        let end = s.endTimeOfDay
        print(String(format: "%@ %@  %@  %02d:%02d–%02d:%02d  profile '%@'", s.enabled ? "●" : "○", s.name, days,
                     s.startHour, s.startMinute, end.hour, end.minute, s.profile.name))
    }

case "history":
    let history = store.load().history.suffix(20)
    if history.isEmpty { print("No completed blocks yet.") }
    for h in history.reversed() {
        print("\(h.startDate.formatted(date: .abbreviated, time: .shortened))  \(Format.duration(h.duration))  \(h.profileName ?? "—")  [\(h.source.label)]")
    }

case "install":
    guard let helper = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("holdfastd"),
          FileManager.default.fileExists(atPath: helper.path) else { fail("holdfastd not found next to this tool") }
    run {
        try await HelperInstaller.install(bundledHelper: helper)
        print("Helper installed.")
    }

case "uninstall":
    run {
        try await HelperInstaller.uninstall()
        print("Helper removed.")
    }

case "help", "--help", "-h":
    print(usage)

default:
    fail("unknown command '\(command)'\n\n\(usage)")
}
