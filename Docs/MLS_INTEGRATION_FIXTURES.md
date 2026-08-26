# MLS Integration Test and Fixture Contract

The native runtime test now creates genuine, internally consistent MLS
artifacts in-process. Do not substitute random bytes: an external sender, key
package, Welcome, Commit, roster, and ratchets are bound to one MLS group state.

## Running the complete runtime path

Build the pinned native framework and test-only external sender, then run the
Swift integration test:

```bash
Scripts/build-native-framework.sh
DAVE_EXTERNAL_SENDER_HELPER="$PWD/.build/native-rebuild/build/integration/dave_external_sender_helper" \
  swift test --filter RuntimeMLSIntegrationTests
```

`RuntimeMLSIntegrationTests` establishes A and B through a live proposal,
Commit, and Welcome; checks the complete roster, epoch authenticator, pairwise
fingerprint, and encrypted audio; adds C in a second epoch; verifies C remains
blocked until Execute; then proves A's rekeyed media decrypts at B and C. CI
rebuilds the same immutable native inputs before running this test.

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

The test-only external-sender executable closes that remaining cryptographic
gap without adding test entry points to the shipped XCFramework. Captured
fixtures remain useful for production gateway ordering and recovery sequences;
they are complementary to, not a replacement for, the runtime loopback.

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
2. Send the emitted key package to the live external sender, apply the corresponding Welcome or Commit, and verify that a key ratchet is installed.
3. Confirm a joining member remains blocked until the matching Execute Transition, then verify encrypted outbound and inbound frame processing.
4. Apply a second transition and verify that members re-key; exercise invalid-transition recovery as a separate fixture.
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
