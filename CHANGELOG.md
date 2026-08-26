# Changelog

All notable changes to `libdave-swift` are documented here. The version is the
SemVer Git tag (for example, `1.3.1`); `Package.swift` intentionally does not
carry a second, independently mutable version number.

## [4.0.0] - 2026-08-27

### Release recommendation

Publish this batch as a **major release**. `DaveFailureCode` gains public enum
cases, so consumers with exhaustive switches must update even though the
runtime changes are otherwise compatible.

### Breaking

- `DaveFailureCode` gains `sessionUnavailable` and `decryptorUnavailable`.
  Creation failures no longer collapse into unrelated failure categories.

### Fixed

- **Commit roster updates are now applied as deltas.** libdave reports added or
  changed members with signatures and removed members with empty signatures;
  the coordinator previously replaced its complete roster with that change
  map. A member-add commit could therefore make every existing member disappear
  from diagnostics, verification, and decryptor synchronization.
- `DaveCoordinatorLimits` now preserves its invariants after public property
  mutation and Codable decoding, not only during initialization. Negative or
  oversized values are normalized, trace and diagnostic buffers have hard
  ceilings, and a non-finite media-readiness timeout no longer reaches the
  trapping `Duration.seconds` conversion.
- Session, encryptor, and decryptor construction failures now emit distinct,
  machine-readable diagnostic codes.

### Added

- A pinned native rebuild pipeline for Discord libdave `v1.1.1/cpp`, mlspp,
  OpenSSL, and vcpkg. The bundled XCFramework now includes exact build metadata,
  license texts, an SPDX 2.3 SBOM, and checksum verification.
- A live external-sender integration test that establishes a real MLS group,
  verifies authenticators and fingerprints, exchanges encrypted audio, adds a
  third member, stages Execute, rekeys, and decrypts at both receivers. CI
  rebuilds the pinned C++ inputs before running it.

### Validation

- Added regression tests for roster-delta application, post-initialization
  limit mutation, hostile Codable values, non-finite watchdog timeouts, bounded
  diagnostics, and distinct native-construction failure codes.
- Refreshed `Dave.xcframework`; archive SHA-256 is
  `f83079a354aa6ba00d68da155c21382a672e26fc4c4198a04392c577e7ec7e0d`.

## [3.0.1] - 2026-08-22

### Fixed

- **A synchronous native MLS proposal failure now requests immediate session
  recreation.** `DaveSessionCoordinator.processProposals` previously converted
  a missing native commit/welcome result into `DaveError.invalidState`, whose
  `retryLater` recovery hint could lead a host to send the following Commit to
  the already failed native MLS session. Proposal processing now fails the
  coordinator closed immediately and throws `DaveError.sessionFailed`, whose
  recovery hint is `recreateSession`.
- Native proposal-failure diagnostics retain the native source and reason under
  the existing `proposalsProcessingFailed` code. Fail-closed teardown is
  idempotent for a session generation, so a delayed copy of the callback or a
  later gateway event cannot overwrite the original cause.
- Commit and Welcome events received after the proposal failure stop at the
  coordinator's failed-state guard and never reach the dead native session.

### Validation

- Added a focused native-failure seam and regression test covering recovery
  classification, diagnostic preservation, exactly-once fail-closed behavior,
  and rejection of later Commit and Welcome events without fabricated MLS
  bytes.
- The bundled `Dave.xcframework` is unchanged in this release.

## [3.0.0] - 2026-08-19

### Release recommendation

Publish as **3.0.0**. Two cases are added to the public `DaveError` enum, which
breaks exhaustive switches — the same reason 2.0.0 was a major release.
Everything else in this batch is source-compatible: new parameters have
defaults, new result properties are additive, and `DaveDiagnostics` now decodes
older payloads instead of rejecting them.

### Breaking

- `DaveError` gains `invalidAuthSessionId` and `unrecognizedRosterMembers`.
  Consumers with exhaustive switches must handle them.
- The package now builds in the Swift 6 language mode and its manifest uses
  swift-tools-version 6.0, so a Swift 6 toolchain is required. This is not a
  new constraint in practice: the package already requires macOS 26, whose SDK
  ships one.
