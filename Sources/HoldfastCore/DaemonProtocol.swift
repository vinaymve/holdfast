// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
import Foundation

/// The daemon's XPC surface. Payloads are JSON `Data` so the interface needs no custom NSSecureCoding classes.
@objc public protocol SCDaemonProtocol {
    func startBlock(_ request: Data, authorization: Data, reply: @escaping (NSError?) -> Void)
    func addToBlock(_ addition: Data, authorization: Data, reply: @escaping (NSError?) -> Void)
    func extendBlock(to newEndDate: Date, authorization: Data, reply: @escaping (NSError?) -> Void)
    func saveSchedules(_ schedules: Data, authorization: Data, reply: @escaping (NSError?) -> Void)
    func getVersion(reply: @escaping (String) -> Void)
    func getState(reply: @escaping (Data?) -> Void)
}

/// Talks to the daemon. `requireAuthorization: false` is only for the unprivileged dev daemon.
public final class DaemonClient {
    private let serviceName: String
    private let privileged: Bool
    private let requireAuthorization: Bool

    public init(serviceName: String = SC.serviceName, privileged: Bool = true, requireAuthorization: Bool = true) {
        self.serviceName = serviceName
        self.privileged = privileged
        self.requireAuthorization = requireAuthorization
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func fire() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if fired { return false }
            fired = true
            return true
        }
    }

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: serviceName, options: privileged ? .privileged : [])
        connection.remoteObjectInterface = NSXPCInterface(with: SCDaemonProtocol.self)
        connection.resume()
        return connection
    }

    private func authorization(for right: String) throws -> SCAuthorization.Ticket? {
        requireAuthorization ? try SCAuthorization.obtain(right: right) : nil
    }

    private func perform(right: String, _ invoke: @escaping (SCDaemonProtocol, Data, @escaping (NSError?) -> Void) -> Void) async throws {
        // The ticket must outlive the XPC call: the daemon validates the authorization after we send it.
        let ticket = try authorization(for: right)
        let auth = ticket?.externalForm ?? Data()
        let connection = makeConnection()
        defer {
            connection.invalidate()
            withExtendedLifetime(ticket) {}
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once()
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                if once.fire() { continuation.resume(throwing: SCError(.helperUnavailable, error.localizedDescription)) }
            } as? SCDaemonProtocol
            guard let proxy else {
                if once.fire() { continuation.resume(throwing: SCError(.helperUnavailable)) }
                return
            }
            invoke(proxy, auth) { error in
                guard once.fire() else { return }
                if let error { continuation.resume(throwing: SCError.unwrap(error)) } else { continuation.resume() }
            }
        }
    }

    public func startBlock(_ request: BlockRequest) async throws {
        let data = try Coding.encoder().encode(request)
        try await perform(right: SC.startRight) { proxy, auth, reply in
            proxy.startBlock(data, authorization: auth, reply: reply)
        }
    }

    public func addToBlock(_ addition: BlockAddition) async throws {
        let data = try Coding.encoder().encode(addition)
        try await perform(right: SC.modifyRight) { proxy, auth, reply in
            proxy.addToBlock(data, authorization: auth, reply: reply)
        }
    }

    public func extendBlock(to newEnd: Date) async throws {
        try await perform(right: SC.modifyRight) { proxy, auth, reply in
            proxy.extendBlock(to: newEnd, authorization: auth, reply: reply)
        }
    }

    public func saveSchedules(_ schedules: [Schedule]) async throws {
        let data = try Coding.encoder().encode(schedules)
        try await perform(right: SC.modifyRight) { proxy, auth, reply in
            proxy.saveSchedules(data, authorization: auth, reply: reply)
        }
    }

    /// The daemon's version string, or an error if it can't be reached within `timeout` seconds.
    public func version(timeout: TimeInterval = 2) async throws -> String {
        let connection = makeConnection()
        defer { connection.invalidate() }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let once = Once()
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                if once.fire() { continuation.resume(throwing: SCError(.helperUnavailable, error.localizedDescription)) }
            } as? SCDaemonProtocol
            guard let proxy else {
                if once.fire() { continuation.resume(throwing: SCError(.helperUnavailable)) }
                return
            }
            proxy.getVersion { version in
                if once.fire() { continuation.resume(returning: version) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.fire() { continuation.resume(throwing: SCError(.helperUnavailable, "Timed out.")) }
            }
        }
    }
}
