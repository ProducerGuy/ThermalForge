//
//  DaemonLifecycleTests.swift
//  ThermalForge
//
//  #31: the install/uninstall launchd sequence (bootout waits for the job to be
//  gone, bootstrap retries once, failures carry a rerun line), the daemon's startup
//  fan reconcile, its SIGTERM release decision, its start errors, and that its
//  logs are readable. launchctl, the registration query, the clock and the SMC are
//  all injected, so nothing here needs root, real time, or hardware.
//

import Darwin
import Foundation
import OSLog
import Testing

@testable import ThermalForgeCore

/// A scripted launchd: launchctl results and registration answers in order, a
/// fake clock, and a record of what was called.
private final class FakeLaunchd {
    var results: [(status: Int32, output: String)]
    var registered: [Bool]
    private(set) var calls: [[String]] = []
    private(set) var pauses = 0
    private(set) var registrationChecks = 0
    var clock = Date(timeIntervalSince1970: 0)

    init(results: [(status: Int32, output: String)] = [], registered: [Bool]) {
        self.results = results
        self.registered = registered
    }

    var control: LaunchdControl {
        LaunchdControl(
            launchctl: { args in
                self.calls.append(args)
                return self.results.isEmpty ? (0, "") : self.results.removeFirst()
            },
            isRegistered: {
                self.registrationChecks += 1
                // The last answer repeats once the script runs out.
                return self.registered.count > 1 ? self.registered.removeFirst() : self.registered[0]
            },
            now: { self.clock },
            pause: { seconds in
                self.pauses += 1
                self.clock = self.clock.addingTimeInterval(seconds)
            }
        )
    }
}

@Suite("Daemon lifecycle (#31)")
struct DaemonLifecycleTests {

    // MARK: Waiting

    @Test("waitUntil returns as soon as the condition holds, with no fixed delay")
    func waitReturnsOnCondition() {
        let launchd = FakeLaunchd(registered: [false])
        var checks = 0
        let ok = launchd.control.waitUntil(limit: 30) { checks += 1; return checks == 3 }
        #expect(ok)
        #expect(checks == 3)
        #expect(launchd.pauses == 2)
    }

    @Test("waitUntil gives up at the limit, measured on the injected clock")
    func waitGivesUpAtLimit() {
        let launchd = FakeLaunchd(registered: [false])
        let ok = launchd.control.waitUntil(limit: 1) { false }
        #expect(!ok)
        #expect(launchd.clock >= Date(timeIntervalSince1970: 1))
    }

    // MARK: Bootout

    @Test("Bootout is skipped when nothing is registered")
    func bootoutSkippedWhenNotRegistered() throws {
        let launchd = FakeLaunchd(registered: [false])
        try launchd.control.bootoutIfRegistered(label: "com.example", rerun: "rerun")
        #expect(launchd.calls.isEmpty)
    }

    @Test("Bootout returns once launchd reports the job gone, however long that takes")
    func bootoutWaitsForTeardown() throws {
        // Registered before the bootout, still registered for two polls after it.
        let launchd = FakeLaunchd(results: [(0, "")], registered: [true, true, true, false])
        try launchd.control.bootoutIfRegistered(label: "com.example", rerun: "rerun")
        #expect(launchd.calls == [["bootout", "system/com.example"]])
        #expect(launchd.registrationChecks == 4)
        #expect(launchd.pauses == 2)
    }

