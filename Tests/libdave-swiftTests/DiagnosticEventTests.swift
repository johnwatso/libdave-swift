import XCTest
@testable import libdave_swift

/// Covers the observability surface: the bounded trace, the live event stream,
/// the expanded diagnostics snapshot, and structured failure reporting.
///
/// The recurring theme is that these are the tools a host uses to explain a
/// voice session it cannot reproduce, so they must be bounded, ordered,
/// exportable, and free of key material.
final class DiagnosticEventTests: XCTestCase {

    private func makeCoordinator(
        limits: DaveCoordinatorLimits = .default
    ) async throws -> DaveSessionCoordinator {
        let coordinator = DaveSessionCoordinator(limits: limits)
        try await coordinator.configureForDiscordVoice(
            groupId: 8_800,
            selfUserId: "424242424242424242",
            protocolVersion: 1
        )
        return coordinator
    }

    // MARK: - Bounded trace

    func testTraceRecordsStateMachineEventsInOrder() async throws {
        let coordinator = try await makeCoordinator()
        _ = await coordinator.executeDiscordTransition(7)

        let events = await coordinator.getDiagnostics().recentEvents
        XCTAssertFalse(events.isEmpty, "configuration and gateway handling must be traced")

        // Sequence numbers are strictly increasing, so a host can order events
        // and detect a gap without relying on timestamp resolution.
        let ids = events.map(\.id)
        XCTAssertEqual(ids, ids.sorted(), "trace must be ordered")
        XCTAssertEqual(Set(ids).count, ids.count, "sequence numbers must be unique")

        XCTAssertTrue(
            events.contains { $0.kind == .sessionConfigured },
            "configuration must appear in the trace"
        )
        XCTAssertTrue(
            events.allSatisfy { $0.sessionGeneration > 0 },
            "every event must name the session generation it belongs to"
        )
    }

    func testTraceStaysWithinItsConfiguredCapacity() async throws {
        let coordinator = try await makeCoordinator(
            limits: DaveCoordinatorLimits(maximumTrackedTransitions: 8, traceEventCapacity: 25)
        )

        for transitionId in 1...400 {
            _ = await coordinator.executeDiscordTransition(UInt64(transitionId))
        }

        let events = await coordinator.getDiagnostics().recentEvents
        XCTAssertLessThanOrEqual(events.count, 25, "the trace must not exceed its capacity")
        XCTAssertFalse(events.isEmpty)

        // Oldest-first eviction: what survives is the most recent window.
        let ids = events.map(\.id)
        XCTAssertEqual(ids, ids.sorted())
    }

    /// The trace is meant to be exportable to a log or monitoring pipeline, so
    /// it must never carry MLS payloads, ratchets, or key material.
    func testTraceCarriesSizesButNeverPayloadBytes() async throws {
        let coordinator = try await makeCoordinator()

        // A recognisable byte pattern: if any of it were retained, it would
        // show up in the encoded trace.
        let marker = Data(repeating: 0xAB, count: 64)
        _ = try? await coordinator.consumeDiscordGatewayEvent(.commit(marker, transitionId: 3))

        let diagnostics = await coordinator.getDiagnostics()
        let encoded = try JSONEncoder().encode(diagnostics.recentEvents)
        let text = String(decoding: encoded, as: UTF8.self)

        XCTAssertFalse(text.contains("abababab"), "trace must not contain payload bytes")
        XCTAssertFalse(text.lowercased().contains("ratchet"), "trace must not reference key material")
        XCTAssertTrue(
            diagnostics.recentEvents.contains { $0.payloadByteCount == 64 },
            "payload size must be recorded even though the bytes are not"
        )
    }

    func testTraceSurvivesResetSoAPostMortemKeepsTheCause() async throws {
        let coordinator = try await makeCoordinator()
        _ = await coordinator.executeDiscordTransition(5)
        let beforeCount = await coordinator.getDiagnostics().recentEvents.count

        try await coordinator.recreateSessionState()

        let diagnostics = await coordinator.getDiagnostics()
        XCTAssertGreaterThanOrEqual(
            diagnostics.recentEvents.count,
            beforeCount,
            "the events explaining why a session was recreated must survive the recreation"
        )
        // Generations let a host separate pre- and post-recovery events.
        let generations = Set(diagnostics.recentEvents.map(\.sessionGeneration))
        XCTAssertGreaterThan(generations.count, 1, "trace must span session generations")
    }

