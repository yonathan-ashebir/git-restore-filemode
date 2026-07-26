#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  printf 'usage: %s <rust-target> [asset-target]\n' "$0" >&2
  exit 2
fi

rust_target="$1"
asset_target="${2:-${rust_target}}"
binary_name="git-restore-filemode"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dist_dir="${repo_root}/dist"
stage_dir="${dist_dir}/${binary_name}-${asset_target}"
binary_ext=""

case "${asset_target}" in
  *windows* | *-pc-*)
    binary_ext=".exe"
    ;;
esac

rm -rf "${stage_dir}"
mkdir -p "${stage_dir}"

cp "${repo_root}/target/${rust_target}/release/${binary_name}${binary_ext}" "${stage_dir}/"
cp "${repo_root}/README.md" "${stage_dir}/"
cp "${repo_root}/LICENSE" "${stage_dir}/"

tar -czf "${dist_dir}/${binary_name}-${asset_target}.tar.gz" -C "${dist_dir}" "${binary_name}-${asset_target}"
printf '%s\n' "${dist_dir}/${binary_name}-${asset_target}.tar.gz"
