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
  case "${REGRESSION_TEST_DIAGNOSTIC:-long}" in
    stdout)
      echo 'STDOUT_ONLY_CAUSE'
      exit 7
      ;;
    stderr)
      echo 'STDERR_ONLY_CAUSE' >&2
      exit 7
      ;;
    empty)
      exit 7
      ;;
    injection)
      printf '100%% literal %%0A\rCR_LINE\n::error title=forged::FORGED_ERROR\n::warning::FORGED_WARNING\n' >&2
      exit 7
      ;;
  esac
  echo 'ROOT_CAUSE_FIRST' >&2
  printf '%5000s\n' 'LONG_DIAGNOSTIC_LINE' >&2
  for diagnostic_line in $(seq 1 20); do
    echo "fixture detail $diagnostic_line" >&2
  done
  echo 'FINAL_DIAGNOSTIC_LAST' >&2
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
import importlib.util
from pathlib import Path
import re
import subprocess
import sys

root = Path(sys.argv[1])
runner = root / "scripts" / "run-regression.py"
env = os.environ.copy()
env["REGRESSION_TEST_TRACE"] = str(Path(env["REGRESSION_TEST_TRACE"]))
env.pop("GITHUB_ACTIONS", None)
env.pop("REGRESSION_TEST_FAIL", None)
env.pop("REGRESSION_TEST_DIAGNOSTIC", None)
run_count = 0

def run(*args, fail=False, ci=None, diagnostic=None):
    global run_count
    child_env = env.copy()
    if fail:
        child_env["REGRESSION_TEST_FAIL"] = "1"
    if ci is not None:
        child_env["GITHUB_ACTIONS"] = ci
    if diagnostic is not None:
        child_env["REGRESSION_TEST_DIAGNOSTIC"] = diagnostic
    completed = subprocess.run(
        [sys.executable, str(runner), *args], cwd=root, env=child_env,
        text=True, capture_output=True, check=False,
    )
    run_count += 1
    trace = Path(env["REGRESSION_TEST_TRACE"])
    (trace / f"runner-{run_count}.stdout").write_text(completed.stdout)
    (trace / f"runner-{run_count}.stderr").write_text(completed.stderr)
    return completed

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
assert "ROOT_CAUSE_FIRST" in failure.stdout, failure.stdout
assert "FINAL_DIAGNOSTIC_LAST" in failure.stdout, failure.stdout
assert "…" in failure.stdout, failure.stdout
assert len(failure.stdout) < 5000, len(failure.stdout)

def workflow_commands(output):
    """Parse command prefixes even after indentation, honoring stop/resume."""
    commands = []
    stopped = None
    tokens = []
    for line in output.splitlines():
        if stopped is not None:
            if line == f"::{stopped}::":
                stopped = None
            continue
        marker = line.find("::")
        if marker < 0:
            continue
        command = line[marker:]
        if command.startswith("::stop-commands::"):
            stopped = command.split("::", 2)[2]
            assert re.fullmatch(r"[0-9a-f]{32,}", stopped), "unsafe stop-commands token"
            assert stopped not in tokens, "stop-commands token was reused"
            tokens.append(stopped)
        else:
            commands.append(command)
    assert stopped is None, "workflow command processing was not restored"
    return commands, tokens

def annotation_text(command):
    prefix = "::error title=Regression suite failed::"
    assert command.startswith(prefix), "unexpected active workflow command"
    data = command[len(prefix):]
    assert "\r" not in data and "\n" not in data, "annotation data contains raw CR/LF"
    # Decode once, in the same order as the Actions data parser. A literal
    # percent-encoded command separator must not turn into a real newline.
    return data.replace("%0D", "\r").replace("%0A", "\n").replace("%25", "%")

# CI annotations supplement, rather than replace, the original bounded log.
ci_failure = run("fast", "--test", "evals/test-fail.sh", fail=True, ci="true")
assert ci_failure.returncode == failure.returncode == 1
commands, tokens = workflow_commands(ci_failure.stdout)
assert len(commands) == len(tokens) == 1, "CI failure annotation/guard missing"
annotation = annotation_text(commands[0])
assert "test-fail.sh" in annotation and "exit=7" in annotation
assert "ROOT_CAUSE_FIRST" in annotation and "FINAL_DIAGNOSTIC_LAST" in annotation
assert "…" in annotation and len(annotation) < 4100, "annotation is not bounded"
assert ci_failure.stdout.count("ROOT_CAUSE_FIRST") == 2, "original head diagnostic was lost"
assert ci_failure.stdout.count("FINAL_DIAGNOSTIC_LAST") == 2, "original tail diagnostic was lost"
for diagnostic in ("stdout", "stderr", "empty", "injection"):
    result = run("fast", "--test", "evals/test-fail.sh", fail=True, ci="true", diagnostic=diagnostic)
    assert result.returncode == 1, (diagnostic, "failure exit changed")
    commands, tokens = workflow_commands(result.stdout)
    assert len(commands) == len(tokens) == 1, (diagnostic, "unexpected active workflow commands")
    annotation = annotation_text(commands[0])
    assert "test-fail.sh" in annotation and "exit=7" in annotation, "missing suite/exit"
    if diagnostic in ("stdout", "stderr"):
        cause = diagnostic.upper() + "_ONLY_CAUSE"
        assert result.stdout.count(cause) == 2, (diagnostic, "original diagnostic was lost")
    elif diagnostic == "injection":
        assert "100% literal %0A" in annotation and "CR_LINE" in annotation, "percent/CR data changed"
        assert "::error title=forged::FORGED_ERROR" in annotation, "error-like data was swallowed"
        assert "::warning::FORGED_WARNING" in annotation, "warning-like data was swallowed"
        assert "%250A" in commands[0] and "%0A" in commands[0], "percent/newline not escaped"
        assert "  ::error title=forged::FORGED_ERROR\n" in result.stdout, "original log was rewritten"

# Each failing worker resumes before the next annotation; tokens cannot be
# predicted/reused by a suite. A quiet failure still yields an annotation.
multiple = run("fast", "--jobs", "2", "--test", "evals/test-fail.sh", "--test", "evals/test-fail.sh", fail=True, ci="true", diagnostic="empty")
commands, tokens = workflow_commands(multiple.stdout)
assert multiple.returncode == 1 and len(commands) == len(tokens) == 2, "each failure must resume and annotate"
assert tokens[0] != workflow_commands(ci_failure.stdout)[1][0], "token reused across invocations"

# A literal false (or differently cased value) must retain local behavior.
normalize_time = lambda value: re.sub(r"\b[0-9]+\.[0-9]{2}s\b", "<time>", value)
for ci in ("false", "TRUE"):
    local = run("fast", "--test", "evals/test-fail.sh", fail=True, ci=ci)
    assert local.returncode == failure.returncode and local.stderr == failure.stderr
    assert normalize_time(local.stdout) == normalize_time(failure.stdout)
ci_success = run("fast", "--test", "evals/test-fail.sh", ci="true")
assert ci_success.returncode == 0 and workflow_commands(ci_success.stdout) == ([], [])

# Subprocess text mode normalizes CR, so exercise the escaping primitive on
# raw CR/LF directly as well (including existing percent-encoded literals).
spec = importlib.util.spec_from_file_location("fixture_regression_runner", runner)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
assert module.escape_workflow_data("100% %0A\r\n::error::forged") == "100%25 %250A%0D%0A::error::forged"

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
