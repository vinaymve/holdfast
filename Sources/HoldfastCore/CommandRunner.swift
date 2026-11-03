// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
import Foundation

public struct CommandResult {
    public let status: Int32
    public let output: String
    public init(status: Int32, output: String = "") {
        self.status = status
        self.output = output
    }
}

public protocol CommandRunner {
    @discardableResult
    func run(_ path: String, _ args: [String]) -> CommandResult
}

public struct ProcessRunner: CommandRunner {
    public init() {}

    @discardableResult
    public func run(_ path: String, _ args: [String]) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, output: "\(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

/// Records commands instead of running them. Used for sandbox/dev mode and tests.
public final class RecordingRunner: CommandRunner {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    public var responder: (String, [String]) -> CommandResult

    public init(responder: @escaping (String, [String]) -> CommandResult = RecordingRunner.defaultResponder) {
        self.responder = responder
    }

    public static let defaultResponder: (String, [String]) -> CommandResult = { path, args in
        if path.hasSuffix("pfctl"), args.contains("-E") {
            return CommandResult(status: 0, output: "pfctl: pf already enabled\nToken : 424242\n")
        }
        return CommandResult(status: 0)
    }

    public var commands: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    @discardableResult
    public func run(_ path: String, _ args: [String]) -> CommandResult {
        lock.lock()
        recorded.append([path] + args)
        lock.unlock()
        return responder(path, args)
    }
}
