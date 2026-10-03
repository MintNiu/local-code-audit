#!/usr/bin/env bash
set -euo pipefail

# Use a copied runner and a tiny temporary repository. The real full run
# excludes this file, so the self-test cannot recursively invoke itself.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/local-review-regression-runner.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

fake_repo="$fixture_root/repo"
mkdir -p "$fake_repo/scripts" "$fake_repo/evals" "$fixture_root/trace"
cp "$repo_root/scripts/run-regression.py" "$fake_repo/scripts/run-regression.py"
chmod +x "$fake_repo/scripts/run-regression.py"

cat >"$fake_repo/evals/test-parallel-a.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
trace_dir="${REGRESSION_TEST_TRACE:?}"
[[ -d "${TMPDIR:?}" && -n "${OLLAMA_REVIEW_LOCK_DIR:?}" && ! -e "$OLLAMA_REVIEW_LOCK_DIR" ]]
printf '%s\n' "$OLLAMA_REVIEW_LOCK_DIR" >>"$trace_dir/locks"
mkdir "$OLLAMA_REVIEW_LOCK_DIR"
touch "$OLLAMA_REVIEW_LOCK_DIR/probe-a"
touch "$trace_dir/started-a"
for _ in $(seq 1 80); do
  [[ -e "$trace_dir/started-b" ]] && exit 0
  sleep 0.025
done
echo 'parallel worker did not overlap' >&2
exit 1
EOF
cat >"$fake_repo/evals/test-parallel-b.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
trace_dir="${REGRESSION_TEST_TRACE:?}"
[[ -d "${TMPDIR:?}" && -n "${OLLAMA_REVIEW_LOCK_DIR:?}" && ! -e "$OLLAMA_REVIEW_LOCK_DIR" ]]
printf '%s\n' "$OLLAMA_REVIEW_LOCK_DIR" >>"$trace_dir/locks"
mkdir "$OLLAMA_REVIEW_LOCK_DIR"
touch "$OLLAMA_REVIEW_LOCK_DIR/probe-b"
touch "$trace_dir/started-b"
for _ in $(seq 1 80); do
  [[ -e "$trace_dir/started-a" ]] && exit 0
  sleep 0.025
done
echo 'parallel worker did not overlap' >&2
exit 1
EOF
cat >"$fake_repo/evals/test-fail.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${REGRESSION_TEST_FAIL:-}" == 1 ]]; then
  exit 7
fi
EOF
cat >"$fake_repo/evals/test-regression-runner.sh" <<'EOF'
#!/usr/bin/env bash
echo 'self-test must be excluded by full mode' >&2
exit 9
EOF
chmod +x "$fake_repo"/evals/test-*.sh

REGRESSION_TEST_TRACE="$fixture_root/trace" python3 - "$fake_repo" <<'PY'
import os
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1])
runner = root / "scripts" / "run-regression.py"
env = os.environ.copy()
env["REGRESSION_TEST_TRACE"] = str(Path(env["REGRESSION_TEST_TRACE"]))

def run(*args, fail=False):
    child_env = env.copy()
    if fail:
        child_env["REGRESSION_TEST_FAIL"] = "1"
    return subprocess.run(
        [sys.executable, str(runner), *args], cwd=root, env=child_env,
        text=True, capture_output=True, check=False,
    )

# Each suite waits for the other's marker, proving jobs=2 really overlaps.
parallel = run("fast", "--jobs", "2", "--test", "evals/test-parallel-a.sh", "--test", "evals/test-parallel-b.sh")
assert parallel.returncode == 0, parallel.stderr + parallel.stdout
assert "suites=2 passed=2 failed=0" in parallel.stdout
locks = (Path(env["REGRESSION_TEST_TRACE"]) / "locks").read_text().splitlines()
assert len(locks) == 2 and len(set(locks)) == 2, locks

# A failing suite propagates its non-zero status and remains visible.
failure = run("fast", "--test", "evals/test-fail.sh", fail=True)
assert failure.returncode != 0, failure.stdout
assert "test-fail.sh" in failure.stdout and "exit=7" in failure.stdout

# full mode enumerates test-*.sh but excludes this self-test.
full = run("full", "--jobs", "2")
assert full.returncode == 0, full.stderr + full.stdout
assert "test-regression-runner.sh" not in full.stdout
assert "suites=3 passed=3 failed=0" in full.stdout

# Invalid options and out-of-whitelist paths fail before a suite starts.
invalid_cases = [
    ("fast", "--jobs", "0", "--test", "evals/test-parallel-a.sh"),
    ("fast", "--test", "evals/run-synthetic.sh"),
    ("fast", "--test", "evals/run-history.sh"),
    ("fast", "--test", "../run-synthetic.sh"),
    ("full", "--test", "evals/test-parallel-a.sh"),
]
for case in invalid_cases:
    result = run(*case)
    assert result.returncode == 2, (case, result.returncode, result.stdout, result.stderr)
PY

echo 'regression runner self-test passed'
