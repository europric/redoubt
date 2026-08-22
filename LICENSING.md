# Licensing

Redoubt is **source-available**, not open source. This file is the
authoritative map of which license applies to which path in this
repository. If a license badge, a nested `LICENSE` file, and this
document ever disagree, this document wins.

## Quick path

1. Read the [License](#license-by-path) table below for the directory
   you care about.
2. Follow the linked license file for the exact terms.
3. If you plan any commercial use, see [Commercial use](#commercial-use)
   first — the root license does not permit it.

## License by path

| Path | License | Notes |
|------|---------|-------|
| `lib/` | [PolyForm Noncommercial 1.0.0](/LICENSE) | Application source. Personal and noncommercial use permitted; commercial use is not. |
| `assets/` | [PolyForm Noncommercial 1.0.0](/LICENSE) | Bundled fonts and static assets shipped with the app. |
| Root config (`pubspec.yaml`, `analysis_options.yaml`, etc.) | [PolyForm Noncommercial 1.0.0](/LICENSE) | Project configuration needed to build the app. |
| `test/` | [All Rights Reserved](/test/LICENSE) | Excluded from the root grant. No reuse rights. |
| `integration_test/` | [All Rights Reserved](/integration_test/LICENSE) | Excluded from the root grant. No reuse rights. |
| `tool/wallet_lints/` | [All Rights Reserved](/tool/wallet_lints/LICENSE) | Excluded from the root grant. No reuse rights. |
| `design/redoubt-brand/` | [All Rights Reserved](/design/redoubt-brand/LICENSE) | Brand assets; excluded from the root grant. No reuse rights. |

Any path not listed above falls back to the root [`LICENSE`](/LICENSE)
(PolyForm Noncommercial 1.0.0).

## Why the carve-out

The root license grants broad personal and noncommercial rights over
the application itself. The excluded paths above are carved out
separately so that:

- Test suites, test tooling, and lint tooling are not accidentally
  redistributable as if they were part of the licensed application.
- Brand assets (name, mark, visual identity) stay fully reserved,
  independent of how permissive the application license is.

The carve-out removes reuse rights for those paths — it does not hide
them. Everything in this repository remains visible under GitHub's
normal terms of service for the repository's current visibility.

## Terminology

Redoubt's license is **source-available**. It is deliberately **not**
"open source" under the Open Source Definition, because the Open
Source Definition forbids restricting commercial use, and this license
does exactly that. Do not describe Redoubt's own license as "open
source" in any documentation, issue, or communication.

## Commercial use

No commercial-licensing contact is currently offered. If you want to
use Redoubt commercially, this repository does not currently provide a
path to do so.

## Contributions

Redoubt is not currently accepting external contributions or pull
requests, so there is no inbound-licensing agreement in place for
contributors at this time.
