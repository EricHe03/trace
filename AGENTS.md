# Repository Guidelines

## Project Structure & Module Organization
Trace is organized as layered Swift modules used by both Swift Package Manager and Xcode targets. Core/shared code lives in `TraceCore`, `TraceCompression`, `TraceSecurity`, `TraceNetworking`, `TracePacket`, and `TraceQUIC`. Higher-level features are in `TraceProxy`, `TraceFeatures`, and `TraceUI`. App targets are `Trace` (main app), `TraceVPN` (packet tunnel extension), and `TraceWidget` (widget extension). Tests are in `TraceTests` (unit/integration) and `TraceUITests` (UI). Supporting docs and tooling live in `Docs/`, `Tools/QUIC/`, and `ThirdParty/`.

## Build, Test, and Development Commands
- `git submodule update --init --recursive`: fetch required third-party sources.
- `open Trace.xcodeproj`: open the project for local development/signing.
- `xcodebuild -list -project Trace.xcodeproj`: verify schemes and targets.
- `xcodebuild -project Trace.xcodeproj -scheme Trace -configuration Debug -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' build-for-testing`: CI-aligned simulator build.
- `xcodebuild -project Trace.xcodeproj -scheme Trace -configuration Debug -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' test-without-building`: run tests.
- `swiftformat --lint . --config .swiftformat`: formatting check.
- `swiftlint lint --strict --config .swiftlint.yml`: lint check.

## Coding Style & Naming Conventions
Use Swift 6 conventions with 4-space indentation (`.swiftformat`). Keep file names aligned with primary types (for example, `PacketFlowLoop.swift`). Use `UpperCamelCase` for types and `lowerCamelCase` for members/functions. Test types end with `Tests`. Prefer explicit, module-local changes over cross-layer shortcuts, and follow existing patterns in the module you modify.

## Testing Guidelines
Use XCTest for all tests. Put behavior and parser/networking coverage in `TraceTests`; place UI flow validation in `TraceUITests`. Name test methods with `test...` plus behavior/outcome, such as `testExtractSNIFromValidClientHello`. Add or update tests whenever behavior changes, especially in VPN, MITM proxy, and protocol parsing paths.

## Commit & Pull Request Guidelines
Follow Conventional Commits seen in history: `feat(vpn): ...`, `fix(proxy): ...`, `refactor(networking)!: ...`. Keep commits focused and PRs small. PR descriptions should explain what changed and why, link related issues, include screenshots/screen recordings for UI changes, and call out breaking changes or migration steps.

## Security & Configuration Tips
Report vulnerabilities through GitHub Security Advisories, not public issues. Keep app, VPN, and widget signing settings aligned (bundle IDs, entitlements, App Group). If the VPN extension bundle ID changes, update `providerBundleIdentifier` in `TraceFeatures/VPN/VPNManager.swift`.
