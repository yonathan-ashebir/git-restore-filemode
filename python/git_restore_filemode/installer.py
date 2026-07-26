from __future__ import annotations

import os
import platform
import shutil
import subprocess
import tarfile
import tempfile
import urllib.error
import urllib.request
from importlib import metadata
from pathlib import Path

from . import __version__

BINARY_NAME = "git-restore-filemode"
REPO_OWNER = os.environ.get("GIT_RESTORE_FILEMODE_REPO_OWNER", "yonathan-ashebir")
REPO_NAME = os.environ.get("GIT_RESTORE_FILEMODE_REPO_NAME", "git-restore-filemode")
REPO_URL = f"https://github.com/{REPO_OWNER}/{REPO_NAME}"


def ensure_executable() -> Path:
    target = os.environ.get("GIT_RESTORE_FILEMODE_TARGET") or detect_target()
    release = release_version()
    executable = cache_path(release, target)

    if executable.exists():
        return executable

    executable.parent.mkdir(parents=True, exist_ok=True)
    if not install_from_release(executable, release, target):
        install_from_cargo(executable, release, target)
    executable.chmod(0o755)
    return executable


def release_version() -> str:
    override = os.environ.get("GIT_RESTORE_FILEMODE_VERSION")
    if override:
        return override

    try:
        package_version = metadata.version("git-restore-filemode")
    except metadata.PackageNotFoundError:
        package_version = __version__

    return f"v{package_version}"


def cache_path(release: str, target: str) -> Path:
    cache_root = os.environ.get("GIT_RESTORE_FILEMODE_CACHE_DIR")
    if cache_root:
        root = Path(cache_root)
    elif platform.system() == "Windows":
        root = Path(os.environ.get("LOCALAPPDATA", Path.home() / "AppData" / "Local"))
        root /= "git-restore-filemode"
    elif platform.system() == "Darwin":
        root = Path.home() / "Library" / "Caches" / "git-restore-filemode"
    else:
        root = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
        root /= "git-restore-filemode"

    return root / release / target / executable_name(target)


def detect_target() -> str:
    system = platform.system()
    machine = platform.machine().lower()

    arch = {
        "x86_64": "x86_64",
        "amd64": "x86_64",
        "aarch64": "aarch64",
        "arm64": "aarch64",
    }.get(machine)

    if not arch:
        raise RuntimeError(f"unsupported CPU architecture: {platform.machine()}")

    if system == "Linux":
        return f"{arch}-unknown-linux"
    if system == "Darwin":
        return f"{arch}-apple-darwin"
    if system == "Windows":
        return f"{arch}-pc-windows-msvc"

    raise RuntimeError(f"unsupported operating system: {system}")


def executable_name(target: str) -> str:
    return f"{BINARY_NAME}.exe" if "windows" in target or "-pc-" in target else BINARY_NAME


def rust_target_for_platform(target: str) -> str:
    if target == "x86_64-unknown-linux":
        return "x86_64-unknown-linux-musl"
    if target == "aarch64-unknown-linux":
        return "aarch64-unknown-linux-musl"
    return target


def install_from_release(destination: Path, release: str, target: str) -> bool:
    asset = f"{BINARY_NAME}-{target}.tar.gz"
    if release == "latest":
        url = f"{REPO_URL}/releases/latest/download/{asset}"
    else:
        url = f"{REPO_URL}/releases/download/{release}/{asset}"

    with tempfile.TemporaryDirectory() as tmp:
        archive = Path(tmp) / asset
        try:
            download(url, archive)
            extract_binary(archive, destination)
            return True
        except (OSError, RuntimeError, tarfile.TarError, urllib.error.URLError):
            return False


def download(url: str, destination: Path) -> None:
    request = urllib.request.Request(url)
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        request.add_header("Authorization", f"Bearer {token}")

    with urllib.request.urlopen(request, timeout=60) as response:
        with destination.open("wb") as output:
            shutil.copyfileobj(response, output)


def extract_binary(archive: Path, destination: Path) -> None:
    expected_names = {BINARY_NAME, f"{BINARY_NAME}.exe"}
    with tarfile.open(archive, "r:gz") as tar:
        for member in tar.getmembers():
            if Path(member.name).name not in expected_names or not member.isfile():
                continue

            source = tar.extractfile(member)
            if source is None:
                continue

            with source:
                with destination.open("wb") as output:
                    shutil.copyfileobj(source, output)
            return

    raise RuntimeError(f"{archive} did not contain {BINARY_NAME}")


def install_from_cargo(destination: Path, release: str, target: str) -> None:
    cargo = shutil.which("cargo")
    rustc = shutil.which("rustc")
    if not cargo or not rustc:
        raise RuntimeError(
            "no matching release asset was available, and Rust/Cargo was not found"
        )

    with tempfile.TemporaryDirectory() as tmp:
        cargo_root = Path(tmp) / "cargo-root"
        rust_target = rust_target_for_platform(target)
        rustup = shutil.which("rustup")
        if rustup:
            subprocess.run([rustup, "target", "add", rust_target], check=True)

        args = [
            cargo,
            "install",
            "--locked",
            "--git",
            REPO_URL,
            "--target",
            rust_target,
            "--bin",
            BINARY_NAME,
            "--root",
            str(cargo_root),
        ]
        if release != "latest":
            args.insert(5, release)
            args.insert(5, "--tag")

        subprocess.run(args, check=True)

        built = cargo_root / "bin" / executable_name(target)
        if not built.exists():
            built = cargo_root / "bin" / rust_target / executable_name(target)
        if not built.exists():
            raise RuntimeError(f"cargo install did not produce {built}")

        shutil.copy2(built, destination)
