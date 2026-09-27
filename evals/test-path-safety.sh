#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-path-safety.XXXXXX")"
fake_bin="$fixture_root/bin"
repo="$fixture_root/repo"
outside_file="$fixture_root/outside.yml"
trap 'rm -rf "$fixture_root"' EXIT
mkdir -p "$fake_bin" "$repo/src/main/java/example"

git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name path-safety-test
cat >"$repo/src/main/java/example/Changed.java" <<'EOF'
package example;

final class Changed {
    int value() {
        return 1;
    }
}
EOF
git -C "$repo" add .
git -C "$repo" commit -qm base
printf '\n// changed\n' >>"$repo/src/main/java/example/Changed.java"

# If the filter follows a model-supplied ../ path, this contradictory source
# would turn the fabricated finding into a false clean result. It must never
# be read because it is not part of the diff evidence.
cat >"$outside_file" <<'EOF'
baseUrl: "http://localhost:8092"
EOF

cat >"$fake_bin/ollama" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "show" ]]; then
    exit 0
fi
exit 2
EOF
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"response":"P1 ../outside.yml:1 - baseUrl 缺少默认值和空值检查。\n影响：可能失败。\n修复建议：增加检查。\n验证方式：传入空值。","done":true,"done_reason":"stop"}'
EOF
chmod +x "$fake_bin/ollama" "$fake_bin/curl"

if PATH="$fake_bin:$PATH" \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  "$repo_root/bin/local-review.sh" --repo "$repo" \
  >"$fixture_root/stdout" 2>"$fixture_root/stderr"; then
  echo 'model-supplied path traversal was accepted as a review result' >&2
  cat "$fixture_root/stdout" >&2
  cat "$fixture_root/stderr" >&2
  exit 1
fi
grep -F '缺少可验证的严重级别或文件/行号' "$fixture_root/stderr" >/dev/null || {
  echo 'path traversal did not fail through the normal location gate' >&2
  cat "$fixture_root/stderr" >&2
  exit 1
}

# A changed symlink is a real diff path but must not make the contradiction
# guard read its target outside the repository. The finding should remain
# visible instead of being turned into clean by the target's default value.
mkdir -p "$repo/src/main/resources"
ln -s "$outside_file" "$repo/src/main/resources/Changed.yml"
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"response":"P1 src/main/resources/Changed.yml:1 - baseUrl 缺少默认值和空值检查。\n影响：可能失败。\n修复建议：增加检查。\n验证方式：传入空值。","done":true,"done_reason":"stop"}'
EOF
chmod +x "$fake_bin/curl"
if PATH="$fake_bin:$PATH" \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  "$repo_root/bin/local-review.sh" --repo "$repo" \
  >"$fixture_root/symlink-stdout" 2>"$fixture_root/symlink-stderr"; then
  :
else
  echo 'changed symlink review failed before returning the finding' >&2
  cat "$fixture_root/symlink-stdout" >&2
  cat "$fixture_root/symlink-stderr" >&2
  exit 1
fi
grep -F 'P1 src/main/resources/Changed.yml:1' "$fixture_root/symlink-stdout" >/dev/null || {
  echo 'changed symlink target was read and contradicted the finding' >&2
  cat "$fixture_root/symlink-stdout" >&2
  cat "$fixture_root/symlink-stderr" >&2
  exit 1
}

# Source snapshots used by deterministic Java preflights must not follow a
# changed Java symlink into an external file either. Capture the prompt and
# assert that the external marker never crosses the evidence boundary.
outside_java="$fixture_root/outside.java"
printf '%s\n' 'final class Outside { /* OUTSIDE_JAVA_MARKER_7f3a */ void leak() { externalRepo.findByIdForUpdate(42); } }' >"$outside_java"
ln -s "$outside_java" "$repo/src/main/java/example/SymlinkChanged.java"
java_capture="$fixture_root/java-symlink-request.json"
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
previous=""
for argument in "$@"; do
  if [[ "$previous" == "--data-binary" && "$argument" == @* ]]; then
    cp "${argument#@}" "${CAPTURE_REQUEST:?}"
  fi
  previous="$argument"
done
printf '%s\n' '{"response":"未发现阻塞问题","done":true,"done_reason":"stop"}'
EOF
chmod +x "$fake_bin/curl"
CAPTURE_REQUEST="$java_capture" PATH="$fake_bin:$PATH" \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  "$repo_root/bin/local-review.sh" --repo "$repo" >/dev/null
if grep -F 'OUTSIDE_JAVA_MARKER_7f3a' "$java_capture" >/dev/null; then
  echo 'changed Java symlink target leaked into deterministic preflight evidence' >&2
  exit 1
fi

# Repository-controlled AGENTS.md/README.md symlinks are untrusted prompt
# inputs and must not cause the model request to read external content.
outside_rules="$fixture_root/outside-rules.md"
printf '%s\n' 'OUTSIDE_RULES_MARKER_2c91' >"$outside_rules"
ln -s "$outside_rules" "$repo/AGENTS.md"
ln -s "$outside_rules" "$repo/README.md"
rules_capture="$fixture_root/rules-symlink-request.json"
CAPTURE_REQUEST="$rules_capture" PATH="$fake_bin:$PATH" \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  "$repo_root/bin/local-review.sh" --repo "$repo" --with-readme >/dev/null
if grep -F 'OUTSIDE_RULES_MARKER_2c91' "$rules_capture" >/dev/null; then
  echo 'AGENTS.md or README.md symlink target leaked into prompt evidence' >&2
  exit 1
fi

# Git permits newlines in pathnames; line-oriented path indexes must reject
# such a diff before any preflight can reinterpret the suffix as ../outside.
newline_repo="$fixture_root/newline-repo"
mkdir -p "$newline_repo/src/main/java/example"
git -C "$newline_repo" init -q
git -C "$newline_repo" config user.email test@example.invalid
git -C "$newline_repo" config user.name path-safety-test
printf '%s\n' 'package example; final class Base {}' >"$newline_repo/src/main/java/example/Base.java"
git -C "$newline_repo" add .
git -C "$newline_repo" commit -qm base
printf '%s\n' '// changed' >>"$newline_repo/src/main/java/example/Base.java"
newline_path="$newline_repo/src/main/java/example/zfoo"$'\n'"../outside.java"
mkdir -p "$(dirname "$newline_path")"
printf '%s\n' 'class WeirdPath {}' >"$newline_path"
if PATH="$fake_bin:$PATH" OLLAMA_REVIEW_MODEL=devstral-small-2-review \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  "$repo_root/bin/local-review.sh" --repo "$newline_repo" >"$fixture_root/newline-stdout" 2>"$fixture_root/newline-stderr"; then
  echo 'newline pathname was accepted into a line-oriented evidence index' >&2
  exit 1
fi
grep -F '变更路径包含换行' "$fixture_root/newline-stderr" >/dev/null || {
  echo 'newline pathname did not fail closed with a path-boundary diagnostic' >&2
  cat "$fixture_root/newline-stderr" >&2
  exit 1
}
echo 'path safety regression passed'