- `DaveExternalSenderState.registered` is renamed `submitted`, and a `rejected`
  case is added. Archived diagnostics containing the old spelling still decode.
  There is deliberately no `accepted` case: `daveSessionSetExternalSender`
  returns `void` and the C API exposes no way to observe that a pending MLS
  group was created, so only rejection is detectable.

### Fixed

- **Fixed a process crash (SIGSEGV) on an empty external-sender payload.**
  `DaveSession.setExternalSender(Data())` reached a native unmarshaller that
  reads the buffer without checking its length. The wrapper's `baseAddress`
  check did not prevent it, because empty `Data` may still vend a non-`nil`
  pointer. All buffer-taking MLS entry points now reject zero-length input
  before crossing into native code. `DaveSessionCoordinator` already validated
  empty payloads, so only direct users of the low-level API were affected.

- **A long call no longer fails closed once its transition window fills.** The
  replay ledger and the staged-transition window are now aged out oldest-first
  instead of failing the session at `maximumTrackedTransitions`. Each Discord
  transition stored two permanent ledger entries, so at the default bound a
  session died after roughly thirty membership changes — reachable within a
  single busy voice call. Entries with unacknowledged outbound actions, and
  those for the active or a still-staged transition, are never evicted, so
  gateway retries and live state keep working. `DaveDiagnostics` reports
  `evictedTransitionCount`.
- **Native callback contexts are reclaimed.** Contexts were retained until
  process exit — one per session, one per rebuilt encryptor, and one per
  pairwise-fingerprint request — so a client that reconnected and verified
  identities grew memory for as long as it ran. They are now retired when their
  owner tears down and reclaimed after a grace window, with a hard ceiling.
- **A replaced key ratchet is no longer destroyed while native code may still
  read it.** `dave.h` documents that the cryptors borrow a ratchet handle
  without taking ownership, and libdave's decryptor keeps using the previous
  epoch's ratchet for frames already in flight when a re-key lands. Replaced
  ratchets are now held for a grace window that comfortably exceeds the native
  transition expiry.
- **The media-readiness watchdog runs on a monotonic clock.** An NTP correction
  or a sleep/wake cycle could previously expire a healthy transition
  immediately or postpone a stalled one indefinitely.
- The async pairwise-fingerprint call can no longer suspend forever if a
  native callback never arrives; it returns `nil` after a timeout.
- **A diagnostics subscriber no longer hangs forever when its coordinator is
  released.** Subscriber bookkeeping lived in the actor's isolated state and the
  termination handler hopped back onto the actor, so once the coordinator was
  deallocated nothing could finish the streams — a host building a coordinator
  per voice connection leaked one permanently suspended task per connection.
  Bookkeeping moved to a lock-guarded broadcaster that a cancelled consumer and
  `deinit` can both reach.
- **A specific failure is no longer flattened by a later generic one.** The
  native MLS failure callback fires during the same native call that a
  synchronous path may already have classified precisely, and overwrote it with
  `nativeMlsFailure`. The first report — the cause — is now kept.
- **Every public gateway entry point records a diagnostic event**, not only
  `consumeDiscordGatewayEvent(_:)`. A host using the documented per-message
  helpers previously got an almost empty trace.

### Added

- Roster verification. `DiscordDaveTransitionResult` and
  `DiscordDaveGatewayResult` carry `rosterUserIds` and
  `unrecognizedRosterUserIds`, and the coordinator exposes `currentRoster()`,
  `unrecognizedRosterMembers()`, `rosterMemberSignature(for:)`, and
  `epochAuthenticator()`. A roster member the voice session never announced is
  what an end-to-end encrypted call exists to surface; it is always reported,
  and `DaveCoordinatorLimits.unrecognizedRosterMemberPolicy` can escalate it to
  a fail-closed session.
- `DavePersistedIdentityStore` for the MLS signature keys written when an
  `authSessionId` is used: locate them, purge one identity (on logout or
  account switch) or all of them, and harden their permissions.
