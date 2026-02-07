# Repository Guidelines

## Project Structure & Module Organization
`Trace` is a modular Swift 6 iOS project. Main app code lives in `Trace/` (views, services, repositories). Extension targets are `TraceVPN/` (packet tunnel) and `TraceWidget/` (widget source for `TraceWidgetExtension`). Shared modules are split by responsibility: `TraceCore/` (models/storage/logging), `TraceNetworking/`, `TraceSecurity/`, `TraceCompression/`, `TracePacket/`, `TraceProxy/`, `TraceFeatures/`, and `TraceUI/`. Tests live in `TraceTests/` (unit/integration) and `TraceUITests/` (UI flows). Third-party tunnel code is in the git submodule `ThirdParty/hev-socks5-tunnel/`.

## Build, Test, and Development Commands
- `git submodule update --init --recursive`: pull required third-party sources after clone.
- `open Trace.xcodeproj`: primary local development entry point.
- `xcodebuild -project Trace.xcodeproj -scheme Trace -configuration Debug -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' build-for-testing`: CI-aligned simulator build.
- `xcodebuild -project Trace.xcodeproj -scheme Trace -configuration Debug -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' test-without-building`: run tests from built artifacts.
- `swiftformat --lint . --config .swiftformat`: formatting check.
- `swiftlint lint --strict --config .swiftlint.yml`: lint check.

## Coding Style & Naming Conventions
Use Swift 6 conventions and keep module boundaries clean. Formatting uses 4-space indentation and rules from `.swiftformat`; linting uses `.swiftlint.yml`. Follow existing naming patterns: types/protocols in `UpperCamelCase`, methods/properties in `lowerCamelCase`. Prefer descriptive file names matching primary types (for example, `NetworkCaptureService.swift`). SwiftUI screens should keep the `...View` suffix.

## Testing Guidelines
Write or update tests for behavior changes. Use XCTest naming like `test<Scenario>_<ExpectedResult>()` when practical; keep test files as `*Tests.swift`. Run `Cmd+U` in Xcode or the `xcodebuild` commands above. The shared test plan is `TraceTests/Trace.xctestplan`. There is no explicit coverage threshold in CI, so focus on meaningful assertions around changed logic and regressions.

## Commit & Pull Request Guidelines
History follows Conventional Commits (for example, `feat(widget): ...`, `fix(session): ...`, `refactor(compression)!: ...`). Keep commits focused and PRs small. PRs should explain what changed and why, link related issues, include screenshots/screen recordings for UI work, call out breaking changes or migration steps, and confirm build/lint/tests status.

## Security & Configuration Notes
Do not open public issues for vulnerabilities; use GitHub Security Advisories. Keep bundle identifiers, entitlements, and `APP_GROUP_IDENTIFIER` aligned across app/extension targets. If the VPN extension bundle ID changes, also update `providerBundleIdentifier` in `TraceFeatures/VPN/VPNManager.swift`.
