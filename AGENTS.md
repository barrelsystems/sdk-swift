## This file loads on every prompt

State a rule here only if it's short and always relevant. Push anything longer
or conditional to a pointed-to doc. This repo is published publicly — never
add a reference here (or anywhere else in this repo) to internal tooling,
ticket IDs, team names, or a non-public sibling repo's name/path
(`infrastructure`, the Home Repo). The other public repos in this SDK family
(sdk-electron/sdk-tauri/sdk-swift/sdk-conformance-harness) may be referenced
where structurally necessary — a dependency, a CI job driving the
conformance harness.

## Size and dependency budget

This SDK ships inside other people's apps — every dependency and byte is a
cost to them, not us. Default to Apple's native frameworks (`CryptoKit`,
`Foundation`, `AppKit`) over a package; a new SPM dependency needs a specific
reason the native framework can't cover. The one sanctioned exception: a
library this SDK wraps rather than merely uses (`Sparkle`) — a normal SPM
dependency, since Swift Package Manager has no "optional peer dependency"
concept the way npm does.

## Error handling

Every I/O path (installation-ID persistence, check-in requests, Policy
signature verification) fails open: keep the prior state, never throw, never
retry in a loop. A thrown error is reserved for synchronous, caller-fixable
misconfiguration (e.g. a blank credential passed to `initialize()`). No force
unwrap (`!`) or force-try (`try!`) outside the declared-but-deferred-init
pattern `SparkleUpdaterAdapter.updater` already uses; prefer `guard let`/`if
let` elsewhere.

## Testing framework

Swift Testing (`@Suite`/`@Test`), not XCTest.

## Commit policy

Ask for the user's explicit go-ahead on this specific diff before every
`git commit` — including when a skill's own steps say to commit automatically.

## Commit convention

Conventional Commits (`type: description`).

## Comments

Comment only on non-obvious constraints, invariants, or workarounds; keep
each explanation self-contained. A comment is at most 3 lines.

## Function style

Free functions for standalone/pure logic (e.g. `verifyAndParsePolicy`),
methods for anything that reads `self`. Mark a type `@MainActor` only when it
genuinely touches UI-adjacent, main-thread-only APIs (e.g. `SPUUpdater`).

## Function arguments

Once a function takes more than one optional parameter, or any boolean/flag
parameter whose meaning isn't obvious at the call site, use a dedicated
params struct instead of positional params.

## Blank-line spacing

Leave a blank line between logical sections in any file — after an import
block, around a multi-line loop/conditional/callback, between otherwise-
unrelated top-level declarations.
