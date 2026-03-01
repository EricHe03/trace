# Repository Guidelines

## Project Structure & Module Organization
`Trace` is an iOS app with multiple Swift modules and extensions:
- `Trace/`: main app target.
- `TraceVPN/`: Packet Tunnel extension.
- `TraceWidget/`: widget/live activity source (`TraceWidgetExtension` target).
- Shared modules: `TraceCore`, `TraceFeatures`, `TraceProxy`, `TracePacket`, `TraceNetworking`, `TraceSecurity`, `TraceCompression`, `TraceUI`.
- Tests: `TraceTests/` (unit) and `TraceUITests/` (UI).
- Third-party and tooling: `ThirdParty/` (submodules) and `Tools/QUIC/` scripts.

## Build, Test, and Development Commands
Use the same commands CI runs:

```bash
git submodule update --init --recursive
open Trace.xcodeproj
```

```bash
xcodebuild -project Trace.xcodeproj -scheme Trace -configuration Debug -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' build-for-testing
xcodebuild -project Trace.xcodeproj -scheme Trace -configuration Debug -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' test-without-building
swiftformat --lint . --config .swiftformat
swiftlint lint --strict --config .swiftlint.yml
```

For QUIC toolchain changes, also run:
`./Tools/QUIC/build_quiche_apple.sh` and `./Tools/QUIC/verify_quiche_symbols.sh build/quiche/quiche.xcframework`.

## Coding Style & Naming Conventions
- Swift 6 with 4-space indentation (see `.swiftformat`).
- Run SwiftFormat and SwiftLint before pushing.
- Keep module boundaries clean; place shared logic in `TraceCore`/`TraceFeatures`, not UI targets.
- Naming: types/protocols `UpperCamelCase`, functions/properties `lowerCamelCase`, and file names that match the primary type (for example, `NetworkRequestRepository.swift`).
- Prefer explicit, descriptive names over abbreviations unless already established (for example, `URL`, `DNS`).

## Testing Guidelines
- Framework: XCTest (`TraceTests`, `TraceUITests`).
- Add or update tests with every behavior change.
- Unit tests should be narrowly scoped and named `FeatureBehaviorTests.swift`.
- No strict coverage percentage is enforced, but changed paths should be meaningfully covered.

## Commit & Pull Request Guidelines
- Follow Conventional Commits style seen in history: `type(scope): summary` (for example, `feat(vpn): ...`, `fix(diagnostics): ...`, `refactor(capture): ...`).
- Keep commits focused; split refactors from functional changes.
- PRs should include: purpose, key changes, linked issue(s), test evidence, and screenshots/screen recordings for UI changes.
- Call out breaking changes, migration steps, and signing/entitlement impacts explicitly.
