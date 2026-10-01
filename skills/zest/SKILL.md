---
name: zest
description: Install, run, update, and remove Zig CLI tools with zest. Use when a Zig CLI tool needs to be installed from a git repository, moved onto PATH, upgraded to its latest release, or removed, and for diagnosing a tool that fails to build or install.
---

# zest

[zest](https://github.com/JustinWoodring/zest) builds Zig CLI tools from any git
repository with the native Zig build pipeline and puts them on `PATH` under a
single name. It exists to remove the "clone the repo, figure out the build,
remember where you put the binary, repeat on every update" loop.

## Core commands

```sh
zest install github.com/user/my-cli-tool   # build and install
zest list                                   # what is installed
zest run <tool> [args...]                   # run it, installing ephemerally if needed
zest update <tool>                          # rebuild at the latest tag
zest remove <tool>                          # unlink, delete the clone, forget it
zest inspect [target]                       # check whether a project is installable
zest self-update                            # upgrade zest itself
```

## Resolving a source

- `github.com/user/repo` — host shorthand
- `https://host/user/repo.git` or `git@host:user/repo.git` — explicit git URL
- `my-cli-tool` — a bare name, resolved through the
  [Zigistry](https://zigistry.dev) registry; ambiguous names are never guessed
- `@v1.2.0` — target a tag. Omit it and you get the latest semantic-version tag,
  falling back to the default branch when the repository has no tags.

Everything is compiled on your machine. There are no prebuilt binaries.

## Version policy

The default target is the **latest semantic-version tag**, not the newest commit.
If a repository has no tags, zest uses its default branch and keeps working;
when a tag appears, the next install or update picks it up.

`zest update` checks out the new ref and rebuilds. If the build fails, the
source is rolled back so the installed binary still matches its recorded commit.

## Before installing

`zest inspect` tells you what zest would do without doing it — the binaries a
project builds, the name of the executable, its license, the latest upstream
tag, and registry visibility. Useful when a repository builds several
executables.

## Layout

Everything lives under `$XDG_DATA_HOME/zest` (default `~/.local/share/zest`):

- `bin/` — symlinks to built binaries; this directory goes on `PATH`
- `src/<tool>/` — the staged clone, with `dist/` holding build output
- `state.json` — the install manifest: source, version, commit, install time

`zest remove` removes all three for that tool. `zest self-update` is the only
operation permitted to replace the `zest` binary itself; a third-party package
that builds an executable named `zest` is refused outright so it can never shadow
the real one.

## Agent skills

A tool may ship agent skills in a `skills/` directory. With
[zymposium](https://github.com/JustinWoodring/zymposium) installed, zest
re-syncs a tool's skills after every install, update, and remove, so
`zest update <tool>` refreshes the binary and the agent's skills together.

zymposium is optional: without it, zest behaves identically.

## When an install fails

- **"no `zig` compiler found"** — install Zig, or re-run the zest install script,
  which bootstraps a private toolchain.
- **"produced N executables and none is unambiguously '<name>'"** — the project
  builds several binaries and none is named after the tool; install the intended
  binary from its own repository.
- **"produced a binary named 'zest'"** — refused by design.
- **A failed build leaves the previous version installed.** `zest update` does
  not destroy a working install when the new build is broken; run
  `zest inspect` on the source to see why.
