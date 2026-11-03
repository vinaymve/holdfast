// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
import Foundation
import HoldfastCore

struct DaemonOptions {
    var serviceName = SC.serviceName
    var paths = SystemPaths.production
    var runner: CommandRunner = ProcessRunner()
    var scraper: LinkScraping = HTTPLinkScraper()
    /// Only ever false in unprivileged dev mode (see main.swift).
    var requireAuthorization = true
}

/// Owns the XPC listener and a one-second timer. All state changes happen on `queue`, one at a time,
/// so a checkup can never interleave with a block being started.
final class Daemon: NSObject, NSXPCListenerDelegate, SCDaemonProtocol {
    private let options: DaemonOptions
    private let controller: BlockController
    private let queue = DispatchQueue(label: "dev.holdfast.daemon.work")
    private let listener: NSXPCListener
    private var timer: DispatchSourceTimer?
    private var lastNetworkTimeQuery = Date.distantPast

    init(options: DaemonOptions) {
        self.options = options
        controller = BlockController(paths: options.paths, runner: options.runner, scraper: options.scraper)
        listener = NSXPCListener(machServiceName: options.serviceName)
        super.init()
        listener.delegate = self
        controller.onChange = {
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name(SC.configurationChangedNotification), object: nil, userInfo: nil,
                options: [.deliverImmediately, .postToAllSessions])
        }
    }

    func start() {
        if options.requireAuthorization { SCAuthorization.registerRights() }
        listener.resume()

        // The daemon stays resident (unlike the original, which exited when idle) because schedules
        // need something awake to start them.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.controller.tick()
            self?.askForNetworkTimeIfNeeded()
        }
        timer.resume()
        self.timer = timer
    }

    /// After a reboot mid-block the daemon can't tell a moved clock from time spent powered off, so it asks NTP.
    /// The query blocks, so it runs off the work queue and reports back onto it.
    private func askForNetworkTimeIfNeeded() {
        guard controller.wantsNetworkTime, Date().timeIntervalSince(lastNetworkTimeQuery) >= 20 else { return }
        lastNetworkTimeQuery = Date()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let network = NetworkTime.current() else { return }
            self?.queue.async { self?.controller.applyNetworkTime(network) }
        }
    }

    // MARK: NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Optional hardening for signed builds: set SC_CLIENT_REQUIREMENT (a code-signing requirement string)
        // in the LaunchDaemon plist's EnvironmentVariables to restrict who may connect.
        if let requirement = ProcessInfo.processInfo.environment["SC_CLIENT_REQUIREMENT"], !requirement.isEmpty {
            connection.setCodeSigningRequirement(requirement)
        }
        connection.exportedInterface = NSXPCInterface(with: SCDaemonProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    // MARK: SCDaemonProtocol

    private func authorized(_ data: Data, right: String) -> Bool {
        !options.requireAuthorization || SCAuthorization.verify(data, right: right)
    }

    private func nsError(_ error: Error) -> NSError {
        if let sc = error as? SCError { return sc.nsError }
        return SCError(.invalidRequest, error.localizedDescription).nsError
    }

    private func mutate(right: String, authorization: Data, reply: @escaping (NSError?) -> Void,
                        _ work: @escaping () throws -> Void) {
        queue.async { [self] in
            guard authorized(authorization, right: right) else { return reply(SCError(.notAuthorized).nsError) }
            do {
                try work()
                reply(nil)
            } catch {
                NSLog("ERROR: %@", "\(error)")
                reply(nsError(error))
            }
        }
    }

    func startBlock(_ request: Data, authorization: Data, reply: @escaping (NSError?) -> Void) {
        mutate(right: SC.startRight, authorization: authorization, reply: reply) { [self] in
            try controller.startBlock(Coding.decoder().decode(BlockRequest.self, from: request))
        }
    }

    func addToBlock(_ addition: Data, authorization: Data, reply: @escaping (NSError?) -> Void) {
        mutate(right: SC.modifyRight, authorization: authorization, reply: reply) { [self] in
            try controller.addToBlock(Coding.decoder().decode(BlockAddition.self, from: addition))
        }
    }

    func extendBlock(to newEndDate: Date, authorization: Data, reply: @escaping (NSError?) -> Void) {
        mutate(right: SC.modifyRight, authorization: authorization, reply: reply) { [self] in
            try controller.extendBlock(to: newEndDate)
        }
    }

    func saveSchedules(_ schedules: Data, authorization: Data, reply: @escaping (NSError?) -> Void) {
        mutate(right: SC.modifyRight, authorization: authorization, reply: reply) { [self] in
            try controller.saveSchedules(Coding.decoder().decode([Schedule].self, from: schedules))
        }
    }

    func getVersion(reply: @escaping (String) -> Void) {
        reply(SC.version)
    }

    func getState(reply: @escaping (Data?) -> Void) {
        queue.async { [self] in
            reply(try? Coding.encoder().encode(controller.state))
        }
    }
}
