#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-system-dict-auth.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
repo="$fixture_root/repo"
safe_repo="$fixture_root/safe-repo"
fake_bin="$fixture_root/bin"
mkdir -p "$repo/src/main/java/com/bit/system/controller" \
  "$repo/src/main/java/com/bit/system/service/impl" \
  "$repo/src/main/java/com/bit/system/domain" \
  "$repo/src/main/resources" "$fake_bin"

git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name system-dict-auth-preflight

cat >"$repo/src/main/java/com/bit/system/controller/DictController.java" <<'EOF'
@RequestMapping("/api/v1/dicts")
class DictController {
    private final DictService dictService = null;

    public Result<Void> create(@RequestBody DictSaveDTO dto) {
        dictService.createDict(dto);
        return Result.ok();
    }

    public Result<Void> update(@PathVariable Long id, @RequestBody DictSaveDTO dto) {
        dictService.updateDict(dto);
        return Result.ok();
    }

    public Result<Void> delete(@PathVariable Long id) {
        dictService.deleteDict(id);
        return Result.ok();
    }

    public Result<Void> createItem(@RequestBody DictItemSaveDTO dto) {
        dictService.createItem(dto);
        return Result.ok();
    }

    public Result<Void> updateItem(@PathVariable Long id, @RequestBody DictItemSaveDTO dto) {
        dictService.updateItem(dto);
        return Result.ok();
    }

    public Result<Void> deleteItem(@PathVariable Long id) {
        dictService.deleteItem(id);
        return Result.ok();
    }
}
EOF
cat >"$repo/src/main/java/com/bit/system/service/impl/DictServiceImpl.java" <<'EOF'
class DictServiceImpl {
    private final SysDictMapper sysDictMapper = null;
    private final SysDictItemMapper sysDictItemMapper = null;
    void write() {
        sysDictMapper.insert(null);
        sysDictMapper.updateById(null);
        sysDictMapper.deleteById(1L);
        sysDictItemMapper.insert(null);
        sysDictItemMapper.updateById(null);
        sysDictItemMapper.deleteById(1L);
    }
}
EOF
cat >"$repo/src/main/java/com/bit/system/domain/SysDict.java" <<'EOF'
@TableName("sys_dict")
class SysDict {}
EOF
cat >"$repo/src/main/java/com/bit/system/domain/SysDictItem.java" <<'EOF'
@TableName("sys_dict_item")
class SysDictItem {}
EOF
cat >"$repo/src/main/resources/application.yml" <<'EOF'
tenant:
  ignore-tables:
    - sys_dict
    - sys_dict_item
EOF
git -C "$repo" add .
git -C "$repo" commit -qm base

python3 - "$repo/src/main/java/com/bit/system/controller/DictController.java" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace(
    '    public Result<Void> create(',
    '    @PostMapping\n    public Result<Void> create(',
).replace(
    '    public Result<Void> update(',
    '    @PutMapping("/{id}")\n    public Result<Void> update(',
).replace(
    '    public Result<Void> delete(',
    '    @DeleteMapping("/{id}")\n    public Result<Void> delete(',
).replace(
    '    public Result<Void> createItem(',
    '    @PostMapping("/items")\n    public Result<Void> createItem(',
).replace(
    '    public Result<Void> updateItem(',
    '    @PutMapping("/items/{id}")\n    public Result<Void> updateItem(',
).replace(
    '    public Result<Void> deleteItem(',
    '    @DeleteMapping("/items/{id}")\n    public Result<Void> deleteItem(',
)
path.write_text(text)
PY

cat >"$fake_bin/ollama" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' '{"response":"未发现阻塞问题","done":true,"done_reason":"stop"}'
EOF
chmod +x "$fake_bin/ollama" "$fake_bin/curl"

run_review() {
  PATH="$fake_bin:$PATH" \
  LOCAL_REVIEW_EXAMPLES_FILE=/dev/null \
  OLLAMA_REVIEW_MODEL=devstral-small-2-review-tuned \
  OLLAMA_REVIEW_MAX_DIFF_BYTES=60000 \
  OLLAMA_REVIEW_NUM_CTX=65536 \
  OLLAMA_REVIEW_TOTAL_TIMEOUT_SECONDS=120 \
  "$repo_root/bin/local-review.sh" --repo "$1"
}

output="$(run_review "$repo")"
marker='全局字典写入口缺少显式权限校验'
[[ "$(printf '%s\n' "$output" | grep -cF "$marker" || true)" == 1 ]] || {
  echo 'system dict authorization preflight did not emit exactly one finding' >&2
  printf '%s\n' "$output" >&2
  exit 1
}
for field in '影响：' '修复建议：' '验证方式：' '证据行：'; do
  printf '%s\n' "$output" | grep -F "$field" >/dev/null || {
    echo "system dict authorization preflight omitted $field" >&2
    exit 1
  }
done

cp -R "$repo" "$safe_repo"
python3 - "$safe_repo/src/main/java/com/bit/system/controller/DictController.java" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()
text = re.sub(r'(?m)^    @PostMapping', "    @PreAuthorize(\"@perm.has('sys:dict:create')\")\n    @PostMapping", text)
text = re.sub(r'(?m)^    @PutMapping', "    @PreAuthorize(\"@perm.has('sys:dict:update')\")\n    @PutMapping", text)
text = re.sub(r'(?m)^    @DeleteMapping', "    @PreAuthorize(\"@perm.has('sys:dict:delete')\")\n    @DeleteMapping", text)
path.write_text(text)
PY
safe_output="$(run_review "$safe_repo")"
if printf '%s\n' "$safe_output" | grep -F "$marker" >/dev/null; then
  echo 'system dict authorization preflight reported the guarded safe fixture' >&2
  printf '%s\n' "$safe_output" >&2
  exit 1
fi

echo 'system dict global authorization preflight regression passed'
