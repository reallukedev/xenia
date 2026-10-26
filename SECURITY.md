# Security

Xenia handles people's messages and encryption keys, so security reports get priority.

## Reporting a vulnerability

Please report it privately through GitHub: on the repository's **Security** tab, choose
**Report a vulnerability** (or open
[a new advisory](https://github.com/reallukedev/xenia/security/advisories/new)). Don't open a public
issue, pull request or discussion for it.

Include what you found, how to reproduce it, and what an attacker could do with it. The fix is
discussed in the private advisory, and you'll be credited there unless you'd rather not be.

## Scope

- The apps and their extensions (`apple/`), the shared engine (`crates/xenia-core`) and the push
  gateway (`services/push-gateway`).
- Problems in the Matrix Rust SDK itself belong with
  [its maintainers](https://github.com/matrix-org/matrix-rust-sdk/security). If you're not sure
  where something lives, report it here and it'll be passed on.
- The scripts in `scripts/dev/` only drive a local test server and aren't meant to be secure.

## Supported versions

Fixes go into the latest release.
