# MLS Integration Fixture Contract

The unit tests cover wrapper and state-machine behavior, but a real encrypted DAVE integration test needs genuine, internally consistent MLS artifacts. Do not substitute random bytes: an external sender, key package, Welcome, Commit, roster, and ratchets are bound to one MLS group state.

## Running a fixture

`Tests/libdave-swiftTests/MLSIntegrationFixtureTests.swift` is the harness for
these fixtures. Drop a JSON file into
`Tests/libdave-swiftTests/Fixtures/mls-integration/` and it runs automatically;
see `EXAMPLE.json.txt` in that directory for the format.

Until a fixture is captured, `testCapturedMlsSessionsRunEndToEnd` skips with an
explanation, so the missing coverage is visible in test output rather than
silently absent. A committed `harness-selfcheck.json` — malformed bytes only,
no secret material — keeps the harness's own discovery, decoding, and assertion
paths exercised in the meantime, so a captured fixture lands in a harness that
is known to work.

## What a captured fixture can and cannot verify

**A captured Welcome cannot be replayed into a fresh session.** This is a
property of MLS plus the current C API, not a limitation of the harness, and it
bounds what this whole approach can prove.

A Welcome seals the group secrets to the HPKE init key in the key package the
joining client published. `daveSessionGetMarshalledKeyPackage` returns a *new*
init key on every call — verified: two reads from a single session differ, and
so do two sessions sharing one `authSessionId`. With a persisted identity the
signature and encryption keys are stable, but the init key is regenerated and
never written to the key store, so its private half exists only in the memory of
the process that generated it. Once that process exits, no later session can
decrypt that Welcome.

A captured fixture therefore verifies:

- that genuine external-sender bytes are accepted and produce a key package;
- that genuine Welcome/Commit bytes drive the gateway state machine, action
  emission, and transition sequencing as expected; and
- that malformed or out-of-order real-world sequences recover correctly.

It cannot verify key ratchet installation, re-keying, or encrypted media
round-trips, because all three sit behind decrypting the Welcome.

Closing that remaining gap needs one of:

- **an in-process loopback**, by extending the C shim in the upstream C++
  repository with test-only entry points that mint an external sender and its
  proposals. Two clients can then be driven through a full join, re-key, and
  media exchange with no captured data, and it runs in CI; or
- **a live verification run** against a disposable Voice channel, asserting the
  same properties in-process while the session is still alive. This exercises
  the real path but produces nothing replayable, so it is a manual gate rather
  than a regression test.

## Fixture inputs

Capture these from a disposable, non-production test Voice session or generate them with a controlled upstream libdave harness:

- serialized external-sender bytes;
- serialized Welcome and/or Commit bytes, in the order received;
- the protocol version, synthetic group ID, transition ID, and the complete numeric Snowflake roster supplied with each transition;
- the expected gateway actions (`mlsKeyPackage`, `transitionReady`, or ordered recovery actions); and
- a non-secret test media frame with its expected round-trip result.

Do not commit production guild IDs, account IDs, key packages, private keys, credentials, live media, or a fixture that can join a production MLS group. Redact metadata and use a newly generated disposable group whenever the fixture is refreshed.

## Required integration assertions

1. Configure the coordinator with a numeric local Snowflake and register the captured external sender.
2. Send the emitted key package into the fixture harness, apply the corresponding Welcome or Commit, and verify that a key ratchet is installed.
3. Confirm media remains blocked until the matching Execute Transition, then verify encrypted outbound and inbound frame processing.
4. Apply a second transition and verify that both directions re-key; exercise invalid-transition recovery as a separate fixture.
5. Verify that reset/recovery drops old cryptors and that an old native callback cannot change the replacement session's state.

## External-sender validation boundary

The native `daveSessionSetExternalSender` C API returns `void`. libdave-swift
drains any failure reported synchronously by the native MLS callback, fails the
coordinator closed, and throws `DaveError.externalSenderRejected` before it can
issue a key package. A failure reported later through that callback also fails
the coordinator closed.

That is a reliable malformed-payload safety boundary, but it is not an
end-to-end proof that a sender belongs to the later Welcome/Commit and media
flow. Do not use `isExternalSenderRegistered` as the sole integration
assertion: validate a captured, internally consistent disposable fixture as
described above.
