#![cfg(unix)]

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::time::{SystemTime, UNIX_EPOCH};

use std::os::unix::fs::PermissionsExt;

struct TestRepo {
    path: PathBuf,
}

impl TestRepo {
    fn new(name: &str) -> Self {
        let mut path = std::env::temp_dir();
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time is before UNIX epoch")
            .as_nanos();
        path.push(format!(
            "git-restore-filemode-{name}-{}-{unique}",
            std::process::id()
        ));
        fs::create_dir_all(&path).expect("failed to create temp repo");
        git(&path, ["init", "-q"]);

        Self { path }
    }

    fn write(&self, path: &str, contents: &str) {
        let path = self.path.join(path);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).expect("failed to create parent dir");
        }
        fs::write(path, contents).expect("failed to write file");
    }

    fn set_executable(&self, path: &str, executable: bool) {
        set_executable(&self.path.join(path), executable);
    }

    fn commit_all(&self, message: &str) {
        git(&self.path, ["add", "."]);
        git(
            &self.path,
            [
                "-c",
                "user.name=Test User",
                "-c",
                "user.email=test@example.com",
                "commit",
                "-q",
                "-m",
                message,
            ],
        );
    }

    fn restore_filemode<const N: usize>(&self, args: [&str; N]) -> Output {
        Command::new(env!("CARGO_BIN_EXE_git-restore-filemode"))
            .args(args)
            .current_dir(&self.path)
            .output()
            .expect("failed to run git-restore-filemode")
    }
}

impl Drop for TestRepo {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

#[test]
fn restores_worktree_mode_from_index_without_touching_contents() {
    let repo = TestRepo::new("worktree-from-index");
    repo.write("script.sh", "#!/bin/sh\necho original\n");
    repo.set_executable("script.sh", true);
    repo.commit_all("add executable script");

    repo.write("script.sh", "#!/bin/sh\necho changed\n");
    repo.set_executable("script.sh", false);

    let output = repo.restore_filemode(["script.sh"]);

    assert_success(output);
    assert!(is_executable(&repo.path.join("script.sh")));
    assert_eq!(
        fs::read_to_string(repo.path.join("script.sh")).expect("failed to read script"),
        "#!/bin/sh\necho changed\n"
    );
}

#[test]
fn staged_restore_uses_head_by_default() {
    let repo = TestRepo::new("staged-from-head");
    repo.write("tool", "echo tool\n");
    repo.set_executable("tool", true);
    repo.commit_all("add executable tool");

    repo.set_executable("tool", false);
    git(&repo.path, ["add", "tool"]);
    assert_eq!(index_mode(&repo.path, "tool"), "100644");

    let output = repo.restore_filemode(["--staged", "tool"]);

    assert_success(output);
    assert_eq!(index_mode(&repo.path, "tool"), "100755");
    assert!(!is_executable(&repo.path.join("tool")));
}

#[test]
fn explicit_source_can_restore_worktree_from_head_even_when_index_differs() {
    let repo = TestRepo::new("source-head");
    repo.write("run", "echo one\n");
    repo.set_executable("run", true);
    repo.commit_all("add executable");

    repo.set_executable("run", false);
    git(&repo.path, ["add", "run"]);
    assert_eq!(index_mode(&repo.path, "run"), "100644");

    let output = repo.restore_filemode(["--source=HEAD", "--worktree", "run"]);

    assert_success(output);
    assert!(is_executable(&repo.path.join("run")));
    assert_eq!(index_mode(&repo.path, "run"), "100644");
}

#[test]
fn reads_pathspecs_from_file() {
    let repo = TestRepo::new("pathspec-file");
    repo.write("bin/a", "echo a\n");
    repo.write("bin/b", "echo b\n");
    repo.set_executable("bin/a", true);
    repo.set_executable("bin/b", true);
    repo.commit_all("add executables");

    repo.set_executable("bin/a", false);
    repo.set_executable("bin/b", false);
    fs::write(repo.path.join("paths.txt"), "bin/a\n").expect("failed to write pathspec file");

    let output = repo.restore_filemode(["--pathspec-from-file=paths.txt"]);

    assert_success(output);
    assert!(is_executable(&repo.path.join("bin/a")));
    assert!(!is_executable(&repo.path.join("bin/b")));
}

fn git<const N: usize>(repo: &Path, args: [&str; N]) -> Output {
    let output = Command::new("git")
        .args(args)
        .current_dir(repo)
        .output()
        .expect("failed to run git");
    assert_success(output)
}

fn assert_success(output: Output) -> Output {
    assert!(
        output.status.success(),
        "command failed\nstatus: {}\nstdout:\n{}\nstderr:\n{}",
        output.status,
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    output
}

fn set_executable(path: &Path, executable: bool) {
    let mut permissions = fs::metadata(path)
        .expect("failed to stat file")
        .permissions();
    let current = permissions.mode();
    let desired = if executable {
        current | 0o111
    } else {
        current & !0o111
    };
    permissions.set_mode(desired);
    fs::set_permissions(path, permissions).expect("failed to chmod file");
}

fn is_executable(path: &Path) -> bool {
    fs::metadata(path)
        .expect("failed to stat file")
        .permissions()
        .mode()
        & 0o111
        != 0
}

fn index_mode(repo: &Path, path: &str) -> String {
    let output = git(repo, ["ls-files", "-s", path]);
    let stdout = String::from_utf8(output.stdout).expect("git output was not utf-8");
    stdout
        .split_whitespace()
        .next()
        .expect("missing index mode")
        .to_string()
}
