# git-restore-filemode

`git-restore-filemode` is a simple Git extension command that restores only Git's
tracked executable bit for regular files. It follows the destination/source
defaults of `git restore`, but it never restores file contents.

## Examples

Restore working tree file modes from the index:

```sh
git restore-filemode -- script.sh
```

Restore staged file modes from `HEAD`:

```sh
git restore-filemode --staged -- script.sh
```

Restore both the index and working tree from a specific commit:

```sh
git restore-filemode --source=HEAD~1 --staged --worktree -- bin/
```

## Supported options

- `-s`, `--source <tree-ish>`: restore file modes from a tree-ish.
- `-S`, `--staged`: restore the index.
- `-W`, `--worktree`: restore the working tree.
- `--ignore-unmerged`: skip unmerged index entries when restoring from the index.
- `--pathspec-from-file <file>`: read pathspecs from a file, or `-` for stdin.
- `--pathspec-file-nul`: split `--pathspec-from-file` input on NUL bytes.
- `-q`, `--quiet`: suppress non-fatal messages.

Default source selection matches `git restore`:

- Working tree restore defaults to the index.
- Staged restore defaults to `HEAD`.
- `--source` overrides the default source.

## Install

Git discovers extension commands by executable name, so once this binary is on
`PATH` it can be run as:

```sh
git restore-filemode [<options>] [--source=<tree>] <pathspec>...
```

### Shell

The shell installer first downloads the matching executable from GitHub
Releases. If a release asset is unavailable, it checks for Rust and falls back to
building with Cargo. Linux release binaries are static and selected only by CPU
architecture, so there is no glibc/musl split.

```sh
curl -fsSL https://raw.githubusercontent.com/yonathan-ashebir/git-restore-filemode/main/install.sh | bash
```

The installer reads the current `PATH` and installs into the first preferred
directory it finds there. By default it tries system directories first and falls
back to user directories when system install paths are unavailable or not
writable.

```sh
curl -fsSL https://raw.githubusercontent.com/yonathan-ashebir/git-restore-filemode/main/install.sh | bash -s -- --user
curl -fsSL https://raw.githubusercontent.com/yonathan-ashebir/git-restore-filemode/main/install.sh | bash -s -- --system
```

System candidates include `/usr/local/bin`, `/opt/homebrew/bin` on macOS,
`/usr/bin`, and `/bin`. User candidates include `~/.local/bin`, `~/bin`, and
the closest `%LOCALAPPDATA%` equivalents on Windows. Set
`GIT_RESTORE_FILEMODE_INSTALL_DIR` to force a specific directory.

### Python

```sh
uv tool install git-restore-filemode
pip install --user git-restore-filemode
```

The Python package installs a small launcher named `git-restore-filemode`. On
first run it downloads the matching release executable into a per-user cache, or
falls back to Cargo when Rust is installed.

### Node

```sh
npm install -g git-restore-filemode
pnpm add -g git-restore-filemode
bun install -g git-restore-filemode
```

The npm package follows the same release-download-first behavior and keeps the
native executable inside the installed package.

### Cargo

```sh
cargo install --path .
```

After this package is published to crates.io, the direct install command will
be:

```sh
cargo install git-restore-filemode
```

## Notes

Only regular Git blobs with modes `100644` and `100755` are restorable. Symlinks,
submodules, missing working tree files, and non-regular paths are not changed.

Registry metadata for PyPI and npm is included, but publishing those packages is
intentionally left for a later release step.

## Release Targets

- Linux x64 static: `x86_64-unknown-linux`
- Linux ARM64 static: `aarch64-unknown-linux`
- macOS Intel: `x86_64-apple-darwin`
- macOS Apple Silicon: `aarch64-apple-darwin`
- Windows x64: `x86_64-pc-windows-msvc`
- Windows ARM64: `aarch64-pc-windows-msvc`
