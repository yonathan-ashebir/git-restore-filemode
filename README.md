# git-restore-filemode

`git-restore-filemode` is a Git extension command that restores only Git's
tracked executable bit for regular files. It follows the destination/source
defaults of `git restore`, but it never restores file contents.

Git discovers extension commands by executable name, so once this binary is on
`PATH` it can be run as:

```sh
git restore-filemode [<options>] [--source=<tree>] <pathspec>...
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

```sh
cargo install --path .
```

## Notes

Only regular Git blobs with modes `100644` and `100755` are restorable. Symlinks,
submodules, missing working tree files, and non-regular paths are not changed.
