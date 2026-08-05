# Migrating to libdave-swift 2.0

Version 2.0 makes the safe Discord DAVE flow explicit. Upgrade it before
updating SwiftBot: resolve the latest immutable `2.0.x` package tag, run the bot's
Voice integration tests, then deploy the SwiftBot change separately.

## What changed

- A Welcome or Commit can prepare a newer ratchet without making it the active
  outbound ratchet. The matching Execute Transition is what authorizes the
  activation.
- Execute Transition may arrive before its binary MLS payload. The coordinator
  retains that signal and applies the matching transition when it arrives.
- Replayed gateway events are idempotent, while a conflicting payload for the
  same transition ID is a recovery condition.
- Outbound gateway actions are delivery-aware. Treat an emitted action as a
  durable intent until the gateway write succeeds and the action is
  acknowledged; retry the same envelope after reconnect rather than asking MLS
  to generate different bytes.
- An initial MLS key package requires the Discord external sender. The old
  timer/fallback pattern that published one before the sender arrived is no
  longer safe.
- If native MLS rejects an external sender while it is being registered, the
  coordinator throws `DaveError.externalSenderRejected` and fails closed.
  Recreate the Voice session; do not retry the same opaque bytes as though
  they were a valid MLS artifact.
- The coordinator rejects oversized MLS payloads, rosters, media frames, and
  unbounded transition/outbox growth according to `DaveCoordinatorLimits`.

## Gateway adapter shape

Keep one `DaveSessionCoordinator` actor for the lifetime of one Discord Voice
session. Pass every DAVE gateway input through
`consumeDiscordGatewayEvent(_:)`, then deliver the returned pending action
envelopes in their listed order. Only acknowledge an envelope with
`acknowledgeDiscordGatewayAction(_:)` after the WebSocket write reports
success.

On a WebSocket reconnect, request `pendingDiscordGatewayActions()` again and
retry the unchanged payloads. Do not regenerate a key package, commit/welcome,
or transition-ready action merely because a write was interrupted. Reset or
recreate the coordinator only when its recovery hint calls for that action or
when the entire Voice session is being replaced.

For the small number of integrations that keep the older per-event helpers,
use a transition ID for every Welcome, Commit, and Execute event. Avoid the
legacy `processDiscordTransition(_:)` entry point in production: it has no
transition ID and therefore cannot safely model Discord's Execute ordering.

## Prepare Epoch and Execute Transition

Discord's Prepare Epoch (opcode 24) has its own `transition_id`; it is not
interchangeable with the MLS epoch number. Feed it through the gateway reducer
and deliver the resulting actions exactly as for a Welcome or Commit:

```swift
let prepared = try await coordinator.consumeDiscordGatewayEvent(
    .prepareEpoch(
        protocolVersion: protocolVersion,
        epoch: epoch,
        transitionId: transitionID
    )
)
try await deliver(prepared) // includes .transitionReady(transitionID) for later epochs

let executed = try await coordinator.consumeDiscordGatewayEvent(
    .executeTransition(transitionID)
)
try await deliver(executed)
```

For an established group (epoch greater than one), Prepare Epoch stages the
new outbound ratchet and prepares existing receive transforms while the active
outbound ratchet remains in service. Only the matching Execute Transition
activates the staged outbound ratchet. Do not pause a working announcer solely
because Prepare Epoch arrived, and do not switch its media to the new epoch
until Execute has been consumed.

For Discord's epoch-1 sole-member reset, the gateway instead sends Execute
Transition `0` immediately after Prepare Epoch. Consume it immediately and do
not send Transition Ready for ID `0`. Native MLS deliberately leaves the
fresh local group pending, so media must remain paused until a later genuine
Commit or Welcome establishes a ratchet; this state has no normal ten-second
transition deadline.

## Announcer playback rules

The TTS/playback layer should consult the coordinator's returned diagnostics
or media state before it sends an Opus frame:

1. If media is ready, encrypt and send normally.
2. If the error is `.mediaNotReady` or its recovery hint is `.retryLater`, drop
   the real-time frame and continue the state machine. Do not queue audio
   indefinitely and do not reuse a previous encryptor or ratchet.
3. If the result needs recovery, stop the current announcer item, execute the
   ordered recovery gateway actions, and let the normal Voice reconnect policy
   decide whether to retry the announcement.
4. After an epoch/transition completes, resume only with the active state
   reported by the coordinator; do not infer readiness from receiving a Commit,
   Welcome, or Prepare Epoch alone. A later-epoch Prepare remains staged until
   its matching Execute Transition.

This intentionally favors a brief dropped announcement frame over encrypted
audio with stale key material. For an announcer, that is both easier to
recover from and much easier to diagnose.

## Source and diagnostics migration

`DaveError`, recovery, and diagnostic enums have new cases. Update exhaustive
switches with the new cases and include a `default`/`@unknown default` branch
where appropriate for your deployment model.

`DaveDiagnostics` has additional fields (session generation, staged and active
transition IDs, outbox state). Treat it as an observation payload, not a
durable database schema. If diagnostics JSON is persisted, add a versioned
wrapper or a backward-compatible decoder before mixing 1.x and 2.0 records.

## Limits

The defaults are intentionally generous for a normal Discord Voice session.
If SwiftBot has tighter operational bounds, provide them when constructing the
coordinator:

```swift
let limits = DaveCoordinatorLimits(
    maximumMlsPayloadBytes: 1_048_576,
    maximumRosterMembers: 1_000,
    maximumMediaFrameBytes: 65_535,
    maximumTrackedTransitions: 64,
    maximumPendingOutboundActions: 64
)
let coordinator = DaveSessionCoordinator(authSessionId: sessionID, limits: limits)
```

Do not set a limit to zero to disable it: the public initializer clamps every
limit to at least one, specifically to avoid an unbounded or invalid native
path.