    // MARK: - Live stream

    func testEventStreamDeliversOrderedEventsWithGeneration() async throws {
        let coordinator = try await makeCoordinator()
        let stream = await coordinator.diagnosticEvents()

        let collector = Task {
            var received: [DaveDiagnosticEvent] = []
            for await event in stream {
                received.append(event)
                if received.count == 3 { break }
            }
            return received
        }

        _ = await coordinator.executeDiscordTransition(11)
        _ = await coordinator.executeDiscordTransition(12)
        _ = await coordinator.executeDiscordTransition(13)

        let received = await collector.value
        XCTAssertEqual(received.count, 3)
        XCTAssertEqual(received.map(\.id), received.map(\.id).sorted(), "stream must stay ordered")
        XCTAssertTrue(received.allSatisfy { $0.sessionGeneration > 0 })
    }

    func testStreamAndTraceAgreeOnWhatHappened() async throws {
        let coordinator = try await makeCoordinator()
        let stream = await coordinator.diagnosticEvents()

        let collector = Task {
            var received: [DaveDiagnosticEvent] = []
            for await event in stream {
                received.append(event)
                if event.kind == .sessionFailedClosed { break }
            }
            return received
        }

        // Drive a failure so both views record the same terminal event.
        _ = try? await coordinator.consumeDiscordGatewayEvent(.externalSender(Data([0x01, 0x02, 0x03])))

        let streamed = await collector.value
        let traced = await coordinator.getDiagnostics().recentEvents

        let streamedFailure = try XCTUnwrap(streamed.last)
        XCTAssertEqual(streamedFailure.kind, .sessionFailedClosed)
        // The same event object appears in both views: an after-the-fact trace
        // and a live stream must never disagree.
        XCTAssertTrue(
            traced.contains(streamedFailure),
            "the streamed event must be identical to the traced one"
        )
    }

    func testMultipleSubscribersAreIndependentAndCancellable() async throws {
        let coordinator = try await makeCoordinator()

        // Each subscription lives entirely inside this scope, so both streams
        // and their iterators are released before the release check below.
        do {
            let first = await coordinator.diagnosticEvents()
            let second = await coordinator.diagnosticEvents()

            let firstTask = Task { () -> Int in
                var count = 0
                for await _ in first {
                    count += 1
                    if count == 2 { break }
                }
                return count
            }
            let secondTask = Task { () -> Int in
                var count = 0
                for await _ in second {
                    count += 1
                    if count == 2 { break }
                }
                return count
            }

            _ = await coordinator.executeDiscordTransition(21)
            _ = await coordinator.executeDiscordTransition(22)

            // Each subscriber receives the full stream independently.
            let firstCount = await firstTask.value
            let secondCount = await secondTask.value
            XCTAssertEqual(firstCount, 2)
            XCTAssertEqual(secondCount, 2)
        }

        // A consumer that stopped iterating must be released, not retained and
        // yielded to for the life of the coordinator.
        var remaining = await coordinator.activeDiagnosticSubscriberCount()
        for _ in 0..<50 where remaining > 0 {
            try await Task.sleep(for: .milliseconds(20))
            remaining = await coordinator.activeDiagnosticSubscriberCount()
        }
        XCTAssertEqual(remaining, 0, "terminated subscribers must be released")
    }

    func testFinishingStreamsTerminatesConsumers() async throws {
        let coordinator = try await makeCoordinator()
        let stream = await coordinator.diagnosticEvents()

        let collector = Task { () -> Int in
            var count = 0
            for await _ in stream { count += 1 }
            return count
        }

        _ = await coordinator.executeDiscordTransition(31)
        await coordinator.finishDiagnosticEventStreams()

        // Terminates rather than hanging.
        _ = await collector.value
        let remaining = await coordinator.activeDiagnosticSubscriberCount()
        XCTAssertEqual(remaining, 0)
    }

