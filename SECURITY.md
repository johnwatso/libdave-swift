# Security Policy

## Supported versions

Security fixes are made on `main` and, when practical, the latest tagged
release. Earlier releases are not supported; see the repository's GitHub
Releases page for the current supported tag.

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability. Use the repository's [private security advisory form](https://github.com/johnwatso/libdave-swift/security/advisories/new). If that form is unavailable, contact the repository maintainer through a private channel on their GitHub profile and include `Security: libdave-swift` in the subject.

Include the affected package version or commit, macOS and architecture, a minimal reproduction, impact, and any relevant native-library version information. Do not include production MLS messages, external-sender data, key packages, media ciphertext, private keys, tokens, or Discord account data in a report.

Maintainers will acknowledge reports privately, assess scope, and coordinate a fix and disclosure. Please allow time for a fix before publishing technical details.

## Scope

Report issues in the Swift wrapper, the bundled `Dave.xcframework`, its build/provenance metadata, or the integration guidance. Vulnerabilities in an embedded upstream component should also be reported to that component's maintainers; include the package version and framework checksum so the affected artifact can be identified.
