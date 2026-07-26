#!/usr/bin/env bash
set -euo pipefail

binary_name="git-restore-filemode"
repo_owner="${GIT_RESTORE_FILEMODE_REPO_OWNER:-yonathan-ashebir}"
repo_name="${GIT_RESTORE_FILEMODE_REPO_NAME:-git-restore-filemode}"
release_version="${GIT_RESTORE_FILEMODE_VERSION:-latest}"
install_dir="${GIT_RESTORE_FILEMODE_INSTALL_DIR:-${HOME}/.local/bin}"
repo_url="https://github.com/${repo_owner}/${repo_name}"

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
  local ext
  ext="$(binary_ext_for_target "${target}")"

  mkdir -p "${install_dir}"
  cp "${source}" "${install_dir}/${binary_name}${ext}"
  chmod 0755 "${install_dir}/${binary_name}${ext}"
  printf 'Installed %s to %s\n' "${binary_name}" "${install_dir}/${binary_name}${ext}"
}

install_from_release() {
  local target="$1"
  local tmp_dir archive url candidate
  tmp_dir="$(mktemp -d)"
  archive="${tmp_dir}/${binary_name}-${target}.tar.gz"
  url="$(release_asset_url "${target}")"

  if ! download "${url}" "${archive}"; then
    rm -rf "${tmp_dir}"
    return 1
  fi

  tar -xzf "${archive}" -C "${tmp_dir}"
  candidate="$(find "${tmp_dir}" -type f \( -name "${binary_name}" -o -name "${binary_name}.exe" \) | head -n 1)"
  if [ -z "${candidate}" ]; then
    rm -rf "${tmp_dir}"
    return 1
  fi

  install_binary "${candidate}" "${target}"
  rm -rf "${tmp_dir}"
}

install_from_cargo() {
  local target="$1"
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
  install_binary "${candidate}" "${target}"
  rm -rf "${tmp_dir}"
}

main() {
  local target
  target="${GIT_RESTORE_FILEMODE_TARGET:-$(detect_target)}"

  if ! install_from_release "${target}"; then
    printf 'Release asset unavailable for %s; falling back to Cargo.\n' "${target}" >&2
    install_from_cargo "${target}"
  fi

  case ":${PATH}:" in
    *":${install_dir}:"*) ;;
    *)
      printf 'Note: %s is not currently on PATH.\n' "${install_dir}" >&2
      ;;
  esac
}

main "$@"
