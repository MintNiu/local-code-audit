#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-sql-menu-delivery.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
repo="$fixture_root/repo"
safe_repo="$fixture_root/safe-repo"
fake_bin="$fixture_root/bin"
lock_dir="$fixture_root/ollama.lock"
mkdir -p "$repo/sql" "$fake_bin"

git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name sql-menu-delivery-preflight

cat >"$repo/sql/platform_system.sql" <<'EOF'
INSERT INTO `sys_menu` (`id`,`application_id`,`parent_id`,`path`)
VALUES (22003, @ai_application_id, 22011, '0,22000,22011', '知识库问答');
EOF
cat >"$repo/sql/platform_ai_basic_rag_wiki_delivery.sql" <<'EOF'
-- standalone delivery cleanup for an already initialized database
START TRANSACTION;
UPDATE `sys_menu`
SET `is_deleted`=1, `visible`=0
WHERE `application_id`=@ai_application_id
  AND `id` IN (22011,22012,22013);
UPDATE `sys_tenant_menu` tm
INNER JOIN `sys_menu` m ON m.`id`=tm.`menu_id`
SET tm.`is_deleted`=1
WHERE m.`application_id`=@ai_application_id AND m.`is_deleted`=1;
UPDATE `sys_role_menu` rm
INNER JOIN `sys_menu` m ON m.`id`=rm.`menu_id`
SET rm.`is_deleted`=1
WHERE m.`application_id`=@ai_application_id AND m.`is_deleted`=1;
COMMIT;
EOF
git -C "$repo" add .
git -C "$repo" commit -qm base

# The target diff removes 22011 from the old cleanup list, but does not add a
# restoration statement for databases where the old script already ran.
sed -i '' 's/22011,22012,22013/22012,22013/' \
  "$repo/sql/platform_ai_basic_rag_wiki_delivery.sql"

cat >"$fake_bin/ollama" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"response":"未发现阻塞问题","done":true,"done_reason":"stop"}'
EOF
chmod +x "$fake_bin/ollama" "$fake_bin/curl"

run_review() {
  PATH="$fake_bin:$PATH" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
  OLLAMA_REVIEW_NUM_CTX=65536 \
  OLLAMA_REVIEW_LOCK_DIR="$lock_dir" \
  OLLAMA_REVIEW_TOTAL_TIMEOUT_SECONDS=120 \
    "$repo_root/bin/local-review.sh" --repo "$1"
}

marker='独立交付脚本只把基础聊天父菜单 22011 从历史软删除列表移除'
output="$(run_review "$repo")"
[[ "$(printf '%s\n' "$output" | grep -cF "$marker" || true)" == 1 ]] || {
  echo 'sql menu delivery preflight did not report the legacy-upgrade fixture' >&2
  printf '%s\n' "$output" >&2
  exit 1
}
for field in '影响：' '修复建议：' '验证方式：'; do
  printf '%s\n' "$output" | grep -F "$field" >/dev/null || {
    echo "sql menu delivery preflight omitted $field" >&2
    exit 1
  }
done

cp -R "$repo" "$safe_repo"
cat >>"$safe_repo/sql/platform_ai_basic_rag_wiki_delivery.sql" <<'EOF'
UPDATE `sys_menu`
SET `is_deleted`=0, `visible`=1
WHERE `application_id`=@ai_application_id AND `id`=22011;
INSERT INTO `sys_tenant_menu` (`tenant_id`,`menu_id`,`is_deleted`)
VALUES (1,22011,0) ON DUPLICATE KEY UPDATE `is_deleted`=0;
INSERT INTO `sys_role_menu` (`role_id`,`menu_id`,`tenant_id`,`is_deleted`)
VALUES (@ai_pilot_role_id,22011,1,0) ON DUPLICATE KEY UPDATE `is_deleted`=0;
EOF
safe_output="$(run_review "$safe_repo")"
if printf '%s\n' "$safe_output" | grep -F "$marker" >/dev/null; then
  echo 'sql menu delivery preflight reported the explicit restoration fixture' >&2
  printf '%s\n' "$safe_output" >&2
  exit 1
fi

echo 'sql menu delivery preflight regression passed'
