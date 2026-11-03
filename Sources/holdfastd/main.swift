// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
import Foundation
import HoldfastCore

// holdfastd — the privileged helper. Normally launched by launchd as root.
//
//   holdfastd                       run the daemon
//   holdfastd --version
//   holdfastd --can-uninstall       exit 0 if no block is running
//   holdfastd --emergency-clear     (root) remove every block rule and forget the active block
//   holdfastd --dev-root DIR [--service NAME]      (debug builds only)
//                                      unprivileged development mode: sandboxed hosts/pf files under DIR,
//                                      pfctl commands only recorded, no admin authorization required.
//                                      Refuses to run as root.

setvbuf(stdout, nil, _IOLBF, 0)
let args = Array(CommandLine.arguments.dropFirst())

func value(after flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

if args.contains("--version") {
    print(SC.version)
    exit(0)
}

if args.contains("--can-uninstall") {
    let state = StateStore().load()
    exit(state.activeBlock == nil ? 0 : 1)
}

if args.contains("--emergency-clear") {
    guard geteuid() == 0 else {
        FileHandle.standardError.write(Data("--emergency-clear must be run as root (sudo).\n".utf8))
        exit(1)
    }
    let cleared = EmergencyClear().run()
    print(cleared ? "Block rules removed." : "Some block rules could not be removed; check /etc/hosts and /etc/pf.conf.")
    exit(cleared ? 0 : 2)
}

var options = DaemonOptions()
#if DEBUG
// Development only. Compiled out of release builds, so the shipped root daemon has no way to turn authorization off.
if let root = value(after: "--dev-root") {
    guard geteuid() != 0 else {
        FileHandle.standardError.write(Data("--dev-root is for unprivileged development and refuses to run as root.\n".utf8))
        exit(1)
    }
    do {
        options.paths = try SystemPaths.sandbox(root: root)
    } catch {
        FileHandle.standardError.write(Data("Couldn't create dev sandbox at \(root): \(error)\n".utf8))
        exit(1)
    }
    let log = root + "/commands.log"
    options.runner = RecordingRunner { path, args in
        if let handle = FileHandle(forWritingAtPath: log) ?? {
            FileManager.default.createFile(atPath: log, contents: nil)
            return FileHandle(forWritingAtPath: log)
        }() {
            handle.seekToEndOfFile()
            handle.write(Data(([path] + args).joined(separator: " ").appending("\n").utf8))
            try? handle.close()
        }
        return RecordingRunner.defaultResponder(path, args)
    }
    options.scraper = NoScraper()
    options.requireAuthorization = false
    if let service = value(after: "--service") { options.serviceName = service }
    print("holdfastd dev mode: sandbox \(root), service \(options.serviceName)")
}
#endif

let daemon = Daemon(options: options)
daemon.start()
RunLoop.main.run()
