use std::collections::BTreeSet;
use std::ffi::{OsStr, OsString};
use std::fs;
use std::io::{self, Read};
use std::path::PathBuf;
use std::process::{Command, Output};

use clap::{ArgAction, Parser, ValueHint};

#[cfg(unix)]
use std::os::unix::ffi::OsStringExt;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

#[derive(Debug, Parser)]
#[command(
    name = "git-restore-filemode",
    bin_name = "git restore-filemode",
    version,
    about = "Restore Git-tracked executable file modes without restoring file contents.",
    override_usage = "git restore-filemode [<options>] [--source=<tree>] <pathspec>..."
)]
struct Cli {
    /// Restore file modes from this tree-ish instead of the default source.
    #[arg(short = 's', long = "source", value_name = "tree-ish")]
    source: Option<String>,

    /// Restore the index.
    #[arg(short = 'S', long = "staged", action = ArgAction::SetTrue)]
    staged: bool,

    /// Restore the working tree.
    #[arg(short = 'W', long = "worktree", action = ArgAction::SetTrue)]
    worktree: bool,

    /// Suppress non-fatal messages.
    #[arg(short = 'q', long = "quiet", action = ArgAction::SetTrue)]
    quiet: bool,

    /// Ignore unmerged index entries when restoring from the index.
    #[arg(long = "ignore-unmerged", action = ArgAction::SetTrue)]
    ignore_unmerged: bool,

    /// Read pathspec from file.
    #[arg(long = "pathspec-from-file", value_name = "file", value_hint = ValueHint::FilePath)]
    pathspec_from_file: Option<PathBuf>,

    /// With --pathspec-from-file, pathspec elements are separated with NUL.
    #[arg(long = "pathspec-file-nul", action = ArgAction::SetTrue)]
    pathspec_file_nul: bool,

    /// Pathspecs to restore.
    #[arg(
        value_name = "pathspec",
        trailing_var_arg = true,
        allow_hyphen_values = true,
        value_parser = clap::builder::OsStringValueParser::new()
    )]
    pathspecs: Vec<OsString>,
}

#[derive(Debug)]
struct Error {
    message: String,
    prefixed: bool,
}

type Result<T> = std::result::Result<T, Error>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum FileMode {
    Regular,
    Executable,
}

#[derive(Debug, Clone)]
struct ModeEntry {
    mode: FileMode,
    path: Vec<u8>,
}

#[derive(Debug)]
enum Source {
    Index,
    Treeish(String),
}

