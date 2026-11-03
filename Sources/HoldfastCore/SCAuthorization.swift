// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
import Foundation
import Security

/// Admin authorization via Authorization Services, as in the original's SCXPCAuthorization.
/// The client prompts for the admin password (or Touch ID); the daemon re-checks the resulting
/// reference without prompting. This is what stops an arbitrary local process from starting or editing blocks.
public enum SCAuthorization {
    /// Mirrors Apple's stock "authenticate-admin" rule, with a 2-minute shared timeout.
    /// Do NOT add a "mechanisms" key: it replaces authd's normal credential-collection chain with whatever
    /// is listed, and a lone "builtin:authenticate" can't verify a login (the prompt just re-appears forever,
    /// logging "Mechanism failed to return a valid UID").
    static let rule: [String: Any] = [
        "class": "user",
        "group": "admin",
        "authenticate-user": true,
        "allow-root": false,
        "session-owner": false,
        "timeout": 120,
        "shared": true,
        "tries": 10_000,
        "version": 2,
    ]

    private static let descriptions: [String: String] = [
        SC.startRight: "Holdfast needs your username and password to start the block.",
        SC.modifyRight: "Holdfast needs your username and password to modify the block.",
    ]

    /// Daemon side, at launch (as root): create the rights if they don't exist yet.
    public static func registerRights() {
        var authRef: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &authRef) == errAuthorizationSuccess, let authRef else { return }
        defer { AuthorizationFree(authRef, []) }

        for (name, description) in descriptions {
            if AuthorizationRightGet(name, nil) == errAuthorizationDenied {
                let status = AuthorizationRightSet(authRef, name, rule as CFDictionary, description as CFString, nil, nil)
                if status != errAuthorizationSuccess { NSLog("Couldn't register right %@: %d", name, status) }
            }
        }
    }

    /// A granted authorization. The external form handed to the daemon is only valid while the original
    /// AuthorizationRef is alive, so keep this object around until the daemon has replied.
    /// (Freeing it early makes the daemon's AuthorizationCreateFromExternalForm fail, which looks like
    /// "not authorized" even though the user entered the right password.)
    public final class Ticket {
        private var ref: AuthorizationRef?
        public let externalForm: Data

        init(ref: AuthorizationRef, externalForm: Data) {
            self.ref = ref
            self.externalForm = externalForm
        }

        deinit { if let ref { AuthorizationFree(ref, []) } }
    }

    /// Client side: prompts the user and returns a ticket whose `externalForm` is sent to the daemon.
    public static func obtain(right: String) throws -> Ticket {
        var authRef: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &authRef) == errAuthorizationSuccess, let authRef else {
            throw SCError(.notAuthorized, "(couldn't create an authorization session)")
        }

        func fail(_ error: SCError) -> SCError {
            AuthorizationFree(authRef, [])
            return error
        }

        let status: OSStatus = right.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { itemPtr in
                var rights = AuthorizationRights(count: 1, items: itemPtr)
                let flags: AuthorizationFlags = [.interactionAllowed, .extendRights]
                return AuthorizationCopyRights(authRef, &rights, nil, flags, nil)
            }
        }
        guard status == errAuthorizationSuccess else {
            switch status {
            case errAuthorizationCanceled: throw fail(SCError(.notAuthorized, "The password prompt was cancelled."))
            case errAuthorizationDenied: throw fail(SCError(.notAuthorized, "The password wasn't accepted, or this account isn't an administrator."))
            default: throw fail(SCError(.notAuthorized, "(authorization error \(status))"))
            }
        }

        var external = AuthorizationExternalForm()
        let externalStatus = AuthorizationMakeExternalForm(authRef, &external)
        guard externalStatus == errAuthorizationSuccess else {
            throw fail(SCError(.notAuthorized, "(couldn't export the authorization, error \(externalStatus))"))
        }
        return Ticket(ref: authRef, externalForm: withUnsafeBytes(of: &external) { Data($0) })
    }

    /// Daemon side: verify a client-supplied authorization holds `right`. Never prompts.
    public static func verify(_ data: Data, right: String) -> Bool {
        guard data.count == MemoryLayout<AuthorizationExternalForm>.size else {
            NSLog("Authorization for %@ rejected: malformed authorization data (%d bytes)", right, data.count)
            return false
        }
        var external = AuthorizationExternalForm()
        withUnsafeMutableBytes(of: &external) { _ = data.copyBytes(to: $0) }

        var authRef: AuthorizationRef?
        let restore = AuthorizationCreateFromExternalForm(&external, &authRef)
        guard restore == errAuthorizationSuccess, let authRef else {
            NSLog("Authorization for %@ rejected: couldn't restore the client's authorization (error %d)", right, restore)
            return false
        }
        defer { AuthorizationFree(authRef, []) }

        let status: OSStatus = right.withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { itemPtr in
                var rights = AuthorizationRights(count: 1, items: itemPtr)
                return AuthorizationCopyRights(authRef, &rights, nil, [.extendRights], nil)
            }
        }
        if status != errAuthorizationSuccess { NSLog("Authorization check for %@ failed with status %d", right, status) }
        return status == errAuthorizationSuccess
    }
}
