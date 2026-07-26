#!/usr/bin/env bash
set -euo pipefail

binary_name="git-restore-filemode"
repo_owner="${GIT_RESTORE_FILEMODE_REPO_OWNER:-yonathan-ashebir}"
repo_name="${GIT_RESTORE_FILEMODE_REPO_NAME:-git-restore-filemode}"
release_version="${GIT_RESTORE_FILEMODE_VERSION:-latest}"
install_dir_override="${GIT_RESTORE_FILEMODE_INSTALL_DIR:-}"
install_scope="auto"
repo_url="${GIT_RESTORE_FILEMODE_REPO_URL:-https://github.com/${repo_owner}/${repo_name}}"

usage() {
  cat <<'EOF'
usage: install.sh [--user|--system]

Install git-restore-filemode from a GitHub Release, falling back to Cargo when
no matching release asset exists.

Options:
  --system   Install to a preferred system executable directory already on PATH.
  --user     Install to a preferred per-user executable directory already on PATH.
  -h, --help Show this help.

By default, the installer tries system directories first and falls back to user
directories. Set GIT_RESTORE_FILEMODE_INSTALL_DIR to force a specific directory.
EOF
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --system)
        if [ "${install_scope}" != "auto" ]; then
          printf 'install.sh: --user and --system are mutually exclusive\n' >&2
          exit 2
        fi
        install_scope="system"
        ;;
      --user)
        if [ "${install_scope}" != "auto" ]; then
          printf 'install.sh: --user and --system are mutually exclusive\n' >&2
          exit 2
        fi
        install_scope="user"
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        printf 'install.sh: unknown option: %s\n' "$1" >&2
        usage >&2
        exit 2
        ;;
    esac
    shift
  done
}

platform_family() {
  case "$(uname -s)" in
    Darwin)
      printf '%s' "macos"
      ;;
    Linux)
      printf '%s' "linux"
      ;;
    MINGW* | MSYS* | CYGWIN*)
      printf '%s' "windows"
      ;;
    FreeBSD | OpenBSD | NetBSD | DragonFly)
      printf '%s' "bsd"
      ;;
    *)
      printf '%s' "unix"
      ;;
  esac
}

env_value() {
  printenv "$1" 2>/dev/null || true
}

to_shell_path() {
  local path="$1"

  if [ -z "${path}" ]; then
    return 0
  fi

  if command -v cygpath >/dev/null 2>&1; then
    cygpath -u "${path}" 2>/dev/null && return 0
  fi

  printf '%s\n' "${path}"
}