    /// A slow consumer must degrade its own stream, never stall the DAVE state
    /// machine or grow memory without bound.
    func testSlowConsumerDoesNotStallTheCoordinator() async throws {
        let coordinator = try await makeCoordinator(
            limits: DaveCoordinatorLimits(maximumTrackedTransitions: 8, diagnosticEventBufferSize: 4)
        )
        // Subscribe but never consume.
        let stream = await coordinator.diagnosticEvents()

        for transitionId in 1...200 {
            _ = await coordinator.executeDiscordTransition(UInt64(transitionId))
        }

        // The coordinator kept running; the stream simply dropped old events.
        let diagnostics = await coordinator.getDiagnostics()
        XCTAssertNotEqual(diagnostics.handshakeState, .failed)

        var delivered = 0
        for await _ in stream {
            delivered += 1
            if delivered >= 4 { break }
        }
        XCTAssertEqual(delivered, 4, "the buffer bounds what a slow consumer retains")
    }

    // MARK: - Watchdog, limits and counts

    func testDiagnosticsReportPendingWatchdogDetail() async throws {
        let coordinator = try await makeCoordinator()
        _ = await coordinator.markDiscordMediaNotReady(reason: "unit test pause", timeout: 60)

        let watchdog = await coordinator.getDiagnostics().watchdog
        XCTAssertEqual(watchdog.state, .pending)
        XCTAssertEqual(watchdog.reason, "unit test pause")
        XCTAssertEqual(watchdog.timeout, 60)
        XCTAssertNotNil(watchdog.startedAt)
        let remaining = try XCTUnwrap(watchdog.secondsRemaining)
        XCTAssertGreaterThan(remaining, 0)
        XCTAssertLessThanOrEqual(remaining, 60)
        XCTAssertNil(watchdog.recoveryHint, "a pending watchdog has no recovery guidance yet")
    }

    func testDiagnosticsReportTimedOutWatchdogWithRecoveryHint() async throws {
        let coordinator = try await makeCoordinator()
        _ = await coordinator.markDiscordMediaNotReady(reason: "expired pause", timeout: 0.01)
        try await Task.sleep(for: .milliseconds(120))

        let diagnostics = await coordinator.getDiagnostics()
        XCTAssertEqual(diagnostics.watchdog.state, .timedOut)
        XCTAssertEqual(diagnostics.watchdog.reason, "expired pause")
        XCTAssertEqual(diagnostics.watchdog.recoveryHint, .recreateSession)
    }

    func testDiagnosticsCarryLimitsAndLiveCounts() async throws {
        let limits = DaveCoordinatorLimits(maximumTrackedTransitions: 12, traceEventCapacity: 50)
        let coordinator = try await makeCoordinator(limits: limits)
        _ = await coordinator.executeDiscordTransition(3)

        let diagnostics = await coordinator.getDiagnostics()
        XCTAssertEqual(diagnostics.limits.maximumTrackedTransitions, 12)
        XCTAssertEqual(diagnostics.limits.traceEventCapacity, 50)
        XCTAssertEqual(diagnostics.stagedTransitionCount, 1, "the buffered Execute is staged")
        XCTAssertEqual(diagnostics.pendingOutboundActionCount, 0)
    }

    // MARK: - Structured failures

    func testNativeFailurePreservesSourceAndReasonSeparately() async throws {
        let coordinator = try await makeCoordinator()
        _ = try? await coordinator.consumeDiscordGatewayEvent(.externalSender(Data([0x01, 0x02, 0x03])))

        let diagnostics = await coordinator.getDiagnostics()
        let failure = try XCTUnwrap(diagnostics.lastFailure, "a rejected sender must produce a structured failure")

        XCTAssertEqual(failure.code, .externalSenderRejected)
        XCTAssertEqual(failure.origin, .nativeMls)
        // Source and reason stay separate so a host can aggregate by source
        // without parsing a formatted string.
        XCTAssertNotNil(failure.nativeSource)
        XCTAssertNotNil(failure.nativeReason)
        XCTAssertFalse(failure.nativeReason?.isEmpty ?? true)
        XCTAssertEqual(failure.sessionGeneration, diagnostics.sessionGeneration)
        XCTAssertEqual(diagnostics.externalSenderState, .rejected)
    }

