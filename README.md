# git-restore-filemode

`git-restore-filemode` is a simple Git extension command that restores only Git's
tracked executable bit for regular files. It follows the destination/source
defaults of `git restore`, but it never restores file contents.

```sh
curl -fsSL https://raw.githubusercontent.com/yonathan-ashebir/git-restore-filemode/main/install.sh | bash
```

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

### Bash script

```sh
curl -fsSL https://raw.githubusercontent.com/yonathan-ashebir/git-restore-filemode/main/install.sh | bash
```

Attempts system dependent global (system) installation path, falling back to user. Accepts --user and --system flags to force use either. Downloads compatible binary when available, building from source otherwise (requires cargo/rust)

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
