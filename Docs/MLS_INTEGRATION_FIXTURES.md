# MLS Integration Fixture Contract

The unit tests cover wrapper and state-machine behavior, but a real encrypted DAVE integration test needs genuine, internally consistent MLS artifacts. Do not substitute random bytes: an external sender, key package, Welcome, Commit, roster, and ratchets are bound to one MLS group state.

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
