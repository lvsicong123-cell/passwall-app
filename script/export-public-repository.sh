#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_DIR="${1:-$ROOT_DIR/dist/passwall-public}"

if [[ -e "$TARGET_DIR" ]]; then
  echo "error: target already exists: $TARGET_DIR" >&2
  exit 1
fi

mkdir -p "$TARGET_DIR"

ROOT_FILES=(
  CHANGELOG.md CODE_OF_CONDUCT.md CONTRIBUTING.md
  LICENSE NOTICE PRIVACY.md README.md README.zh-CN.md SECURITY.md VERSION
  Package.swift
)

PUBLIC_FILES=(
  .github/ISSUE_TEMPLATE/bug_report.yml
  .github/ISSUE_TEMPLATE/config.yml
  .github/ISSUE_TEMPLATE/feature_request.yml
  .github/PULL_REQUEST_TEMPLATE.md
  .github/workflows/ci.yml
  docs/PUBLIC_AUDIT.md
  docs/RELEASE_NOTES.md
  Windows/installer.nsi
  Windows/installer-lifecycle.ps1
  Windows/test-installer.ps1
  script/package-macos-installer.sh
  script/macos-components.plist
)

for path in "${ROOT_FILES[@]}" "${PUBLIC_FILES[@]}"; do
  mkdir -p "$TARGET_DIR/$(dirname "$path")"
  cp "$ROOT_DIR/$path" "$TARGET_DIR/$path"
done

printf '%s\n' \
  '.build/' '.DS_Store' 'dist/' 'Windows/**/bin/' 'Windows/**/obj/' '*.user' \
  > "$TARGET_DIR/.gitignore"

while IFS= read -r -d '' path; do
  case "$path" in
    docs/superpowers/*) continue ;;
  esac
  mkdir -p "$TARGET_DIR/$(dirname "$path")"
  cp "$ROOT_DIR/$path" "$TARGET_DIR/$path"
done < <(git -C "$ROOT_DIR" ls-files -z -- Assets Sources Tests Windows docs)

mkdir -p "$TARGET_DIR/script"
cp "$ROOT_DIR/script/build_and_run.sh" "$TARGET_DIR/script/"
cp "$ROOT_DIR/script/export-public-repository.sh" "$TARGET_DIR/script/"

git -C "$TARGET_DIR" init -q --initial-branch=main
git -C "$TARGET_DIR" add .

scan_pattern() {
  local label="$1"
  local pattern="$2"
  shift 2

  set +e
  git -C "$TARGET_DIR" grep -q -I -E "$pattern" -- "$@" >/dev/null 2>&1
  local status=$?
  set -e

  case "$status" in
    0) echo "error: $label found in public snapshot" >&2; exit 1 ;;
    1) ;;
    *) echo "error: $label scan failed" >&2; exit 1 ;;
  esac
}

SECRET_PATTERN='BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_|AIza[0-9A-Za-z_-]{35}|sk-[A-Za-z0-9_-]{20,}|xox[baprs]-'
scan_pattern "possible secret" "$SECRET_PATTERN" \
  . ':(exclude)script/export-public-repository.sh'

if [[ -n "${PASSWALL_PRIVATE_PATTERN:-}" ]]; then
  scan_pattern "private identity or path" "$PASSWALL_PRIVATE_PATTERN" .
fi

echo "Public repository prepared and staged at: $TARGET_DIR"
echo "No commit, remote, tag, or release was created."