    func testWatchdogExpiryIsReportedAsAStructuredFailure() async throws {
        let coordinator = try await makeCoordinator()
        _ = await coordinator.markDiscordMediaNotReady(reason: "watchdog failure code", timeout: 0.01)
        try await Task.sleep(for: .milliseconds(120))

        let diagnostics = await coordinator.getDiagnostics()
        let failure = try XCTUnwrap(diagnostics.lastFailure)
        XCTAssertEqual(failure.code, .watchdogExpired)
        XCTAssertEqual(failure.origin, .wrapper)
        XCTAssertNil(failure.nativeSource, "a wrapper-detected failure has no native source")
    }

    func testEveryErrorExposesAFailureCodeAndOrigin() {
        let errors: [DaveError] = [
            .sessionCreationFailed,
            .handshakeFailed(reason: "x"),
            .externalSenderRejected(reason: "x"),
            .externalSenderRequired,
            .externalSenderConflict,
            .transitionConflict(transitionId: 1),
            .unrecognizedRosterMembers(userIds: ["1"]),
            .payloadTooLarge(kind: "k", maximum: 1, actual: 2),
            .mediaNotReady,
            .notConfigured,
            .invalidAuthSessionId("x"),
        ]

        for error in errors {
            // Hosts must be able to branch without parsing localizedDescription.
            XCTAssertFalse(error.failureCode.rawValue.isEmpty, "\(error) has no failure code")
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }

        XCTAssertEqual(DaveError.unrecognizedRosterMembers(userIds: ["1"]).failureOrigin, .policy)
        XCTAssertEqual(DaveError.externalSenderRejected(reason: "x").failureOrigin, .nativeMls)
        XCTAssertEqual(DaveError.notConfigured.failureOrigin, .wrapper)
    }

    /// Diagnostics are shipped to monitoring pipelines, so the whole structure
    /// must round-trip and stay free of secret material.
    func testExpandedDiagnosticsRoundTripThroughCodable() async throws {
        let coordinator = try await makeCoordinator()
        _ = await coordinator.markDiscordMediaNotReady(reason: "round trip", timeout: 30)
        _ = await coordinator.executeDiscordTransition(9)

        let diagnostics = await coordinator.getDiagnostics()
        let encoded = try JSONEncoder().encode(diagnostics)
        let decoded = try JSONDecoder().decode(DaveDiagnostics.self, from: encoded)

        XCTAssertEqual(decoded.sessionGeneration, diagnostics.sessionGeneration)
        XCTAssertEqual(decoded.watchdog.state, diagnostics.watchdog.state)
        XCTAssertEqual(decoded.watchdog.reason, "round trip")
        XCTAssertEqual(decoded.limits, diagnostics.limits)
        XCTAssertEqual(decoded.stagedTransitionCount, diagnostics.stagedTransitionCount)
        XCTAssertEqual(decoded.recentEvents.count, diagnostics.recentEvents.count)
        XCTAssertEqual(decoded.recentEvents.map(\.id), diagnostics.recentEvents.map(\.id))
    }

    /// Archived diagnostics written before 3.0 must still decode, including the
    /// external-sender state spelling that was renamed.
    func testLegacyDiagnosticsWithRenamedExternalSenderStateStillDecode() throws {
        let legacy = """
        {
          "protocolVersion": 1,
          "appliedTransitionCount": 1,
          "handshakeState": "Ready",
          "isExternalSenderRegistered": true,
          "externalSenderState": "registered"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(DaveDiagnostics.self, from: legacy)
        XCTAssertEqual(decoded.externalSenderState, .submitted, "the pre-3.0 spelling must still decode")
        XCTAssertEqual(decoded.watchdog.state, .inactive)
        XCTAssertTrue(decoded.recentEvents.isEmpty)
        XCTAssertNil(decoded.lastFailure)
    }
}
