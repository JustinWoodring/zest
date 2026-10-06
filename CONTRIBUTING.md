# Contributing to zest

Thanks for your interest in improving zest. This document describes how to get
a change merged.

## Reporting issues

Open an issue at <https://github.com/JustinWoodring/zest/issues> and include:

- Your OS and architecture (for example, `x86_64-linux`, `aarch64-macos`,
  `x86_64-windows`).
- The `zig version` you are using.
- The exact `zest` command you ran and its full output.
- The output of `zest inspect <project-or-package>`, which summarizes the
  project's build, binaries, and registry status. Redact anything sensitive.

## Getting set up

```sh
git clone https://github.com/JustinWoodring/zest
cd zest
zig build            # build zig-out/bin/zest
zig build test       # unit tests
```

Requirements: Zig 0.17.0 or newer, plus `git`. The first build may fetch the
pinned `dragonfruit` package if it is not already cached; the test fixtures
themselves remain hermetic.

## Development workflow

Run these before opening a pull request:

```sh
zig build                 # must build with no warnings
zig build test            # unit tests
./scripts/mock-e2e.sh     # hermetic end-to-end suite (no network)
./scripts/mock-install.sh # POSIX installer suite
```

The POSIX installer test uses Python 3's standard PTY module to verify that
`curl | sh` can prompt through the controlling terminal.

`scripts/mock-install.ps1` covers the Windows installer and is exercised by CI
on `windows-latest`; you only need it if you are changing `install.ps1`.

## Code style

zest follows the conventions of the Zig standard library and the Zig project:

- Format with the canonical `zig fmt`; CI rejects unformatted code.
- Use 4 spaces of indentation. Never use tabs.
- Prefer `const` over `var`, and `orelse`/`catch` over branching where they
  read better.
- Keep public declarations documented with `///` comments that explain *why*,
  not *what*. Every source file carries a copyright and `SPDX-License-Identifier`
  header.
- Keep the tool boring: no clever metaprogramming, no hidden global state, and
  no new dependencies without discussion.
- Errors that a user can act on are printed to stderr with a `zest: ` prefix
  and turned into a specific exit code. Do not let internal Zig errors escape
  as `internal error:` unless they are genuinely bugs.

## Agent skills integration (optional)

`src/skills.zig` is the one place zest knows about
[zymposium](https://github.com/JustinWoodring/zymposium). It is deliberately
small and deliberately optional: when zymposium is absent, `syncSkills` returns
immediately and nothing changes.

Two rules govern any change here:

- The hook must never fail a zest command. `install`, `update`, and `remove`
  report success on their own terms; a zymposium failure is a note on stderr and
  nothing more. Tests cover the missing-binary case.
- The hook is scoped to one tool (`zymposium sync --tool <name>`), so it must
  never be widened into a full sync that could disturb other tools' skills.

Anything that changes what zest does without zymposium installed does not
belong in this module.

## Tests

Every behavior change needs a test. Tests live next to the code they cover as
`test` blocks, except end-to-end behavior, which belongs in
`scripts/mock-e2e.sh`.

- Unit tests must be hermetic: no network, no filesystem outside a temp dir,
  no reliance on the host toolchain layout.
- New CLI behavior should be covered by the e2e suite, and new installer
  behavior by the install suite.
- Prefer a test that fails for the right reason over one that merely exercises
  a code path.

## Pull requests

1. Fork the repository and create a topic branch.
2. Make your change with tests, and make sure `zig build test`,
   `./scripts/mock-e2e.sh`, and `./scripts/mock-install.sh` all pass.
3. Update `README.md` if you change user-visible behavior.
4. Open a pull request describing the motivation and the approach. Keep the
   change focused; unrelated cleanups belong in their own commit.
5. CI must be green on Linux, macOS, and Windows before merge.

## Versioning and releases

`main` is the development branch. Releases are made by the maintainer by
pushing an annotated `vX.Y.Z` tag, which triggers CI to cross-build the
release binaries and attach them to the GitHub release. Contributors do not
push tags or releases; open a pull request instead.

Because zest installs and upgrades the latest semantic-version tag by default,
every user-visible change should be mentioned in the release notes that the
maintainer writes at tag time.

## Licensing

By contributing you agree that your contributions are licensed under the MIT
license that covers this project. Add your name to [CONTRIBUTORS](CONTRIBUTORS)
if you would like to be credited.
