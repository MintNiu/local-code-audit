#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-java-git-write.XXXXXX")"
fake_bin="$fixture_root/bin"
trap 'rm -rf "$fixture_root"' EXIT
mkdir -p "$fake_bin"

cat >"$fake_bin/ollama" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"response":"未发现阻塞问题","done":true,"done_reason":"stop"}\n'
EOF
chmod +x "$fake_bin/ollama" "$fake_bin/curl"

new_repo() {
  local repo="$1"
  mkdir -p "$repo/src/main/java/example" "$repo/src/main/webapp/WEB-INF"
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name java-git-write-preflight
  git -C "$repo" commit --allow-empty -qm 基线
}

run_review() {
  local repo="$1"
  PATH="$fake_bin:$PATH" TMPDIR="$fixture_root" \
    OLLAMA_REVIEW_LOCK_DIR="$fixture_root/lock" \
    LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
    OLLAMA_REVIEW_NUM_CTX=65536 \
    OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
    OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
    OLLAMA_REVIEW_TOTAL_TIMEOUT_SECONDS=120 \
    "$repo_root/bin/local-review.sh" --repo "$repo"
}

write_fixture() {
  local repo="$1"
  local auth_mapping="$2"
  cat >"$repo/src/main/java/example/GitServlet.java" <<'EOF'
package example;

class GitServlet extends UploadServlet {
    protected void doPost(Request req, Response resp) throws Exception {
        gitFacade.writeFile(branch, path, callback);
    }
}
EOF
  cat >"$repo/src/main/webapp/WEB-INF/web.xml" <<EOF
<web-app>
  <filter>
    <filter-name>AuthenticationFilter</filter-name>
    <filter-class>example.AuthenticationFilter</filter-class>
  </filter>
  <filter-mapping>
    <filter-name>AuthenticationFilter</filter-name>
    <url-pattern>/upload/*</url-pattern>
  </filter-mapping>
  $auth_mapping
  <servlet>
    <servlet-name>gitServlet</servlet-name>
    <servlet-class>example.GitServlet</servlet-class>
  </servlet>
  <servlet-mapping>
    <servlet-name>gitServlet</servlet-name>
    <url-pattern>/git/*</url-pattern>
  </servlet-mapping>
</web-app>
EOF
}

unsafe_repo="$fixture_root/unsafe"
new_repo "$unsafe_repo"
write_fixture "$unsafe_repo" ""
unsafe_output="$(run_review "$unsafe_repo")"
printf '%s\n' "$unsafe_output" | grep -F '新增 GitServlet 写入入口未纳入 AuthenticationFilter 覆盖范围' >/dev/null
printf '%s\n' "$unsafe_output" | grep -F 'GitServlet.java:5' >/dev/null
printf '%s\n' "$unsafe_output" | grep -F 'WEB-INF/web.xml:' >/dev/null
printf '%s\n' "$unsafe_output" | grep -F '影响：' >/dev/null
printf '%s\n' "$unsafe_output" | grep -F '修复建议：' >/dev/null
printf '%s\n' "$unsafe_output" | grep -F '验证方式：' >/dev/null
[[ "$(printf '%s\n' "$unsafe_output" | grep -c '新增 GitServlet 写入入口未纳入 AuthenticationFilter 覆盖范围' || true)" -eq 1 ]]

safe_repo="$fixture_root/safe"
new_repo "$safe_repo"
write_fixture "$safe_repo" '<filter-mapping><filter-name>AuthenticationFilter</filter-name><url-pattern>/git/*</url-pattern></filter-mapping>'
safe_output="$(run_review "$safe_repo")"
if printf '%s\n' "$safe_output" | grep -F '新增 GitServlet 写入入口未纳入 AuthenticationFilter 覆盖范围' >/dev/null; then
  echo 'authenticated GitServlet route was incorrectly reported' >&2
  printf '%s\n' "$safe_output" >&2
  exit 1
fi
printf '%s\n' "$safe_output" | grep -Fx '未发现阻塞问题' >/dev/null

guarded_repo="$fixture_root/global-filter"
new_repo "$guarded_repo"
write_fixture "$guarded_repo" '<filter-mapping><filter-name>GlobalFileUploadFilter</filter-name><url-pattern>/git/*</url-pattern></filter-mapping>'
guarded_output="$(run_review "$guarded_repo")"
if printf '%s\n' "$guarded_output" | grep -F '新增 GitServlet 写入入口未纳入 AuthenticationFilter 覆盖范围' >/dev/null; then
  echo 'global upload guard was incorrectly reported' >&2
  printf '%s\n' "$guarded_output" >&2
  exit 1
fi
printf '%s\n' "$guarded_output" | grep -Fx '未发现阻塞问题' >/dev/null

echo 'Java unprotected Git write preflight regression passed'