fn main() {
    if let Err(err) = run() {
        eprintln!("{err}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let cli = Cli::parse();
    let restore_worktree = cli.worktree || !cli.staged;
    let restore_index = cli.staged;
    let source = select_source(&cli, restore_index);
    let pathspecs = collect_pathspecs(&cli)?;

    if pathspecs.is_empty() {
        return Err(Error::fatal("you must specify path(s) to restore"));
    }

    let entries = read_source_entries(&source, &pathspecs, cli.ignore_unmerged)?;
    if entries.is_empty() {
        return Err(Error::fatal(
            "pathspec did not match any regular files with restorable filemode",
        ));
    }

    if restore_index {
        restore_index_modes(&entries)?;
    }

    if restore_worktree {
        restore_worktree_modes(&entries)?;
    }

    if !cli.quiet {
        // Deliberately silent on success, matching git-restore's normal behavior.
    }

    Ok(())
}

fn select_source(cli: &Cli, restore_index: bool) -> Source {
    if let Some(source) = &cli.source {
        Source::Treeish(source.clone())
    } else if restore_index {
        Source::Treeish("HEAD".to_string())
    } else {
        Source::Index
    }
}

fn collect_pathspecs(cli: &Cli) -> Result<Vec<OsString>> {
    if cli.pathspec_file_nul && cli.pathspec_from_file.is_none() {
        return Err(Error::fatal(
            "the option '--pathspec-file-nul' requires '--pathspec-from-file'",
        ));
    }

    let Some(pathspec_file) = &cli.pathspec_from_file else {
        return Ok(cli.pathspecs.clone());
    };

    if !cli.pathspecs.is_empty() {
        return Err(Error::fatal(
            "'--pathspec-from-file' and pathspec arguments cannot be used together",
        ));
    }

    let mut bytes = Vec::new();
    if pathspec_file.as_os_str() == "-" {
        io::stdin()
            .read_to_end(&mut bytes)
            .map_err(|err| Error::fatal(format!("failed to read pathspecs from stdin: {err}")))?;
    } else {
        bytes = fs::read(pathspec_file).map_err(|err| {
            Error::fatal(format!(
                "failed to read pathspecs from '{}': {err}",
                pathspec_file.display()
            ))
        })?;
    }

    Ok(split_pathspec_file(&bytes, cli.pathspec_file_nul))
}

fn split_pathspec_file(bytes: &[u8], nul_separated: bool) -> Vec<OsString> {
    let separator = if nul_separated { b'\0' } else { b'\n' };

    bytes
        .split(|byte| *byte == separator)
        .filter_map(|part| {
            let mut part = part;
            if !nul_separated && part.ends_with(b"\r") {
                part = &part[..part.len() - 1];
            }
            if part.is_empty() {
                None
            } else {
                Some(os_string_from_bytes(part.to_vec()))
            }
        })
        .collect()
}

fn read_source_entries(
    source: &Source,
    pathspecs: &[OsString],
    ignore_unmerged: bool,
) -> Result<Vec<ModeEntry>> {
    match source {
        Source::Index => read_index_entries(pathspecs, ignore_unmerged),
        Source::Treeish(treeish) => read_tree_entries(treeish, pathspecs),
    }
}

fn read_index_entries(pathspecs: &[OsString], ignore_unmerged: bool) -> Result<Vec<ModeEntry>> {
    let mut args = os_args(["ls-files", "-s", "-z", "--full-name", "--"]);
    args.extend(pathspecs.iter().cloned());

    let output = run_git(args)?;
    let mut entries = Vec::new();
    let mut unmerged_paths = BTreeSet::new();

    for record in output.stdout.split(|byte| *byte == b'\0') {
        if record.is_empty() {
            continue;
        }

        let (metadata, path) = split_record(record)?;
        let fields = split_fields(metadata);
        if fields.len() < 3 {
            return Err(Error::fatal("git ls-files returned an unexpected record"));
        }

        if fields[2] != b"0" {
            unmerged_paths.insert(display_path(path));
            continue;
        }

        if let Some(mode) = FileMode::from_git_mode(fields[0]) {
            entries.push(ModeEntry {
                mode,
                path: path.to_vec(),
            });
        }
    }

    if !ignore_unmerged && !unmerged_paths.is_empty() {
        let paths = unmerged_paths.into_iter().collect::<Vec<_>>().join(", ");
        return Err(Error::fatal(format!(
            "path has unmerged index entries; use --ignore-unmerged to skip: {paths}"
        )));
    }

    Ok(entries)
}

fn read_tree_entries(treeish: &str, pathspecs: &[OsString]) -> Result<Vec<ModeEntry>> {
    let mut args = os_args(["ls-tree", "-r", "-z", "--full-tree"]);
    args.push(OsString::from(treeish));
    args.push(OsString::from("--"));
    args.extend(pathspecs.iter().cloned());

    let output = run_git(args)?;
    let mut entries = Vec::new();

    for record in output.stdout.split(|byte| *byte == b'\0') {
        if record.is_empty() {
            continue;
        }

        let (metadata, path) = split_record(record)?;
        let fields = split_fields(metadata);
        if fields.is_empty() {
            return Err(Error::fatal("git ls-tree returned an unexpected record"));
        }

        if let Some(mode) = FileMode::from_git_mode(fields[0]) {
            entries.push(ModeEntry {
                mode,
                path: path.to_vec(),
            });
        }
    }

    Ok(entries)
}

fn restore_index_modes(entries: &[ModeEntry]) -> Result<()> {
    update_index_mode(FileMode::Executable, entries)?;
    update_index_mode(FileMode::Regular, entries)
}

fn update_index_mode(mode: FileMode, entries: &[ModeEntry]) -> Result<()> {
    let paths = entries
        .iter()
        .filter(|entry| entry.mode == mode)
        .map(|entry| os_string_from_bytes(entry.path.clone()))
        .collect::<Vec<_>>();

    if paths.is_empty() {
        return Ok(());
    }

    let mut args = os_args(["update-index", mode.update_index_arg(), "--"]);
    args.extend(paths);
    run_git(args)?;
    Ok(())
}

#[cfg(unix)]
fn restore_worktree_modes(entries: &[ModeEntry]) -> Result<()> {
    let root = repo_root()?;
    let changes = entries
        .iter()
        .map(|entry| {
            let relative = PathBuf::from(os_string_from_bytes(entry.path.clone()));
            let path = root.join(relative);
            let metadata = fs::symlink_metadata(&path).map_err(|err| {
                Error::fatal(format!(
                    "cannot read working tree path '{}': {err}",
                    display_path(&entry.path)
                ))
            })?;

            if !metadata.file_type().is_file() {
                return Err(Error::fatal(format!(
                    "cannot restore filemode for non-regular path '{}'",
                    display_path(&entry.path)
                )));
            }

            let current_mode = metadata.permissions().mode();
            let desired_mode = match entry.mode {
                FileMode::Executable => current_mode | 0o111,
                FileMode::Regular => current_mode & !0o111,
            };

            Ok((path, current_mode, desired_mode))
        })
        .collect::<Result<Vec<_>>>()?;

    for (path, current_mode, desired_mode) in changes {
        if current_mode == desired_mode {
            continue;
        }

        let mut permissions = fs::metadata(&path)
            .map_err(|err| {
                Error::fatal(format!(
                    "cannot read working tree path '{}': {err}",
                    path.display()
                ))
            })?
            .permissions();
        permissions.set_mode(desired_mode);
        fs::set_permissions(&path, permissions).map_err(|err| {
            Error::fatal(format!(
                "cannot set filemode for working tree path '{}': {err}",
                path.display()
            ))
        })?;
    }

    Ok(())
}

#[cfg(not(unix))]
fn restore_worktree_modes(_entries: &[ModeEntry]) -> Result<()> {
    Err(Error::fatal(
        "working-tree filemode restoration is only supported on Unix-like platforms",
    ))
}

fn repo_root() -> Result<PathBuf> {
    let output = run_git(os_args(["rev-parse", "--show-toplevel"]))?;
    let mut path = output.stdout;
    while path.ends_with(b"\n") || path.ends_with(b"\r") {
        path.pop();
    }

    Ok(PathBuf::from(os_string_from_bytes(path)))
}

fn split_record(record: &[u8]) -> Result<(&[u8], &[u8])> {
    let Some(tab_index) = record.iter().position(|byte| *byte == b'\t') else {
        return Err(Error::fatal("git returned an unexpected record"));
    };

    Ok((&record[..tab_index], &record[tab_index + 1..]))
}

fn split_fields(metadata: &[u8]) -> Vec<&[u8]> {
    metadata
        .split(|byte| *byte == b' ')
        .filter(|field| !field.is_empty())
        .collect()
}

fn run_git<I, S>(args: I) -> Result<Output>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    let args = args
        .into_iter()
        .map(|arg| arg.as_ref().to_os_string())
        .collect::<Vec<_>>();
    let output = Command::new("git")
        .args(&args)
        .output()
        .map_err(|err| Error::fatal(format!("failed to run git: {err}")))?;

    if output.status.success() {
        Ok(output)
    } else {
        Err(Error::git(output))
    }
}

fn os_args<const N: usize>(args: [&str; N]) -> Vec<OsString> {
    args.into_iter().map(OsString::from).collect()
}

#[cfg(unix)]
fn os_string_from_bytes(bytes: Vec<u8>) -> OsString {
    OsString::from_vec(bytes)
}

#[cfg(not(unix))]
fn os_string_from_bytes(bytes: Vec<u8>) -> OsString {
    OsString::from(String::from_utf8_lossy(&bytes).into_owned())
}

fn display_path(path: &[u8]) -> String {
    String::from_utf8_lossy(path).into_owned()
}

impl FileMode {
    fn from_git_mode(mode: &[u8]) -> Option<Self> {
        match mode {
            b"100644" => Some(Self::Regular),
            b"100755" => Some(Self::Executable),
            _ => None,
        }
    }

    fn update_index_arg(self) -> &'static str {
        match self {
            Self::Regular => "--chmod=-x",
            Self::Executable => "--chmod=+x",
        }
    }
}

impl Error {
    fn fatal(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            prefixed: false,
        }
    }

    fn git(output: Output) -> Self {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
        let message = if !stderr.is_empty() {
            stderr
        } else if !stdout.is_empty() {
            stdout
        } else {
            format!("git command failed with status {}", output.status)
        };

        Self {
            message,
            prefixed: true,
        }
    }
}

impl std::fmt::Display for Error {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        if self.prefixed {
            write!(formatter, "{}", self.message)
        } else {
            write!(formatter, "fatal: {}", self.message)
        }
    }
}