- `DaveCoordinatorLimits.mediaReadinessTimeout`, replacing a 10-second default
  that was repeated through the coordinator. Per-call `timeout` parameters now
  default to it.
- A randomized state-machine test suite driving random gateway sequences
  through `consumeDiscordGatewayEvent(_:)` and asserting the safety invariants
  after every step, plus a test that proves the coordinator's dedicated serial
  executor really does serialize actor work.
- A native-boundary fuzz suite that drives the MLS and media entry points with
  adversarial payloads, including mutations of a genuine marshalled key
  package, which reach far deeper into the native parser than random bytes.
  This is what surfaced the empty-external-sender crash above.
- Reconnect soak tests that cycle sessions, cryptors, and the full coordinator
  lifecycle hundreds of times and assert that no native lifetime accumulates.
- A fixture-driven MLS integration harness. A captured session dropped into
  `Tests/libdave-swiftTests/Fixtures/mls-integration/` now runs end to end
  without new code; until then the test skips with an explanation, so the one
  remaining coverage gap is visible in test output. A committed self-check
  fixture keeps the harness itself exercised.
- **A bounded diagnostic trace.** `DaveDiagnostics.recentEvents` keeps the most
  recent state-machine events — timestamp, session generation, kind, transition
  ID, outcome (`applied`, `staged`, `activated`, `replayed`, `rejected`,
  `failed`, `observed`), media readiness, recovery hint, and emitted, pending
  and acknowledged outbound action IDs. It survives reset and recovery, because
  the events explaining *why* a session was recreated are the ones a post-mortem
  needs, and each entry names its generation. Capacity comes from
  `DaveCoordinatorLimits.traceEventCapacity`. Events never carry MLS payloads,
  ratchets, keys, or external-sender bytes — a payload appears only as a byte
  count — so the whole structure is safe to export.
- **A live diagnostics stream.** `DaveSessionCoordinator.diagnosticEvents()`
  returns an `AsyncStream<DaveDiagnosticEvent>` carrying the same events in the
  order the coordinator applied them, each tagged with its session generation so
  a host can discard events from a session it has already replaced. Subscribers
  are independent and individually bounded: a slow consumer drops its own oldest
  events rather than growing memory or stalling the DAVE state machine.
- **Watchdog state, limits, and counts in diagnostics.** The media-readiness
  watchdog is reported as inactive, pending (with start time, timeout, remaining
  time and reason), or timed out (with reason and recovery hint), alongside the
  configured `DaveCoordinatorLimits` and live staged-transition and pending
  outbound action counts.
- **Structured failure reporting.** `DaveDiagnostics.lastFailure` is a
  `DaveFailureReport` carrying a machine-readable `DaveFailureCode`, an origin
  (`nativeMls`, `wrapper`, or `policy`), the native MLS source and reason kept
  as separate fields, and the session generation. `DaveError` exposes matching
  `failureCode` and `failureOrigin`, so hosts branch on codes instead of parsing
  `lastMlsError`.
- AddressSanitizer and ThreadSanitizer CI jobs, a release-configuration test
  run, and `-warnings-as-errors` on the build.
- `Docs/NATIVE_CALLBACK_CONTRACT.md`, recording the measured native callback
  delivery behaviour (always synchronous, on the calling thread, never after
  owner destruction), the tests that hold it in place, why the inert-tombstone
  workaround is still kept, and the upstream unregister-and-drain API that would
  remove the need for it.

### Security

- An `authSessionId` is validated before it reaches native code. It is
  interpolated straight into a key-store filename, so a value containing a path
  separator or `..` could place or delete a signature key outside the identity
  directory.
- The identity directory is tightened from `0755` to `0700` on session
  creation. The native library already creates key files `0600`, but the
  world-readable directory let any local user enumerate which identities exist.

## [2.0.1] - 2026-08-05

### Fixed

- Correctly handle Discord's epoch-1 sole-member reset: Execute Transition
  `0` now executes immediately without sending Transition Ready, clears the
  ordinary transition watchdog, and keeps media fail-closed until a real MLS
  Commit or Welcome establishes a usable ratchet.

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
