# Contributing to Trace

Thanks for your interest in contributing to **Trace**. Contributions are welcome — bug reports, feature requests, docs improvements, and pull requests.

## Code of Conduct

This project follows the Code of Conduct in `CODE_OF_CONDUCT.md`. By participating, you agree to uphold it.

## Before You Start

- **Search existing issues** before filing a new one.
- For **larger changes** (new features, architectural refactors, UX changes), please open an issue first so we can align on approach.
- If you found a **security vulnerability**, please do **not** open a public issue. Use GitHub Security Advisories: https://github.com/Trace-iOS/Trace/security/advisories/new

## Development Setup

Prerequisites (see `README.md` for more context):

- macOS with **Xcode 26.2** (Swift 6)
- iOS **16.0**+ deployment target
- Apple Developer Team with **Network Extension** entitlements
- A **physical iOS device** for end-to-end capture (packet tunnel is unavailable in the simulator)

Setup steps:

1. Open `Trace.xcodeproj`.
2. Update signing for all targets (App, `TraceVPN`, `TraceWidgetExtension`).
3. Set `APP_GROUP_IDENTIFIER` so the app, VPN extension, and widget share storage.
4. Update bundle identifiers and entitlements for App, `TraceVPN`, and `TraceWidgetExtension`.

## Coding Style & Quality

- Keep changes focused and prefer small PRs.
- Run formatting and linting when possible:
  - SwiftFormat config: `.swiftformat`
  - SwiftLint config: `.swiftlint.yml`
- Follow existing patterns in the module you’re changing (e.g. `TraceCore`, `TraceNetworking`, `TraceVPN`, `TraceUI`).

## Tests

- Add or update tests when behavior changes (unit tests in `TraceTests`, UI tests in `TraceUITests`).
- Prefer running tests in Xcode. Note that VPN / packet-tunnel end-to-end behavior generally requires a device.

## Pull Requests

When opening a PR:

- Describe **what** changed and **why** (include links to related issues).
- Include **screenshots/screen recordings** for UI changes.
- Mention any **breaking changes** or migration steps.
- Ensure the project builds (and tests pass when applicable).
- Prefer Conventional Commits-style titles (examples: `feat(vpn): ...`, `fix(ui): ...`). Maintainers may squash-merge.

## License

By contributing to this repository, you agree that your contributions will be licensed under the MIT License (see `LICENSE`).
