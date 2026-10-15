#!/usr/bin/env bash
set -euo pipefail

# Exercise startup without the developer's PATH or installed Ollama. Missing
# dependencies must be reported before repository access or model commands.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash_binary="$(command -v bash)"
python_binary="$(command -v python3)"
cat_binary="$(command -v cat)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-dependency-diagnostics.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
mkdir -p "$fixture_root/repo" "$fixture_root/help-bin"
printf '%s\n' 'untouched fixture' >"$fixture_root/repo/sentinel.txt"
ln -s "$cat_binary" "$fixture_root/help-bin/cat"

cat >"$fixture_root/forbidden-command" <<'EOF'
#!/bin/bash
printf '%s\n' "${0##*/}" >>"$DEPENDENCY_DIAGNOSTICS_COMMAND_LOG"
exit 97
EOF
chmod +x "$fixture_root/forbidden-command"

available_locales="$(locale -a)"
tested_locales=()
for candidate_locale in C C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
  if printf '%s\n' "$available_locales" | grep -Fx "$candidate_locale" >/dev/null; then
    tested_locales+=("$candidate_locale")
  fi
done
[[ ${#tested_locales[@]} -ge 2 ]] || {
  echo 'dependency diagnostics regression requires C and a supported UTF-8 locale' >&2
  exit 1
}

required_commands=(python3 git ollama jq curl awk tr sort rg perl stat)
assertion_count=0
for missing_command in rg jq python3; do
  fake_bin="$fixture_root/missing-$missing_command"
  mkdir -p "$fake_bin"
  for dependency in "${required_commands[@]}"; do
    [[ "$dependency" != "$missing_command" ]] || continue
    if [[ "$dependency" == python3 ]]; then
      ln -s "$python_binary" "$fake_bin/$dependency"
    else
      ln -s "$fixture_root/forbidden-command" "$fake_bin/$dependency"
    fi
  done
  for test_locale in "${tested_locales[@]}"; do
    stdout_file="$fixture_root/stdout"
    stderr_file="$fixture_root/stderr"
    command_log="$fixture_root/commands"
    : >"$command_log"
    status=0
    PATH="$fake_bin" LC_ALL="$test_locale" LANG="$test_locale" \
      DEPENDENCY_DIAGNOSTICS_COMMAND_LOG="$command_log" \
      "$bash_binary" "$repo_root/bin/local-review.sh" --repo "$fixture_root/repo" \
      >"$stdout_file" 2>"$stderr_file" || status=$?
    if [[ "$status" != 2 ]] || ! grep -F \
      "找不到必要命令: ${missing_command}，请先安装并确保它在 PATH 中。" "$stderr_file" >/dev/null; then
      echo "missing $missing_command under $test_locale: expected clear diagnostic and exit 2, got $status" >&2
      cat "$stderr_file" >&2
      exit 1
    fi
    if grep -F 'unbound variable' "$stderr_file" >/dev/null; then
      echo "missing $missing_command under $test_locale caused an unbound variable" >&2
      cat "$stderr_file" >&2
      exit 1
    fi
    [[ ! -s "$stdout_file" && ! -s "$command_log" ]] || {
      echo "missing $missing_command reached repository/model commands or emitted review output" >&2
      cat "$command_log" >&2
      cat "$stdout_file" >&2
      exit 1
    }
    assertion_count=$((assertion_count + 1))
  done
done

# Help is usable before review dependencies are installed. Only the standard
# system cat command used by usage() is available in this isolated PATH.
for test_locale in "${tested_locales[@]}"; do
  status=0
  PATH="$fixture_root/help-bin" LC_ALL="$test_locale" LANG="$test_locale" \
    "$bash_binary" "$repo_root/bin/local-review.sh" --help \
    >"$fixture_root/help-stdout" 2>"$fixture_root/help-stderr" || status=$?
  if [[ "$status" != 0 ]] || [[ -s "$fixture_root/help-stderr" ]] || \
    ! grep -F 'local-review --repo <dir>' "$fixture_root/help-stdout" >/dev/null; then
    echo "--help under $test_locale required a review dependency or failed (status $status)" >&2
    cat "$fixture_root/help-stderr" >&2
    exit 1
  fi
  assertion_count=$((assertion_count + 1))

  # The personal wrapper also needs Python to locate its real global target.
  status=0
  PATH="$fixture_root/help-bin" LC_ALL="$test_locale" LANG="$test_locale" \
    "$bash_binary" "$repo_root/bin/local-review-local.sh" --repo "$fixture_root/repo" \
    >"$fixture_root/wrapper-stdout" 2>"$fixture_root/wrapper-stderr" || status=$?
  if [[ "$status" != 2 ]] || [[ -s "$fixture_root/wrapper-stdout" ]] || \
    ! grep -F '找不到必要命令: python3，请先安装并确保它在 PATH 中。' "$fixture_root/wrapper-stderr" >/dev/null; then
    echo "personal wrapper under $test_locale did not report missing Python clearly (status $status)" >&2
    cat "$fixture_root/wrapper-stderr" >&2
    exit 1
  fi
  assertion_count=$((assertion_count + 1))
done

[[ "$(cat "$fixture_root/repo/sentinel.txt")" == 'untouched fixture' ]]
[[ "$(find "$fixture_root/repo" -mindepth 1 -print | wc -l | tr -d ' ')" == 1 ]]
printf 'dependency diagnostics regression passed (%s cases across %s locales)\n' \
  "$assertion_count" "${#tested_locales[@]}"