    @Test("A failed bootout throws one accurate message: launchctl's cause plus the rerun line")
    func bootoutFailureIsAccurate() {
        let cause = "Boot-out failed: 5: Input/output error"
        let launchd = FakeLaunchd(results: [(5, cause)], registered: [true])
        let expected = LaunchdError.bootoutFailed(exitStatus: 5, detail: cause, rerun: "sudo thermalforge install")
        #expect(throws: expected) {
            try launchd.control.bootoutIfRegistered(label: "com.example", rerun: "sudo thermalforge install")
        }
        #expect(expected.description ==
            "Couldn't stop the running ThermalForge daemon: Boot-out failed: 5: Input/output error (launchctl exit 5). Re-run: sudo thermalforge install")
        #expect(!expected.description.contains("SMC"))
        #expect(!expected.description.contains("Run with sudo"))
    }

    @Test("When launchctl prints nothing, the message still names the exit status")
    func launchdErrorWithoutOutput() {
        let text = LaunchdError.bootstrapFailed(exitStatus: 37, detail: "", rerun: "rerun").description
        #expect(text == "Couldn't start the ThermalForge daemon, also on retry (launchctl exit 37). Re-run: rerun")
    }

    @Test("A job that never unregisters ends in an error, not an endless wait")
    func bootoutStillRegistered() {
        let launchd = FakeLaunchd(results: [(0, "")], registered: [true])
        #expect(throws: LaunchdError.stillRegistered(seconds: 30, rerun: "rerun")) {
            try launchd.control.bootoutIfRegistered(label: "com.example", rerun: "rerun")
        }
    }

    // MARK: Bootstrap

    @Test("A bootstrap that succeeds runs once, with no retry note")
    func bootstrapSucceeds() throws {
        let launchd = FakeLaunchd(results: [(0, "")], registered: [false])
        var notes: [String] = []
        try launchd.control.bootstrap(plist: "/p.plist", rerun: "rerun") { notes.append($0) }
        #expect(launchd.calls == [["bootstrap", "system", "/p.plist"]])
        #expect(notes.isEmpty)
    }

    @Test("A failed bootstrap with nothing registered is retried once; the note carries launchctl's cause")
    func bootstrapRetriesOnce() throws {
        let launchd = FakeLaunchd(results: [(5, "Bootstrap failed: 5: Input/output error"), (0, "")],
                                  registered: [false])
        var notes: [String] = []
        try launchd.control.bootstrap(plist: "/p.plist", rerun: "rerun") { notes.append($0) }
        #expect(launchd.calls.count == 2)
        #expect(notes == ["Starting the daemon failed: Bootstrap failed: 5: Input/output error (launchctl exit 5); retrying once."])
    }

    @Test("A bootstrap that fails twice throws with the second exit status and the rerun line")
    func bootstrapFailsTwice() {
        let launchd = FakeLaunchd(results: [(5, "first"), (37, "second")], registered: [false])
        #expect(throws: LaunchdError.bootstrapFailed(exitStatus: 37, detail: "second", rerun: "rerun")) {
            try launchd.control.bootstrap(plist: "/p.plist", rerun: "rerun") { _ in }
        }
    }

    @Test("A failed bootstrap that left the job registered isn't retried; the running check decides")
    func bootstrapFailedButRegistered() throws {
        let launchd = FakeLaunchd(results: [(5, "")], registered: [true])
        try launchd.control.bootstrap(plist: "/p.plist", rerun: "rerun") { _ in }
        #expect(launchd.calls.count == 1)
    }

    // MARK: Startup reconcile

    private struct SMCUnreadable: Error {}

    @Test("Startup: fans under manual control with no hold are reset to auto")
    func reconcileResetsManual() {
        var resets = 0
        let outcome = StartupFanReconcile.run(manualControlEngaged: { true }, resetAuto: { resets += 1 })
        #expect(outcome == .reset)
        #expect(resets == 1)
    }

    @Test("Startup: fans already on auto are left alone")
    func reconcileLeavesAuto() {
        var resets = 0
        let outcome = StartupFanReconcile.run(manualControlEngaged: { false }, resetAuto: { resets += 1 })
        #expect(outcome == .alreadyAuto)
        #expect(resets == 0)
    }

    @Test("Startup: an unreadable SMC is reset anyway, since auto is the safe state")
    func reconcileResetsWhenUnreadable() {
        var resets = 0
        let outcome = StartupFanReconcile.run(manualControlEngaged: { throw SMCUnreadable() },
                                              resetAuto: { resets += 1 })
        #expect(outcome == .resetAfterUnreadable)
        #expect(resets == 1)
    }

    @Test("Startup: a failed reset is reported, not swallowed")
    func reconcileReportsResetFailure() {
        let outcome = StartupFanReconcile.run(manualControlEngaged: { true },
                                              resetAuto: { throw SMCUnreadable() })
        guard case .resetFailed = outcome else {
            Issue.record("expected .resetFailed, got \(outcome)")
            return
        }
    }

    // MARK: Shutdown

    @Test("SIGTERM releases fans only when the daemon controls them")
    func shutdownReleasesOnlyOwnFans() {
        #expect(DaemonShutdown.releasesFans(holding: true, safetySuspended: false))
        #expect(DaemonShutdown.releasesFans(holding: false, safetySuspended: true))
        #expect(DaemonShutdown.releasesFans(holding: true, safetySuspended: true))
        #expect(!DaemonShutdown.releasesFans(holding: false, safetySuspended: false))
    }

    // MARK: Start errors

    @Test("Daemon start errors say what failed, with the errno, and never blame the SMC or sudo")
    func startErrorsAreAccurate() {
        let path = "/var/run/thermalforge.sock"
        let cases: [(DaemonStartError, String)] = [
            (.ownerIsRoot, "refusing to start: the owner uid is 0. Reinstall from your user account: sudo thermalforge install"),
            (.socketFailed(errno: EMFILE), "couldn't create the control socket: \(String(cString: strerror(EMFILE))) (errno \(EMFILE))"),
            (.bindFailed(path: path, errno: EADDRINUSE), "couldn't bind the control socket at \(path): \(String(cString: strerror(EADDRINUSE))) (errno \(EADDRINUSE))"),
            (.chownFailed(path: path, uid: 4242, errno: EPERM), "couldn't give the control socket at \(path) to uid 4242: \(String(cString: strerror(EPERM))) (errno \(EPERM))"),
            (.chmodFailed(path: path, errno: EPERM), "couldn't set the control socket at \(path) to mode 0600: \(String(cString: strerror(EPERM))) (errno \(EPERM))"),
            (.listenFailed(errno: EINVAL), "couldn't listen on the control socket: \(String(cString: strerror(EINVAL))) (errno \(EINVAL))"),
        ]
        for (error, expected) in cases {
            #expect(error.description == expected)
            #expect(!error.description.contains("SMC"))
            #expect(!error.description.contains("Run with sudo"))
        }
    }

    // MARK: Logs

    @Test("Daemon log lines are readable in the unified log, not <private>")
    func daemonLogsArePublic() throws {
        let token = "tf-log-check-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        DaemonLog.notice("ThermalForge daemon: verb=status outcome=ok \(token)")
        DaemonLog.error("ThermalForge daemon: couldn't bind the control socket: \(token)")

        let wanted = ["ThermalForge daemon: verb=status outcome=ok \(token)",
                      "ThermalForge daemon: couldn't bind the control socket: \(token)"]

        // The unified log can lag under load before it hands entries back, so
        // re-read until both lines appear, bounded.
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let deadline = Date().addingTimeInterval(10)
        var lines: [String] = []
        repeat {
            let since = store.position(timeIntervalSinceLatestBoot: ProcessInfo.processInfo.systemUptime - 60)
            lines = try store.getEntries(at: since)
                .compactMap { $0 as? OSLogEntryLog }
                .filter { $0.subsystem == DaemonLog.subsystem }
                .map(\.composedMessage)
            if wanted.allSatisfy(lines.contains) { break }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        for line in wanted { #expect(lines.contains(line)) }
        #expect(!lines.contains { $0.contains("<private>") })
    }

    // MARK: Fan log routing

    @Test("A routed FanControl message goes to the sink only, never the file-log fallback")
    func fanLogRoutedToSink() {
        var sunk: [String] = []
        var fellBack: [String] = []
        FanControl.deliver("Reset to Apple defaults", to: { sunk.append($0) }) { fellBack.append($0) }
        #expect(sunk == ["Reset to Apple defaults"])
        #expect(fellBack.isEmpty)
    }

    @Test("Without a sink, FanControl messages keep going to the file log (app and CLI)")
    func fanLogFallsBackWithoutSink() {
        var fellBack: [String] = []
        FanControl.deliver("Reset to Apple defaults", to: nil) { fellBack.append($0) }
        #expect(fellBack == ["Reset to Apple defaults"])
    }

    // MARK: Watchdog

    @Test("The watchdog reverts an app hold only after 15s of silence")
    func watchdogTimeout() {
        let beat = Date(timeIntervalSince1970: 1_000_000)
        #expect(!HeartbeatWatchdog.revertsHold(lastBeat: beat, now: beat.addingTimeInterval(15)))
        #expect(HeartbeatWatchdog.revertsHold(lastBeat: beat, now: beat.addingTimeInterval(15.1)))
        #expect(!HeartbeatWatchdog.revertsHold(lastBeat: beat, now: beat.addingTimeInterval(5)))
    }

    // MARK: Old daemon log folder

    /// A fresh directory under the test process's temp dir, removed afterward.
    private func scratchDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tf-legacy-logs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("The old daemon log folder is removed with its contents")
    func legacyLogsRemoved() throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("ThermalForge")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("log".utf8).write(to: folder.appendingPathComponent("thermalforge-old.log"))

        #expect(ThermalForgeDaemon.removeLegacyLogs(at: folder.path) == .removed)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test("No old log folder is reported as not present, not as a failure")
    func legacyLogsAbsent() throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ThermalForgeDaemon.removeLegacyLogs(at: root.appendingPathComponent("ThermalForge").path) == .notPresent)
    }

    @Test("A symlink inside the folder is removed as a link; its target outside survives")
    func legacyLogsDontFollowInnerLinks() throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let keep = outside.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: keep)
        let folder = root.appendingPathComponent("ThermalForge")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link"),
                                                   withDestinationURL: outside)

        #expect(ThermalForgeDaemon.removeLegacyLogs(at: folder.path) == .removed)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(FileManager.default.fileExists(atPath: keep.path))
    }

    @Test("If the folder path is itself a symlink, only the link is removed")
    func legacyLogsDontFollowTopLink() throws {
        let root = try scratchDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let keep = outside.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: keep)
        let link = root.appendingPathComponent("ThermalForge")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        #expect(ThermalForgeDaemon.removeLegacyLogs(at: link.path) == .removed)
        var info = stat()
        #expect(lstat(link.path, &info) != 0)   // the link itself is gone
        #expect(FileManager.default.fileExists(atPath: keep.path))
    }

    @Test("A removal that fails is reported, not thrown", .enabled(if: getuid() != 0))
    func legacyLogsFailureReported() throws {
        let root = try scratchDir()
        let parent = root.appendingPathComponent("locked")
        let folder = parent.appendingPathComponent("ThermalForge")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A read-only parent blocks removing its entry (root would bypass this).
        chmod(parent.path, 0o500)
        defer {
            chmod(parent.path, 0o700)
            try? FileManager.default.removeItem(at: root)
        }

        guard case .failed = ThermalForgeDaemon.removeLegacyLogs(at: folder.path) else {
            Issue.record("expected .failed")
            return
        }
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    // MARK: System tools

    @Test("The running executable's path comes from the system: absolute, real, and fully resolved")
    func executablePathIsReal() throws {
        let path = try #require(SystemTools.currentExecutablePath())
        #expect(path.hasPrefix("/"))
        #expect(FileManager.default.isExecutableFile(atPath: path))
        // Already resolved: realpath of it is itself, so no symlink is left to copy.
        let again = try #require(realpath(path, nil))
        defer { free(again) }
        #expect(String(cString: again) == path)
    }

    @Test("A tool that runs reports its exit status")
    func toolExitStatus() {
        #expect(SystemTools.run("/usr/bin/true", []) == .exited(0, output: ""))
        #expect(SystemTools.run("/usr/bin/false", []) == .exited(1, output: ""))
    }

    @Test("A tool that can't launch is reported, without crashing")
    func toolNotLaunched() {
        guard case .notLaunched(let reason) = SystemTools.run("/nonexistent/thermalforge-tool", []) else {
            Issue.record("expected .notLaunched")
            return
        }
        #expect(!reason.isEmpty)
    }
}
