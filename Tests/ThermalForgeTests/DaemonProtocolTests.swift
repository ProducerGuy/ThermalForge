//
//  DaemonProtocolTests.swift
//  ThermalForge
//
//  Phase 2 wire protocol: length-prefixed JSON frames. Exercises the real fd
//  framing path over a socketpair — request/response round-trips per verb, the
//  FanCommand→request mapping (oneshot preservation), oversized-frame rejection
//  (encode and read side), and unknown-verb decode failure (which the daemon
//  turns into a structured unsupportedVersion).
//

import Darwin
import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("Daemon protocol (Phase 2)")
struct DaemonProtocolTests {

    /// A connected pair of Unix stream fds, for the real writeFrame/readFrame path.
    private func socketPair() -> (Int32, Int32) {
        var fds = [Int32](repeating: 0, count: 2)
        let rc = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        #expect(rc == 0)
        return (fds[0], fds[1])
    }

    /// Round-trip a value: encode → writeFrame(a) → readFrame(b) → decode.
    private func roundTrip<T: Codable & Equatable>(_ value: T, max: Int) throws -> T {
        let (a, b) = socketPair()
        defer { close(a); close(b) }
        let frame = try DaemonProtocol.encodeFrame(value, max: max)
        try DaemonProtocol.writeFrame(a, frame)
        let body = try DaemonProtocol.readFrame(b, max: max)
        return try DaemonProtocol.decode(T.self, from: body)
    }

    @Test("every request verb round-trips through a frame")
    func requestRoundTrip() throws {
        let requests: [DaemonRequest] = [
            DaemonRequest(verb: .max, oneshot: true),
            DaemonRequest(verb: .auto),
            DaemonRequest(verb: .set, rpm: 3000, oneshot: true),
            DaemonRequest(verb: .setfan, rpm: 2500, fan: 1, oneshot: true),
            DaemonRequest(verb: .status),
            DaemonRequest(verb: .state),
            DaemonRequest(verb: .heartbeat),
            DaemonRequest(verb: .version),
        ]
        for req in requests {
            #expect(try roundTrip(req, max: DaemonProtocol.maxRequestBytes) == req)
        }
    }

    @Test("every response shape round-trips through a frame")
    func responseRoundTrip() throws {
        let responses: [DaemonResponse] = [
            .ok(),
            .ok(note: "clamped 999999 → 3500 RPM (max)"),
            .failure(.usage, "usage: set <rpm>"),
            .failure(.heldByCLI, "held by cli"),
            .failure(.rateLimited, "too many fan commands; try again shortly"),
            .failure(.internal, "smc write failed"),
            .versionResponse("0.1.10"),
            .statusResponse(#"{"fans":[],"temperatures":{}}"#),
            .stateResponse(DaemonHoldState(command: "set 3000", owner: "cli")),
            .stateResponse(DaemonHoldState(command: "set 2000", owner: "app", safetySuspended: true)),
            .unsupported(daemonVersion: "0.1.10"),
        ]
        for resp in responses {
            #expect(try roundTrip(resp, max: DaemonProtocol.maxResponseBytes) == resp)
        }
    }

    @Test("oneshot maps from FanCommand and survives the wire")
    func oneshotPreservation() throws {
        // Hold commands carry oneshot; resetAuto never does (it isn't a hold).
        #expect(DaemonRequest(.setMax, oneshot: true) == DaemonRequest(verb: .max, oneshot: true))
        #expect(DaemonRequest(.setRPM(3000), oneshot: true) == DaemonRequest(verb: .set, rpm: 3000, oneshot: true))
        #expect(DaemonRequest(.setFan(index: 1, rpm: 2500), oneshot: true)
                == DaemonRequest(verb: .setfan, rpm: 2500, fan: 1, oneshot: true))
        #expect(DaemonRequest(.resetAuto, oneshot: true).oneshot == false)
        #expect(DaemonRequest(.setMax, oneshot: false).oneshot == false)

        // And the flag survives a frame round-trip either way.
        #expect(try roundTrip(DaemonRequest(.setMax, oneshot: true), max: DaemonProtocol.maxRequestBytes).oneshot == true)
        #expect(try roundTrip(DaemonRequest(.setRPM(1200), oneshot: false), max: DaemonProtocol.maxRequestBytes).oneshot == false)
    }

    @Test("an unknown verb fails to decode (daemon maps this to unsupportedVersion)")
    func unknownVerbRejected() {
        let json = Data(#"{"v":1,"verb":"bogus","oneshot":false}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try DaemonProtocol.decode(DaemonRequest.self, from: json)
        }
    }

    @Test("oversized frames are rejected on encode and on read")
    func oversizedRejected() throws {
        // Encode side: a body larger than the cap throws before it goes on the wire.
        #expect(throws: DaemonProtocol.FrameError.oversized) {
            _ = try DaemonProtocol.encodeFrame(DaemonRequest(verb: .version), max: 1)
        }
        // Read side: a length prefix over the cap is rejected before the body is read.
        let (a, b) = socketPair()
        defer { close(a); close(b) }
        let header: [UInt8] = [0x00, 0x00, 0x13, 0x88]   // 5000 > 4096; top byte 0x00 → hostile/binary
        try DaemonProtocol.writeFrame(a, header)
        #expect(throws: DaemonProtocol.FrameError.oversized) {
            _ = try DaemonProtocol.readFrame(b, max: DaemonProtocol.maxRequestBytes)
        }
    }

    @Test("a legacy string peer is detected, not misread as oversized; binary stays oversized")
    func legacyPeerDetected() throws {
        // A pre-Phase-2 peer's raw reply — first byte is ASCII 'e' (0x65). The bytes
        // as a big-endian length far exceed the cap, but the ASCII lead marks it legacy.
        let (a, b) = socketPair()
        defer { close(a); close(b) }
        try DaemonProtocol.writeFrame(a, Array("error: unknown command 'x'\n".utf8))
        #expect(throws: DaemonProtocol.FrameError.legacyPeer) {
            _ = try DaemonProtocol.readFrame(b, max: DaemonProtocol.maxResponseBytes)
        }

        // A genuinely binary over-cap length (non-ASCII top byte) stays hostile.
        let (c, d) = socketPair()
        defer { close(c); close(d) }
        try DaemonProtocol.writeFrame(c, [0xFF, 0x00, 0x00, 0x00])
        #expect(throws: DaemonProtocol.FrameError.oversized) {
            _ = try DaemonProtocol.readFrame(d, max: DaemonProtocol.maxResponseBytes)
        }
    }
}
