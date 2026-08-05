# Changelog

All notable changes to `libdave-swift` are documented here. The version is the
SemVer Git tag (for example, `1.3.1`); `Package.swift` intentionally does not
carry a second, independently mutable version number.

## [2.0.0] - 2026-08-05

### Release recommendation

Publish this hardening batch as **2.0.0**. It deliberately changes the safe
media-lifecycle contract, expands public enums that consumers may switch over,
and extends the encoded `DaveDiagnostics` schema. A major version makes the
migration explicit instead of letting an existing `from: "1.3.1"` dependency
silently adopt behavior its gateway adapter was not written for.

### Breaking

- Media may only be processed when the coordinator reports it ready for the
  active Discord transition. Applications must treat `.mediaNotReady` and
  `.retryLater` as a drop-and-continue condition, not a reason to reuse old
  cryptographic state.
- Gateway adapters must use the new sequence-aware transition and outbound
  action contract rather than assuming a generated action was delivered.
- Consumers with exhaustive switches over public DAVE error/recovery enums
  must handle the new cases.
- Persisted or transported `DaveDiagnostics` JSON must be treated as
  versioned diagnostic data and refreshed for the 2.0 schema.

### Added

- `consumeDiscordGatewayEvent(_:)`, a sequence-aware, replay-safe Discord
  gateway reducer, plus a bounded, acknowledged outbox of stable action
  envelopes for retrying interrupted WebSocket writes.
- `DaveCoordinatorLimits` to bound untrusted MLS payloads, rosters, media
  frames, tracked transitions, and pending gateway actions before they can grow
  without limit.
- Typed diagnostics and recovery guidance for external-sender registration,
  key-package issuance/delivery, active and pending transitions, session
  generation, and media readiness.
- A media-readiness gate that rejects inbound and outbound media until an
  active ratchet has been authorized by its matching Discord transition.
- Validation for non-empty external-sender payloads and non-zero decimal
  Discord Snowflake IDs before they reach native code.
- `DaveError.externalSenderRejected`, raised when native MLS synchronously
  rejects an external sender, before a key package can be issued.
- Framework checksum verification, an arm64 slice check, and a consumer
  package smoke test in CI.
- Security, third-party provenance, MLS fixture, migration, and
  release-verification documentation.

### Changed

- Later MLS transitions stage their outbound ratchet while established media
  continues on the active one; only the matching Execute Transition swaps it.
- Prepare Epoch is explicitly bound to Discord's `transition_id`, emits
  Transition Ready for later epochs, and cannot activate its staged context
  before the matching Execute Transition.
- Reset and recovery discard all outbound and inbound media cryptors before a
  replacement session can become usable.
- Native callback contexts are made harmless after Swift-side teardown, and
  stale callbacks cannot update a replacement coordinator generation.
- Native key-ratchet handles are retained by their Swift encryptor/decryptor
  wrappers for the full assignment lifetime.
- Negative Swift frame-size arguments now return zero capacity rather than
  being passed to native `size_t` parameters.

### Fixed

- A failed encryptor rebuild can no longer leave the previous ratchet active.
- Empty native output buffers are released correctly.
- The encryptor callback registration avoids a synchronous native callback
  deadlock.

## [1.3.1] - 2026-07-03

### Fixed

- Restored persisted MLS signature key pairs by shipping the generic file
  store in the bundled native framework.

## [1.3.0] - 2026-07-03

### Added

- Inbound media decryption, async pairwise fingerprints, and strict
  concurrency checking.

## [1.2.0] - 2026-06-30

### Added

- Discord DAVE recovery helpers and transition diagnostics.

## [1.1.0] - 2026-06-26

### Changed

- Reliability hardening, dedicated coordinator execution, and an aligned
  macOS deployment target.
