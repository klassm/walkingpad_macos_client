# Agent rules

## Running tests

- Run the unit tests with:
  `swift test --disable-sandbox`
- The `--disable-sandbox` flag is required when running inside a sandboxed
  agent harness (e.g. OpenCode): SwiftPM wraps manifest compilation in its own
  `sandbox-exec` seatbelt, and nested `sandbox_apply` is not permitted, so
  plain `swift test` fails with
  `sandbox-exec: sandbox_apply: Operation not permitted`.
- Do **not** use `xcodebuild` for tests from an agent session: its SPM
  integration cannot skip the sandbox and fails the same way. The
  `Package.swift` in the repo root is a self-contained test harness (no
  external dependencies) that builds the service code for `swift test`;
  the app itself is built by `walkingpad-client.xcodeproj`.
