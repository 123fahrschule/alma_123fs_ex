# Changelog

All notable changes to this package. Versions follow [Semantic Versioning](https://semver.org/);
see "Versions and upgrading" in the README for what a version number promises before 1.0.
Each release is a Git tag equal to the version (`0.1.0`, no `v` prefix).

Every entry that requires a change in consuming applications has an **Upgrading** note.

## Unreleased

## 0.1.0 — 2026-11-10

First version, verified against the Alma sandbox (see "Verified in the sandbox" in the README).

### Added

- `Alma123FS.Client` (Req, host-level base URL, `Alma-Auth`, configurable timeouts, no retries,
  no redirects) and `Alma123FS.client/1` reading `config :alma_123fs_ex` at call time.
- `Alma123FS.Error` with `kind`, `type`, `status`, `code`, `message`, `reason`, `body`;
  `{:unknown, error}` for state-changing calls whose outcome is uncertain.
- `Alma123FS.Eligibility.check/3` (`POST /v2/payments/eligibility`).
- `Alma123FS.Payments.create/2`, `fetch/2`, `cancel/2`, `list/2`; structs `Payment`,
  `Installment`, `Order`.
- `Alma123FS.IPN` (`X-Alma-Signature`) and the optional `Alma123FS.IPNPlug`.
- `Alma123FS.Webhooks` (`/v1/webhooks`) and `Alma123FS.Webhook` (PHP-compatible signature,
  event parsing) for the beta webhooks — not verified against Alma.
