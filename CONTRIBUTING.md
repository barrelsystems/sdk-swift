# Contributing

Thanks for your interest in improving this SDK.

## Reporting bugs and requesting features

Use [GitHub Issues](https://github.com/barrelsystems/sdk-swift/issues) for
both. For a bug, include the SDK version, macOS version, and a minimal
repro. For a feature request, describe the use case first — a port that
changes protocol or lifecycle behavior needs to stay aligned with the
other SDKs in this family.

## Local setup

Requires macOS 13+, Swift 6, and Xcode with `swift-format` available via
`xcrun`.

```sh
git clone https://github.com/barrelsystems/sdk-swift
cd sdk-swift
swift build
```

The `Examples/BasicSwiftApp` package builds separately:

```sh
cd Examples/BasicSwiftApp
swift build
```

## Before opening a pull request

Run the same checks CI runs, from the repo root:

```sh
xcrun swift-format lint --strict --recursive Sources Tests Examples
swift build -Xswiftc -warnings-as-errors
swift test -Xswiftc -warnings-as-errors
(cd Examples/BasicSwiftApp && swift build -Xswiftc -warnings-as-errors)
```

Tests use Swift Testing (`@Suite`/`@Test`), not XCTest. CI also runs the
shared cross-SDK conformance suite against this SDK's `TestService`
target; a protocol or lifecycle change should pass that suite, not just
the unit tests above.

## Pull request process

- Target `master`, not `main`.
- Keep commits focused; describe the "why" in the commit message and PR
  description, not just the "what".
- Follow the conventions in this repo's `AGENTS.md` (comment style,
  function style, error handling, blank-line spacing).
- A reviewer may ask you to check whether a fixed bug also exists in the
  other SDKs in this family, since they implement the same protocol
  independently.

## Code of conduct

Participation in this project is governed by our
[Code of Conduct](CODE_OF_CONDUCT.md).
