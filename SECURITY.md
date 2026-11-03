# Security

Holdfast runs a helper as **root** that edits `/etc/hosts` and the `pf` firewall, so security reports are welcome.

**Reporting.** Please use GitHub's private vulnerability reporting ("Security" tab, "Report a vulnerability") rather than a
public issue. Include the macOS version, how you installed Holdfast, and steps to reproduce.

## What Holdfast is designed to resist

Holdfast is a commitment device: it protects you from *yourself in a weak moment*, not from a determined administrator.

| Attempt during a block | Result |
|---|---|
| Quit the app, or restart the Mac | Block continues; the helper resumes it at boot |
| Edit `/etc/hosts` or `pf.conf` without root | Not possible; with root, the helper repairs it within about a second |
| Start, extend or edit a block from another process | Requires admin authorization (password) |
| Move the system date forward or back | Ignored: elapsed time comes from a monotonic clock |
| Move the date, then reboot | Checked against network time (NTP, falling back to an HTTPS `Date` header, since many networks block NTP); a finished-looking block is held up to 30 minutes for confirmation |
| Copy or rename a blocked app | Still matched by bundle identifier |

## What it cannot stop

- **Anyone with an admin password and a terminal.** `sudo launchctl bootout system/dev.holdfast.daemon` and removing the
  rules by hand always works. That is by design: a permanent, unrecoverable block would be worse. The documented recovery
  command is `sudo /Library/PrivilegedHelperTools/dev.holdfast.daemon --emergency-clear`.
- **Network paths that skip hosts/pf by name or address**: VPNs and proxies, apps with their own DNS-over-HTTPS, sites
  reached through addresses that changed after the block began, or hostnames you didn't list.
- **Moving the date, blocking both NTP and HTTPS to apple.com, *and* rebooting**, after which the 30-minute hold expires.
  Feeding it a fake time instead needs root.

## Known residual risks

- **Shared authorization.** The admin right is "shared" with a 2-minute timeout, like the original SelfControl. After you
  authenticate, another process running as you could briefly reuse that authorization to start or extend a block, add sites, or change
  schedules. It still could not end a block early.
- **State is world-readable** (`/Library/Application Support/Holdfast/state.json`) so the app can show status without a
  privileged call. It contains your blocklist and block history, visible to other local users.
- **The helper parses untrusted input as root**: web pages (link scraping for allowlists; capped at 1 MB, no disk cache) and
  `Info.plist` files of running apps (size-limited). Both only matter for features you enable.
- **Cache clearing runs as root** over each user's home. It refuses paths that resolve outside that home, but a race between
  the check and the delete is theoretically possible on a multi-user Mac.
- **Unsigned builds.** An ad-hoc-signed build trusts the helper binary inside the app bundle at install time. If something
  with write access to the app can replace that binary, the next "install helper" prompt would install it. Releases should be
  signed with a Developer ID and notarized; Holdfast then pins the helper to the app's Team ID before installing it.
- **XPC clients are not code-signature checked by default.** Mutating calls need admin authorization regardless. Signed
  builds can restrict clients further by setting `SC_CLIENT_REQUIREMENT` in the LaunchDaemon plist.

## Reviewed

A pre-release review found and fixed: a daemon-side missing validation of app paths (an app path of `/` matched every
process), app blocking bypass by copying the app, a non-working emergency-clear (the running daemon restored the block),
root cache deletion through user-planted symlinks, loose domain-suffix matching, schedules that never retried a failed start,
silent loss of a corrupt state file, an uncapped download inside the root helper, an unverified helper copy during install,
and dev-only flags present in release builds. Each has a regression test.
