# Native callback contract

The DAVE C API stores `void *` callback contexts but documents nothing about
when a callback may run, and offers no unregister-and-drain operation. A Swift
wrapper cannot, from the header alone, rule out a callback that begins after
the native object it belongs to has been destroyed — which would dereference a
released Swift object inside the C-to-Swift trampoline.

This document records what the bundled framework actually does, how that is
enforced, and what upstream change would let the workaround be removed.

## Measured behaviour

Across several hundred owners per callback type, every callback in the bundled
`Dave.xcframework` is delivered:

- **synchronously**, inside a native call, never from a queue or timer;
- **on the calling thread**, never on another thread; and
- **never after its owner was destroyed** — zero late deliveries observed.

This holds for all three callbacks the wrapper registers: the MLS failure
callback, the encryptor protocol-version-changed callback, and the pairwise
fingerprint callback.

`Tests/libdave-swiftTests/NativeCallbackContractTests.swift` asserts each of
these properties. It brackets every native call, so "outside a native call"
means exactly that rather than merely "not during registration", and it fails
if no callbacks were observed at all, so it cannot pass vacuously. A framework
rebuild that starts delivering callbacks asynchronously or from another thread
fails those tests instead of silently invalidating the reasoning below.

## Why tombstones are still used

Callback contexts are not freed as soon as their owner is torn down. They are
*retired* — the user closure is dropped so the context becomes inert — and
released only after a grace window (see `DaveNativeCallbackContextRetainer`).

Given the measured behaviour, immediate release would be safe: no callback can
begin once no native call is in flight. The grace window is kept anyway because
that safety depends on two things the wrapper cannot enforce:

1. **The C API's contract, not its current implementation.** Nothing in
   `dave.h` promises synchronous delivery. A future framework build could
   change it, and while the contract tests above would catch that in CI, they
   would not protect a consumer who had already shipped.
2. **Callers honouring the documented serialization.** `DaveSession`,
   `DaveEncryptor`, and `DaveDecryptor` are explicitly not `Sendable` and must
   be externally serialized. A host that violates that — destroying a cryptor
   on one thread while another is inside `encrypt` — turns immediate release
   into a use-after-free. With the tombstone it is an inert no-op.

The cost is bounded and temporary: a small object per native callback owner,
reclaimed after the grace window, with a hard ceiling on the table. The
previous design retained every context until process exit, which grew without
limit in a long-running client; that is what was fixed, and it is the part that
mattered.

## Requested upstream change

Either of these would let the tombstones be removed entirely:

1. **An unregister-and-drain API**, for example
   `daveSessionClearMLSFailureCallback(session)` and
   `daveEncryptorSetProtocolVersionChangedCallback(encryptor, NULL, NULL)` with
   a documented guarantee that, once it returns, no callback is running and
   none will start. The encryptor setter already accepts `NULL`; what is
   missing is the drain guarantee.
2. **A documented delivery guarantee** in `dave.h` stating that callbacks are
   invoked only synchronously, on the calling thread, within a library call,
   and never after the owning handle is destroyed.

Option 2 costs nothing to implement — it documents what the code already does —
and is enough for this wrapper to release contexts immediately.