normalize_dir() {
  local dir="$1"

  case "${dir}" in
    \~)
      dir="${HOME}"
      ;;
    \~/*)
      dir="${HOME}/${dir#"~/"}"
      ;;
  esac

  while [ "${dir}" != "/" ] && [ "${dir%/}" != "${dir}" ]; do
    dir="${dir%/}"
  done

  printf '%s' "${dir}"
}

path_entries() {
  local old_ifs="${IFS}"
  local entry
  IFS=":"
  for entry in ${PATH:-}; do
    if [ -n "${entry}" ]; then
      printf '%s\n' "${entry}"
    fi
  done
  IFS="${old_ifs}"
}

system_candidate_dirs() {
  local program_files program_files_x86

  case "$(platform_family)" in
    macos)
      printf '%s\n' \
        "/usr/local/bin" \
        "/opt/homebrew/bin"
      ;;
    windows)
      program_files="$(to_shell_path "$(env_value ProgramFiles)")"
      program_files_x86="$(to_shell_path "$(env_value 'ProgramFiles(x86)')")"

      if [ -n "${program_files}" ]; then
        printf '%s\n' "${program_files}/${binary_name}"
      fi
      if [ -n "${program_files_x86}" ]; then
        printf '%s\n' "${program_files_x86}/${binary_name}"
      fi
      ;;
    *)
      printf '%s\n' \
        "/usr/local/bin" \
        "/opt/${binary_name}/bin"
      ;;
  esac
}

user_candidate_dirs() {
  local local_appdata userprofile

  case "$(platform_family)" in
    windows)
      local_appdata="$(to_shell_path "$(env_value LOCALAPPDATA)")"
      userprofile="$(to_shell_path "$(env_value USERPROFILE)")"

      if [ -n "${local_appdata}" ]; then
        printf '%s\n' \
          "${local_appdata}/Programs/${binary_name}" \
          "${local_appdata}/Programs" \
          "${local_appdata}/Microsoft/WindowsApps"
      fi
      if [ -n "${userprofile}" ]; then
        printf '%s\n' \
          "${userprofile}/AppData/Local/Programs/${binary_name}" \
          "${userprofile}/AppData/Local/Programs"
      fi
      ;;
    *)
      printf '%s\n' \
        "${HOME}/.local/bin" \
        "${HOME}/bin"
      ;;
  esac
}

candidate_dirs() {
  case "$1" in
    system)
      system_candidate_dirs
      ;;
    user)
      user_candidate_dirs
      ;;
    *)
      printf 'install.sh: internal error: unknown install scope: %s\n' "$1" >&2
      return 2
      ;;
  esac
}

candidate_dirs_on_path() {
  local scope="$1"
  local seen=""
  local candidate candidate_norm

  while IFS= read -r candidate; do
    candidate_norm="$(normalize_dir "${candidate}")"
    if [ -z "${candidate_norm}" ]; then
      continue
    fi

    if path_contains_dir "${candidate_norm}"; then
      case "${seen}" in
        *"|${candidate_norm}|"*) ;;
        *)
          seen="${seen}|${candidate_norm}|"
          printf '%s\n' "${candidate_norm}"
          ;;
      esac
    fi
  done < <(candidate_dirs "${scope}")
}

path_contains_dir() {
  local needle
  local path_entry
  needle="$(normalize_dir "$1")"

  while IFS= read -r path_entry; do
    if [ "$(normalize_dir "$(to_shell_path "${path_entry}")")" = "${needle}" ]; then
      return 0
    fi
  done < <(path_entries)

  return 1
}

detect_target() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"

  case "${os}:${arch}" in
    Linux:x86_64 | Linux:amd64)
      printf '%s' "x86_64-unknown-linux"
      ;;
    Linux:aarch64 | Linux:arm64)
      printf '%s' "aarch64-unknown-linux"
      ;;
    Darwin:x86_64 | Darwin:amd64)
      printf '%s' "x86_64-apple-darwin"
      ;;
    Darwin:arm64 | Darwin:aarch64)
      printf '%s' "aarch64-apple-darwin"
      ;;
    MINGW*:x86_64 | MSYS*:x86_64 | CYGWIN*:x86_64)
      printf '%s' "x86_64-pc-windows-msvc"
      ;;
    MINGW*:aarch64 | MSYS*:aarch64 | CYGWIN*:aarch64 | MINGW*:arm64 | MSYS*:arm64 | CYGWIN*:arm64)
      printf '%s' "aarch64-pc-windows-msvc"
      ;;
    *)
      printf 'unsupported platform: %s %s\n' "${os}" "${arch}" >&2
      return 1
      ;;
  esac
}

rust_target_for_platform() {
  case "$1" in
    x86_64-unknown-linux)
      printf '%s' "x86_64-unknown-linux-musl"
      ;;
    aarch64-unknown-linux)
      printf '%s' "aarch64-unknown-linux-musl"
      ;;
    *)
      printf '%s' "$1"
      ;;
  esac
}

download() {
  local url="$1"
  local output="$2"

  if command -v curl >/dev/null 2>&1; then
    if [ -n "${GITHUB_TOKEN:-}" ]; then
      curl -fsSL -H "Authorization: Bearer ${GITHUB_TOKEN}" "${url}" -o "${output}"
    else
      curl -fsSL "${url}" -o "${output}"
    fi
  elif command -v wget >/dev/null 2>&1; then
    if [ -n "${GITHUB_TOKEN:-}" ]; then
      wget -q --header="Authorization: Bearer ${GITHUB_TOKEN}" "${url}" -O "${output}"
    else
      wget -q "${url}" -O "${output}"
    fi
  else
    return 1
  fi
}

release_asset_url() {
  local target="$1"
  local asset="${binary_name}-${target}.tar.gz"

  if [ "${release_version}" = "latest" ]; then
    printf '%s/releases/latest/download/%s' "${repo_url}" "${asset}"
  else
    printf '%s/releases/download/%s/%s' "${repo_url}" "${release_version}" "${asset}"
  fi
}

binary_ext_for_target() {
  case "$1" in
    *windows* | *-pc-*)
      printf '%s' ".exe"
      ;;
    *)
      printf '%s' ""
      ;;
  esac
}

install_binary() {
  local source="$1"
  local target="$2"
  local install_dir="$3"
  local ext
  ext="$(binary_ext_for_target "${target}")"

  mkdir -p "${install_dir}" || return 1
  cp "${source}" "${install_dir}/${binary_name}${ext}" || return 1
  chmod 0755 "${install_dir}/${binary_name}${ext}" || return 1
  printf 'Installed %s to %s\n' "${binary_name}" "${install_dir}/${binary_name}${ext}"
}

install_from_release() {
  local target="$1"
  local install_dir="$2"
  local tmp_dir archive url candidate
  tmp_dir="$(mktemp -d)"
  archive="${tmp_dir}/${binary_name}-${target}.tar.gz"
  url="$(release_asset_url "${target}")"

  if ! download "${url}" "${archive}"; then
    rm -rf "${tmp_dir}"
    return 1
  fi

  tar -xzf "${archive}" -C "${tmp_dir}" || {
    rm -rf "${tmp_dir}"
    return 1
  }
  candidate="$(find "${tmp_dir}" -type f \( -name "${binary_name}" -o -name "${binary_name}.exe" \) | head -n 1)"
  if [ -z "${candidate}" ]; then
    rm -rf "${tmp_dir}"
    return 1
  fi

  install_binary "${candidate}" "${target}" "${install_dir}" || {
    rm -rf "${tmp_dir}"
    return 1
  }
  rm -rf "${tmp_dir}"
}

install_from_cargo() {
  local target="$1"
  local install_dir="$2"
  local tmp_dir cargo_root ext candidate rust_target

  if ! command -v rustc >/dev/null 2>&1 || ! command -v cargo >/dev/null 2>&1; then
    printf 'No release asset was available, and Rust/Cargo was not found for source install.\n' >&2
    printf 'Install Rust from https://rustup.rs/ or set GIT_RESTORE_FILEMODE_VERSION to an existing release tag.\n' >&2
    return 1
  fi

  tmp_dir="$(mktemp -d)"
  cargo_root="${tmp_dir}/cargo-root"
  ext="$(binary_ext_for_target "${target}")"
  rust_target="$(rust_target_for_platform "${target}")"

  if command -v rustup >/dev/null 2>&1; then
    rustup target add "${rust_target}"
  fi

  if [ "${release_version}" = "latest" ]; then
    cargo install --locked --git "${repo_url}" --target "${rust_target}" --bin "${binary_name}" --root "${cargo_root}"
  else
    cargo install --locked --git "${repo_url}" --tag "${release_version}" --target "${rust_target}" --bin "${binary_name}" --root "${cargo_root}"
  fi

  candidate="${cargo_root}/bin/${binary_name}${ext}"
  if [ ! -f "${candidate}" ]; then
    candidate="${cargo_root}/bin/${rust_target}/${binary_name}${ext}"
  fi
  install_binary "${candidate}" "${target}" "${install_dir}" || {
    rm -rf "${tmp_dir}"
    return 1
  }
  rm -rf "${tmp_dir}"
}

prepare_install_dir() {
  local install_dir="$1"

  if ! mkdir -p "${install_dir}" 2>/dev/null; then
    return 1
  fi

  [ -w "${install_dir}" ]
}

install_to_dir() {
  local target="$1"
  local install_dir="$2"

  if ! prepare_install_dir "${install_dir}"; then
    printf 'Cannot install to %s; directory is not writable.\n' "${install_dir}" >&2
    return 1
  fi

  if install_from_release "${target}" "${install_dir}"; then
    return 0
  fi

  printf 'Release asset unavailable for %s; falling back to Cargo.\n' "${target}" >&2
  install_from_cargo "${target}" "${install_dir}"
}

install_for_scope() {
  local scope="$1"
  local target="$2"
  local install_dir found
  found="false"

  while IFS= read -r install_dir; do
    found="true"
    printf 'Trying %s install directory: %s\n' "${scope}" "${install_dir}" >&2
    if install_to_dir "${target}" "${install_dir}"; then
      return 0
    fi
  done < <(candidate_dirs_on_path "${scope}")

  if [ "${found}" = "false" ]; then
    printf 'No preferred %s install directory was found in PATH.\n' "${scope}" >&2
  fi

  return 1
}

install_to_override_dir() {
  local target="$1"
  local install_dir
  install_dir="$(normalize_dir "$(to_shell_path "${install_dir_override}")")"

  if install_to_dir "${target}" "${install_dir}"; then
    if ! path_contains_dir "${install_dir}"; then
      printf 'Note: %s is not currently on PATH.\n' "${install_dir}" >&2
    fi
    return 0
  fi

  return 1
}

main() {
  local target
  parse_args "$@"
  target="${GIT_RESTORE_FILEMODE_TARGET:-$(detect_target)}"

  if [ -n "${install_dir_override}" ]; then
    install_to_override_dir "${target}"
    return
  fi

  case "${install_scope}" in
    system)
      install_for_scope "system" "${target}"
      ;;
    user)
      install_for_scope "user" "${target}"
      ;;
    auto)
      if install_for_scope "system" "${target}"; then
        return 0
      fi
      printf 'System install unavailable; trying user install directories.\n' >&2
      install_for_scope "user" "${target}"
      ;;
    *)
      printf 'install.sh: internal error: unknown install scope: %s\n' "${install_scope}" >&2
      return 2
      ;;
  esac
}

main "$@"
