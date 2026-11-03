# Holdfast

Holdfast is a Swift rewrite of [SelfControl](https://github.com/SelfControlApp/selfcontrol) for macOS 14+: block
distracting websites and apps for a set time, and the block **can't be turned off until the timer ends**, not by
quitting the app, restarting, or changing the system date. It installs alongside the original SelfControl without
touching it. Licensed GPL-3.0-or-later, as a derivative of the original.

## What's new compared to the original

| | |
|---|---|
| **Length picker** | The drag slider is gone. Type hours + minutes (or tap a preset), **or** switch to *Until a time* and pick a clock time like 5:00 PM. A live line shows exactly when it ends. *Start Block* is the window's default button. |
| **Recurring schedules** | "Weekdays 9–5" style windows, stored in and fired by the root daemon, so they run with the app closed. Windows can cross midnight. If a window is already open when a manual block ends, the schedule covers the rest of it. |
| **App blocking** | Add apps to a profile; the daemon quits them (SIGTERM, then SIGKILL) as soon as they run, once a second, for the whole block. Works alone (no site rules) or together with sites. |
| **Profiles** | Named blocklists/allowlists with one-click selection and the original's import lists. |
| **Menu bar + stats** | Live countdown in the menu bar with quick-start buttons, a notification when the block ends (even if the app was quit), and a history/streak screen with a 14-day chart. |

The core is a faithful port: an `/etc/hosts` block plus a `pf` firewall anchor, a root launchd daemon that re-checks
the rules every second and repairs tampering, blocklist and allowlist modes, adding sites / extending a running block
(never shortening it), common-subdomain and Google/Facebook handling, cache and DNS flushing.

## Download

Grab the latest `Holdfast-x.y.z.dmg` from [Releases](https://github.com/vinaymve/holdfast/releases), drag Holdfast to
Applications, and compare `shasum -a 256` against the checksum in the release notes. Releases are currently **not
notarized** (no Apple Developer ID yet), so macOS will refuse to open the app the first time: try to open it once, then
go to System Settings → Privacy & Security and click **Open Anyway**. Universal binary, macOS 14+.

## Build and run

Requires Xcode 15+ / Swift 5.10+ on macOS 14+.

```bash
Scripts/build-app.sh          # builds build/Holdfast.app (app + helper + CLI, ad-hoc signed)
open build/Holdfast.app
```

The first time you start a block, Holdfast installs its helper as part of the same admin prompt. Starting a block,
adding sites, extending, and saving schedules each ask for your admin password / Touch ID, as in the original.

### CLI

```bash
holdfast-cli start --duration 2h --site facebook.com --site reddit.com
holdfast-cli start --until 5pm --profile "Social & Video" --app /Applications/Slack.app
holdfast-cli status | add | extend 30m | schedules | history | ping | install | uninstall
```

## Tests

```bash
swift test                    # 104 unit tests: parsing, hosts/pf rules, controller lifecycle, schedules, app blocking, stats, clock tampering, installer script
Scripts/dev-e2e.sh            # ~70 s end-to-end over real XPC against an unprivileged dev daemon; touches nothing in /etc
```

The engine takes injectable file paths and command runner, so tests run the whole start → tamper → repair → expire
cycle against a scratch directory. The dev daemon (`holdfastd --dev-root DIR`) refuses to run as root.

## Differences from the original (and why)

- **No SMJobBless.** It needs a Developer ID signature that matches the helper's embedded requirement. The helper is
  installed with one admin prompt (`osascript` + `launchctl`) instead. Trade-off: trust in the helper binary rests on
  the app bundle's integrity at install time. For distribution, sign + notarize and move to `SMAppService`; the daemon
  honors an optional `SC_CLIENT_REQUIREMENT` environment variable to restrict XPC clients by code signature.
- **Own identity.** The hosts section is `# BEGIN HOLDFAST BLOCK`, the pf anchor is `dev.holdfast`, the pf token file
  is `/etc/HoldfastPFToken`, and the helper, launchd label and bundle id are all `dev.holdfast.*`, so Holdfast can
  coexist with the original SelfControl and never touches its blocks (a test enforces this). Installing the helper
  also retires the helper of the earlier "SelfControl (Swift)" dev build, unless that one is mid-block.
- **The daemon stays resident** (the original exits when idle) because schedules need something awake.
- **Input hardening.** Entries are validated before they reach `/etc/hosts` or the pf ruleset, so a pasted line can't
  inject extra rules.
- **Bugs fixed relative to the original:** a `/240` mask typo and duplicate lines in the Google range list; swapped
  arguments when appending to a running blocklist; missing `return`s after error replies when extending a block;
  derived `www.` entries dropping the original's port; the "allow local networks" option was stored but never applied
  (it now adds pass rules for private ranges in allowlist blocks).
- **Not ported:** Sparkle auto-update, Sentry reporting, the SelfControl Killer app, localizations, v3 settings
  migration, Mail/Thunderbird/MailMate host importers, and `.selfcontrol` blocklist save/open (profiles replace it).

## Changing the system date doesn't work

The original could be beaten by moving the clock forward. Holdfast doesn't trust the system clock during a block:

- **Within a boot**, elapsed time comes from the monotonic clock (`CLOCK_MONOTONIC_RAW`, which keeps counting through
  sleep and ignores date changes), so setting the date forward, back, or nudging it in small steps changes nothing. The
  app shows the countdown from this clock.
- **Across a reboot** the monotonic clock resets, and the daemon can't tell hours of real downtime from a moved date.
  It saves its last trusted time (time never runs backwards) and asks the network: `time.apple.com` over NTP, or if NTP is blocked (it is on many networks), the `Date` header of an HTTPS response from apple.com. A block that looks
  finished is held until the network answers (a moved date is then corrected), for at most 30 minutes, so being
  offline can never make a block permanent.

What it can't stop: someone with root who deletes the helper or its files, or who tampers with the clock, blocks
both time sources (NTP and HTTPS), *and* reboots (that wins after the 30-minute hold). Choosing the date before you start a block affects only
"until a time" lengths, which you chose yourself.

## Things to know

- Once started, a block cannot be ended early through the app. Test with a short one first.
- Blocked apps are force-quit; unsaved work in them is lost. The app asks before starting if any are open.
- The admin-authorization handshake (client prompt, daemon verification) follows the original's design but has only
  been exercised on a real system up to rights registration and XPC connectivity; the rest of the flow is covered by
  unit and dev-daemon tests that bypass authorization.

## Security

See [SECURITY.md](SECURITY.md) for the threat model, what Holdfast can and can't stop, and how to report a vulnerability.
In short: it protects you from yourself, not from someone with an admin password and a terminal, and VPNs, proxies and
apps with their own encrypted DNS can route around hosts/firewall blocking.

## Releasing

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" Scripts/build-app.sh release
ditto -c -k --keepParent build/Holdfast.app build/Holdfast.zip
xcrun notarytool submit build/Holdfast.zip --keychain-profile "<profile>" --wait
xcrun stapler staple build/Holdfast.app
Scripts/make-dmg.sh           # build/Holdfast-<version>.dmg (signed too if CODESIGN_IDENTITY is set)
```

Without `CODESIGN_IDENTITY`, `Scripts/build-app.sh release` produces a universal, ad-hoc-signed app and
`Scripts/make-dmg.sh` packages it; that is what the unnotarized GitHub releases use.

A signed build pins the installed helper to the app's Team ID. The Developer ID path has not been exercised in this
repository's development (no signing identity was available), so test it on a clean Mac before publishing.

## If something goes wrong

Run as root. This stops the helper, removes all rules, forgets the active block (schedules and history are kept) and
restarts the helper:

```bash
sudo /Library/PrivilegedHelperTools/dev.holdfast.daemon --emergency-clear
```

Remove the helper entirely (Settings → Helper → Remove Helper refuses while a block runs), or by hand:

```bash
sudo launchctl bootout system/dev.holdfast.daemon
sudo rm /Library/LaunchDaemons/dev.holdfast.daemon.plist /Library/PrivilegedHelperTools/dev.holdfast.daemon
```

## Layout

```
Sources/HoldfastCore  engine, models, XPC protocol/client, installer (shared by everything)
Sources/holdfastd       root launchd daemon
Sources/holdfast-cli
Sources/Holdfast        SwiftUI app
Tests/HoldfastCoreTests
Scripts/               build-app.sh, dev-e2e.sh
```
