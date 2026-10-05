//
//  RootOutputTests.swift
//  ThermalForge
//
//  #31: running as root, ThermalForge writes no log files (TFLogger goes to the
//  unified log), and helper tools' own output never reaches the terminal: it is
//  captured and shown only inside our failure messages. Nothing here needs root;
//  the root case is chosen by passing an effective uid, against a temp home.
//

import Darwin
import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("Root writes no log files")
struct RootLoggingTests {

    private func tempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tf-logger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Root logs to the unified log; any other user logs to files in their home")
    func destinationByUser() {
        let home = URL(fileURLWithPath: "/Users/example")
        #expect(TFLogger.destination(euid: 0, home: home) == .unifiedLog)
        #expect(TFLogger.destination(euid: 1234, home: home)
                == .files(URL(fileURLWithPath: "/Users/example/Library/Logs/ThermalForge")))
    }

    @Test("As root, logging creates nothing under the home folder")
    func rootCreatesNoFiles() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let logger = TFLogger(euid: 0, home: home)
        var lines: [(String, Bool)] = []
        logger.unifiedLogSink = { lines.append(($0, $1)) }
        logger.fan("Reset to Apple defaults")
        logger.error("Fan command failed")
        logger.clearAll()

        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path).isEmpty)
        #expect(lines.map(\.0) == ["ThermalForge CLI (root) [FAN]: Reset to Apple defaults",
                                   "ThermalForge CLI (root) [ERROR]: Fan command failed"])
        #expect(lines.map(\.1) == [false, true])
    }

    @Test("As a user, logging still writes the daily file")
    func userWritesFile() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let logger = TFLogger(euid: 1234, home: home)
        var sunk = 0
        logger.unifiedLogSink = { _, _ in sunk += 1 }
        logger.fan("Reset to Apple defaults")

        let text = try String(contentsOf: logger.path, encoding: .utf8)
        #expect(logger.path.path.hasPrefix(home.appendingPathComponent("Library/Logs/ThermalForge").path))
        #expect(text.contains("[FAN] Reset to Apple defaults"))
        #expect(sunk == 0)
    }
}

@Suite("Helper tool output is captured")
struct ToolOutputTests {

    @Test("stdout and stderr are captured with the exit status, not passed through")
    func capturesOutput() {
        let run = SystemTools.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"])
        #expect(run == .exited(3, output: "out\nerr"))
    }

    @Test("A large output can't stall the tool")
    func largeOutput() {
        guard case .exited(0, let output) = SystemTools.run("/bin/sh", ["-c", "yes x | head -c 200000"]) else {
            Issue.record("expected exit 0")
            return
        }
        #expect(output.count > 190_000)
    }

    @Test("A failure detail carries the tool's text only when it printed some")
    func exitDetail() {
        #expect(SystemTools.exitDetail(tool: "xattr", status: 1, output: "")
                == "xattr exit 1")
        #expect(SystemTools.exitDetail(tool: "xattr", status: 1, output: "No such file")
                == "xattr exit 1: No such file")
    }

    @Test("pgrep answers whether a process is running, by name and user")
    func processRunning() throws {
        #expect(SystemTools.processRunning("ThermalForgeTestNoSuchProcess", uid: getuid()) == false)
        #expect(SystemTools.processRunning("ThermalForgeTestNoSuchProcess", uid: nil) == false)

        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["10"]
        try sleeper.run()
        defer { sleeper.terminate(); sleeper.waitUntilExit() }
        #expect(SystemTools.processRunning("sleep", uid: getuid()) == true)
    }
}

/// A scripted app: answers to "is it running?" in order (the last repeats), and a
/// record of how long stopApp waited.
private final class ScriptedApp {
    var answers: [Bool?]
    var slept: TimeInterval = 0
    init(_ answers: [Bool?]) { self.answers = answers }
    func isRunning() -> Bool? { answers.count > 1 ? answers.removeFirst() : answers[0] }
}

@Suite("Stopping the menu bar app is verified, not inferred from killall's exit")
struct AppStopTests {

    private func stop(_ app: ScriptedApp, _ kill: SystemTools.ToolRun) -> SystemTools.AppStop {
        SystemTools.stopApp(isRunning: app.isRunning, kill: { kill },
                            waitLimit: 3, pollInterval: 0.1, sleep: { app.slept += $0 })
    }

    @Test("Running before, gone after: stopped")
    func stopped() {
        let app = ScriptedApp([true, false])
        #expect(stop(app, .exited(0, output: "")) == .stopped)
        #expect(app.slept == 0)
    }

    @Test("Not running before or after: silently not running, whatever killall printed")
    func notRunning() {
        let app = ScriptedApp([false, false])
        #expect(stop(app, .exited(1, output: "No matching processes were found")) == .notRunning)
    }

    @Test("An app that takes a moment to quit is waited for")
    func slowQuit() {
        let app = ScriptedApp([true, true, true, false])
        #expect(stop(app, .exited(0, output: "")) == .stopped)
        #expect(app.slept > 0 && app.slept < 1)
    }

    @Test("killall exit 0 but the app is still running: a failure with killall's text")
    func successExitButStillRunning() {
        let app = ScriptedApp([true, true])
        #expect(stop(app, .exited(0, output: ""))
                == .failed("the menu bar app is still running (killall exit 0)"))
        #expect(app.slept >= 3)
    }

    @Test("killall exit 1 and the app is still running: a failure, not 'not running'")
    func exitOneButStillRunning() {
        let app = ScriptedApp([true, true])
        #expect(stop(app, .exited(1, output: "kill(123): Operation not permitted"))
                == .failed("the menu bar app is still running (killall exit 1: kill(123): Operation not permitted)"))
    }

    @Test("killall didn't launch and the app is still running: a failure saying so")
    func notLaunched() {
        let app = ScriptedApp([true, true])
        #expect(stop(app, .notLaunched("missing"))
                == .failed("the menu bar app is still running (killall didn't run: missing)"))
    }

    @Test("No answer afterward: can't confirm, reported as a failure")
    func unknownAfter() {
        let app = ScriptedApp([true, nil])
        #expect(stop(app, .exited(0, output: ""))
                == .failed("couldn't confirm the menu bar app stopped (killall exit 0)"))
    }

    @Test("No answer beforehand, gone after: killall's exit 0 decides stopped vs not running")
    func unknownBefore() {
        #expect(stop(ScriptedApp([nil, false]), .exited(0, output: "")) == .stopped)
        #expect(stop(ScriptedApp([nil, false]), .exited(1, output: "")) == .notRunning)
    }
}
