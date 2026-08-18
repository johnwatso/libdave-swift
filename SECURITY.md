# Security Policy

## Supported versions

Security fixes are made on `main` and, when practical, the latest tagged
release. Earlier releases are not supported; see the repository's GitHub
Releases page for the current supported tag.

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability. Use the repository's [private security advisory form](https://github.com/johnwatso/libdave-swift/security/advisories/new). If that form is unavailable, contact the repository maintainer through a private channel on their GitHub profile and include `Security: libdave-swift` in the subject.

Include the affected package version or commit, macOS and architecture, a minimal reproduction, impact, and any relevant native-library version information. Do not include production MLS messages, external-sender data, key packages, media ciphertext, private keys, tokens, or Discord account data in a report.

Maintainers will acknowledge reports privately, assess scope, and coordinate a fix and disclosure. Please allow time for a fix before publishing technical details.

## Persisted identity material

A coordinator created with an `authSessionId` makes the native library persist
an MLS signature private key under `Discord Key Storage/` in
`$XDG_CONFIG_HOME` (or `~/.config`). That key is the client's stable identity
in a DAVE group: anyone who can read it can impersonate that identity.

- Key files are created `0600` by the native library, and libdave-swift
  tightens the containing directory to `0700` when a session with a persistent
  identity is created.
- Purge the key on logout or account switch with
  `DavePersistedIdentityStore.purge(authSessionId:)`; the identity is
  regenerated transparently on next use. `purgeAll()` removes every persisted
  identity for the user account.
- Treat the `authSessionId` as a filename component, not free text.
  libdave-swift rejects values containing path separators, `..`, control
  characters, or more than 128 UTF-8 bytes.

## Roster verification

`DiscordDaveGatewayResult.unrecognizedRosterUserIds` lists MLS group members
that the voice session never announced. A non-empty value means the
cryptographic group is wider than the call the user believes they joined, and
should be surfaced. Set
`DaveCoordinatorLimits.unrecognizedRosterMemberPolicy` to `.failClosed` to stop
media instead of only reporting it.

## Scope

Report issues in the Swift wrapper, the bundled `Dave.xcframework`, its build/provenance metadata, or the integration guidance. Vulnerabilities in an embedded upstream component should also be reported to that component's maintainers; include the package version and framework checksum so the affected artifact can be identified.
