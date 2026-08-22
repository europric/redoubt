# Redoubt — air-gapped Ethereum cold wallet

Redoubt is a Flutter app for signing Ethereum transactions on a device
that never touches a network. It moves data in and out only through
[BC-UR](https://github.com/BlockchainCommons/Research/blob/master/papers/bcr-2020-005-ur.md)-encoded
QR codes: an online companion sends an unsigned transaction as a QR
code, Redoubt scans it, signs it offline, and shows the signature back
as another QR code for the companion to broadcast. Redoubt itself has
no networking code path.

## Stack

- [Flutter](https://flutter.dev) / [Dart](https://dart.dev)
- [`blockchain_utils`](https://pub.dev/packages/blockchain_utils) — Ethereum primitives (keys, transactions, encoding)
- [`cbor`](https://pub.dev/packages/cbor) — CBOR encoding for BC-UR payloads
- [`crypto`](https://pub.dev/packages/crypto) / [`cryptography`](https://pub.dev/packages/cryptography) — hashing and cryptographic primitives
- [`mobile_scanner`](https://pub.dev/packages/mobile_scanner) / [`qr_flutter`](https://pub.dev/packages/qr_flutter) — QR scan in, QR render out
- [`flutter_secure_storage`](https://pub.dev/packages/flutter_secure_storage) / [`local_auth`](https://pub.dev/packages/local_auth) — key storage and device biometrics
- [`go_router`](https://pub.dev/packages/go_router) — navigation

See [`pubspec.yaml`](pubspec.yaml) for the full, versioned dependency list.

## Project structure

| Path | Purpose |
|------|---------|
| `lib/features/` | One directory per user-facing feature: account, onboarding, seed, settings, signing, vault. |
| `lib/core/` | Shared, feature-independent code: BIP-39, byte utilities, Ethereum primitives, BC-UR, forms, security, and shared presentation building blocks. |
| `lib/config/` | App-wide configuration: dependency adapters and routing. |
| `test/` | Unit and widget tests, mirroring the `lib/` layout. |
| `integration_test/` | End-to-end and device-level tests (e.g. crypto benchmarks). |
| `tool/wallet_lints/` | Custom lint rules enforced on this codebase. |
| `design/redoubt-brand/` | Brand and design-token source (tokens, components, brand README). |

## Run / build / test

```bash
flutter pub get              # install dependencies
flutter run                  # run on a connected device or simulator
flutter build <platform>     # e.g. flutter build apk, flutter build ios
flutter analyze              # static analysis, including custom wallet_lints rules
flutter test                 # unit and widget tests
```

## License

Redoubt is **source-available**, not open source: the
[PolyForm Noncommercial 1.0.0](LICENSE) license permits personal and
noncommercial use but does not permit commercial use. Tests, test
tooling, and brand assets are carved out from that grant entirely — see
[`LICENSING.md`](LICENSING.md) for the authoritative path-by-path map.

## Disclaimers

- The license text in this repository was assembled by the author
  without professional legal review. It uses the verbatim, unmodified
  PolyForm Noncommercial 1.0.0 text, but no lawyer has confirmed it
  does everything the author intends.
- Redoubt has **not** had an independent security audit. This matters
  more than usual for a project that handles private key material and
  transaction signing — do not trust it with funds you cannot afford
  to lose.
