#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-tenant-lifecycle.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
fake_bin="$fixture_root/bin"
lock_dir="$fixture_root/lock"
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

make_repo() {
  local repo="$1" safe="$2"
  mkdir -p "$repo/src/main/java/com/bit/auth/mapper" "$repo/src/main/java/com/bit/auth/service/impl"
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name test
  printf 'package com.bit.auth.mapper;\npublic interface SysTenantMapper {}\n' >"$repo/src/main/java/com/bit/auth/mapper/SysTenantMapper.java"
  printf 'package com.bit.auth.service.impl;\npublic class LoginServiceImpl {}\n' >"$repo/src/main/java/com/bit/auth/service/impl/LoginServiceImpl.java"
  git -C "$repo" add .
  git -C "$repo" commit -qm base
  if [[ "$safe" == true ]]; then
    cat >"$repo/src/main/java/com/bit/auth/mapper/SysTenantMapper.java" <<'EOF'
package com.bit.auth.mapper;
public interface SysTenantMapper {
    @Select("SELECT id FROM sys_tenant WHERE code = #{code} AND status = 1 AND is_deleted = 0 AND (expire_time IS NULL OR expire_time >= NOW()) LIMIT 1")
    Long selectEnabledIdByCode(String code);
}
EOF
    cat >"$repo/src/main/java/com/bit/auth/service/impl/LoginServiceImpl.java" <<'EOF'
package com.bit.auth.service.impl;
public class LoginServiceImpl {
    void login() {
        authenticationManager.authenticate(new UsernamePasswordAuthenticationToken("u", "p"));
    }
}
EOF
  else
    cat >"$repo/src/main/java/com/bit/auth/mapper/SysTenantMapper.java" <<'EOF'
package com.bit.auth.mapper;
public interface SysTenantMapper {
    @Select("SELECT id FROM sys_tenant WHERE code = #{code} AND is_deleted = 0 LIMIT 1")
    Long selectIdByCode(String code);
}
EOF
    cat >"$repo/src/main/java/com/bit/auth/service/impl/LoginServiceImpl.java" <<'EOF'
package com.bit.auth.service.impl;
public class LoginServiceImpl {
    void login(java.util.Map<String, Object> loginMap) {
        Long tenantId = parseTenantId(loginMap);
        if (tenantId != null) TenantContextHolder.setTenantId(tenantId);
        authenticationManager.authenticate(new UsernamePasswordAuthenticationToken("u", "p"));
    }
    private Long parseTenantId(java.util.Map<String, Object> loginMap) {
        return Long.parseLong(loginMap.get("tenantId").toString());
    }
}
EOF
  fi
  git -C "$repo" add .
  git -C "$repo" commit -qm target
}

context="$fixture_root/SysTenant.java"
cat >"$context" <<'EOF'
package com.bit.system.domain;
public class SysTenant {
    private Integer status;
    private java.time.LocalDateTime expireTime;
}
EOF

unsafe_repo="$fixture_root/unsafe"
safe_repo="$fixture_root/safe"
make_repo "$unsafe_repo" false
make_repo "$safe_repo" true

run_review() {
  local repo="$1" output="$2"
  PATH="$fake_bin:$PATH" \
    OLLAMA_REVIEW_LOCK_DIR="$lock_dir" \
    OLLAMA_REVIEW_EXAMPLES_FILE=/dev/null \
    OLLAMA_REVIEW_NUM_CTX=65536 \
    OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
    OLLAMA_REVIEW_PROBE_TIMEOUT_SECONDS=2 \
    "$repo_root/bin/local-review.sh" --repo "$repo" --base HEAD~1 --context "$context" >"$output"
}

run_review "$unsafe_repo" "$fixture_root/unsafe.out"
grep -F 'P1（条件） src/main/java/com/bit/auth/mapper/SysTenantMapper.java:' "$fixture_root/unsafe.out" >/dev/null
grep -F '停用或到期租户' "$fixture_root/unsafe.out" >/dev/null

run_review "$safe_repo" "$fixture_root/safe.out"
if grep -F 'P1（条件） src/main/java/com/bit/auth/mapper/SysTenantMapper.java:' "$fixture_root/safe.out" >/dev/null; then
  echo 'safe tenant lifecycle query incorrectly reported' >&2
  cat "$fixture_root/safe.out" >&2
  exit 1
fi

echo 'tenant lifecycle login preflight fixture: PASS'
