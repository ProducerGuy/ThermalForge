//
//  UpdateCheckerTests.swift
//  ThermalForge
//
//  Pure comparison logic for the update check. The network fetch isn't exercised
//  here — evaluate() is the part with the edge cases (the "v" strip, numeric vs
//  lexical compare, malformed tags never yielding a false positive).
//

import Testing
@testable import ThermalForgeCore

struct UpdateCheckerTests {
    private let url = "https://example.com/r"

    @Test("a newer tag is an available update")
    func newer() {
        let u = UpdateChecker.evaluate(current: "0.2.0", tagName: "v0.2.1", url: url)
        #expect(u == AvailableUpdate(version: "0.2.1", url: url))
    }

    @Test("the leading v is stripped from the reported version")
    func stripsV() {
        let u = UpdateChecker.evaluate(current: "0.2.0", tagName: "v0.3.0", url: url)
        #expect(u?.version == "0.3.0")
        // A tag without a v works identically.
        #expect(UpdateChecker.evaluate(current: "0.2.0", tagName: "0.3.0", url: url)?.version == "0.3.0")
    }

    @Test("equal version is not an update")
    func equal() {
        #expect(UpdateChecker.evaluate(current: "0.2.1", tagName: "v0.2.1", url: url) == nil)
    }

    @Test("an older tag is not an update")
    func older() {
        #expect(UpdateChecker.evaluate(current: "0.2.1", tagName: "v0.2.0", url: url) == nil)
    }

    @Test("compare is numeric, not lexical (0.2.10 > 0.2.9)")
    func numeric() {
        #expect(UpdateChecker.evaluate(current: "0.2.9", tagName: "v0.2.10", url: url)?.version == "0.2.10")
        #expect(UpdateChecker.evaluate(current: "0.2.10", tagName: "v0.2.9", url: url) == nil)
    }

    @Test("a malformed or empty tag never yields a false update")
    func malformed() {
        // "vX.Y" → "X.Y" → parses to 0.0, which is never newer than a real version.
        #expect(UpdateChecker.evaluate(current: "0.2.0", tagName: "vX.Y", url: url) == nil)
        #expect(UpdateChecker.evaluate(current: "0.2.0", tagName: "", url: url) == nil)
        #expect(UpdateChecker.evaluate(current: "0.2.0", tagName: "v", url: url) == nil)
    }
}
