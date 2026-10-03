#!/usr/bin/env python3
"""Run shell regression suites in isolated workers without a model dependency."""

from __future__ import annotations

import argparse
import os
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path
import subprocess
import sys
import tempfile
import time


REPO_ROOT = Path(__file__).resolve().parent.parent
EVALS_DIR = REPO_ROOT / "evals"
SELF_TEST_NAME = "test-regression-runner.sh"


def positive_int(value: str) -> int:
    try:
        number = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("必须是正整数") from exc
    if number < 1:
        raise argparse.ArgumentTypeError("必须是正整数")
    return number


def resolve_suite(raw: str) -> Path:
    """Resolve one explicitly selected top-level eval suite safely."""

    supplied = Path(raw)
    candidate = supplied if supplied.is_absolute() else REPO_ROOT / supplied
    try:
        resolved = candidate.resolve(strict=True)
    except FileNotFoundError as exc:
        raise ValueError(f"测试套件不存在：{raw}") from exc
    except OSError as exc:
        raise ValueError(f"无法解析测试套件：{raw}") from exc

    evals_root = EVALS_DIR.resolve()
    if candidate.is_symlink():
        raise ValueError(f"测试套件不得是符号链接：{raw}")
    if resolved.parent != evals_root:
        raise ValueError(f"测试套件必须位于仓库 evals 顶层：{raw}")
    if not resolved.name.startswith("test-") or resolved.suffix != ".sh":
        raise ValueError(f"测试套件必须匹配 evals/test-*.sh：{raw}")
    if not resolved.is_file():
        raise ValueError(f"测试套件不是普通文件：{raw}")
    return resolved


def discover_full() -> list[Path]:
    """Find top-level suites and avoid recursively running this self-test."""

    return [
        path
        for path in sorted(EVALS_DIR.glob("test-*.sh"))
        if path.name != SELF_TEST_NAME and path.is_file() and not path.is_symlink()
    ]


@dataclass(frozen=True)
class SuiteResult:
    path: Path
    elapsed: float
    returncode: int
    stdout: str
    stderr: str


def run_suite(path: Path) -> SuiteResult:
    """Run a suite with private TMPDIR and OLLAMA_REVIEW_LOCK_DIR."""

    started = time.monotonic()
    try:
        with tempfile.TemporaryDirectory(prefix=f"local-review-regression-{path.stem}-") as temporary:
            temporary_path = Path(temporary)
            lock_dir = temporary_path / "ollama-review-lock"
            environment = os.environ.copy()
            environment["TMPDIR"] = str(temporary_path)
            environment["OLLAMA_REVIEW_LOCK_DIR"] = str(lock_dir)
            completed = subprocess.run(
                ["bash", str(path)],
                cwd=REPO_ROOT,
                env=environment,
                capture_output=True,
                text=True,
                errors="replace",
                check=False,
            )
            return SuiteResult(
                path, time.monotonic() - started, completed.returncode,
                completed.stdout, completed.stderr
            )
    except OSError as exc:
        return SuiteResult(path, time.monotonic() - started, 1, "", f"无法启动测试套件：{exc}")


def run_all(suites: list[Path], jobs: int) -> int:
    started = time.monotonic()
    results: dict[Path, SuiteResult] = {}
    with ThreadPoolExecutor(max_workers=min(jobs, len(suites))) as executor:
        futures = {executor.submit(run_suite, suite): suite for suite in suites}
        for future in as_completed(futures):
            result = future.result()
            results[result.path] = result

    failed = 0
    for suite in suites:
        result = results[suite]
        print(f"{suite.name}: {result.elapsed:.2f}s exit={result.returncode}")
        if result.returncode != 0:
            failed += 1
            diagnostic = (result.stderr or result.stdout).strip()
            if diagnostic:
                lines = diagnostic.splitlines()
                if len(lines) > 8:
                    lines = lines[-8:]
                rendered = "\n  ".join(lines)
                if len(rendered) > 4000:
                    rendered = rendered[-4000:]
                    rendered = "…" + rendered
                print("  " + rendered)
    elapsed = time.monotonic() - started
    print(f"total: {elapsed:.2f}s suites={len(suites)} passed={len(suites) - failed} failed={failed}")
    return 1 if failed else 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="并行运行本仓库的无模型 shell 回归套件。")
    modes = parser.add_subparsers(dest="mode", required=True)

    fast = modes.add_parser("fast", help="只运行显式指定的测试套件")
    fast.add_argument(
        "--test", dest="tests", action="append", required=True,
        metavar="evals/test-*.sh", help="仓库 evals 顶层的 test-*.sh，可重复传入"
    )
    fast.add_argument("--jobs", type=positive_int, default=2, help="并行数（默认 2）")

    full = modes.add_parser("full", help="运行 evals 顶层全部 test-*.sh")
    full.add_argument("--jobs", type=positive_int, default=2, help="并行数（默认 2）")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        suites = [resolve_suite(raw) for raw in args.tests] if args.mode == "fast" else discover_full()
    except ValueError as exc:
        parser.error(str(exc))
    if not suites:
        parser.error("没有可运行的测试套件")
    return run_all(suites, args.jobs)


if __name__ == "__main__":
    sys.exit(main())
