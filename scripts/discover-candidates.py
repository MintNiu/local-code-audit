#!/usr/bin/env python3
"""Discover direct-parent commits from local repositories for human triage.

This command is intentionally a collector, not a detector. It only records
single-parent commits from the requested time window. It does not infer
severity, merge related roots, or decide whether a model run is warranted.
"""

from __future__ import annotations

import argparse
import csv
import re
import subprocess
import sys
from datetime import date
from pathlib import Path


FULL_SHA_RE = re.compile(r"^[0-9a-fA-F]{40}$")
REF_RE = re.compile(r"^[0-9a-fA-F]{7,64}$")
REQUIRED_COLUMNS = ("repo", "commit", "parent", "feature_cluster", "candidate_reason", "status")


def fail(message: str) -> "NoReturn":
    print(f"候选发现失败：{message}", file=sys.stderr)
    raise SystemExit(2)


def run_git(repo: Path, *args: str) -> str:
    try:
        result = subprocess.run(
            ["git", "-c", "core.fsmonitor=false", "-c", "core.pager=cat", "-C", str(repo), *args],
            check=True,
            capture_output=True,
            text=True,
            errors="replace",
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        detail = getattr(exc, "stderr", "") or str(exc)
        fail(f"git 操作失败（{repo} {' '.join(args)}）：{detail.strip()}")
    return result.stdout


def read_excluded(paths: list[Path]) -> set[tuple[str, str]]:
    excluded: set[tuple[str, str]] = set()
    for path in paths:
        if not path.is_file():
            fail(f"排除表不存在: {path}")
        try:
            text = path.read_text(encoding="utf-8")
        except OSError as exc:
            fail(f"无法读取排除表 {path}: {exc}")
        reader = csv.DictReader(text.splitlines(), delimiter="\t")
        if not reader.fieldnames or "repo" not in reader.fieldnames or "commit" not in reader.fieldnames:
            fail(f"排除表必须包含 repo 和 commit 列: {path}")
        for line_number, row in enumerate(reader, start=2):
            repo = (row.get("repo") or "").strip().lower()
            commit = (row.get("commit") or "").strip().lower()
            if not repo or not REF_RE.fullmatch(commit):
                fail(f"排除表第 {line_number} 行缺少 repo 或 commit 不是完整 SHA: {path}")
            excluded.add((repo, commit))
    return excluded


def discover_repo(repo: Path, since: str, excluded: set[tuple[str, str]]) -> list[dict[str, str]]:
    if repo.is_symlink() or not repo.is_dir() or not (repo / ".git").exists():
        fail(f"仓库目录不存在、是符号链接或不是 Git 工作树: {repo}")
    name = repo.name
    raw = run_git(
        repo,
        "log",
        "--all",
        "--no-merges",
        f"--since={since}",
        "--date=short",
        "--format=%H%x09%P%x09%ad%x09%s",
    )
    rows: list[dict[str, str]] = []
    for line_number, line in enumerate(raw.splitlines(), start=1):
        fields = line.split("\t", 3)
        if len(fields) != 4:
            fail(f"{name} git log 第 {line_number} 行格式异常")
        commit, parents, committed_date, subject = fields
        if not FULL_SHA_RE.fullmatch(commit) or len(parents.split()) != 1 or not committed_date:
            # Root and merge commits are intentionally outside the direct-parent
            # history evaluation contract.
            continue
        if (name.lower(), commit.lower()) in excluded:
            continue
        if any(any(ord(char) < 32 for char in value) for value in (name, subject)):
            fail(f"{name} {commit} 含不可安全写入 TSV 的控制字符")
        rows.append(
            {
                "repo": name,
                "commit": commit,
                "parent": parents.strip(),
                "feature_cluster": f"unclassified-{commit[:12]}",
                "candidate_reason": f"待人工审计：{subject}",
                "status": "pending-human-label",
                "commit_date": committed_date,
                "commit_subject": subject,
            }
        )
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description="从多个本地 Git 仓库发现直接父提交候选；只读且不判断严重度。")
    parser.add_argument("--workspace-root", required=True, type=Path, help="包含多个 Git 仓库的目录")
    parser.add_argument("--since", required=True, help="Git 可接受的起始时间，例如 2026-09-01")
    parser.add_argument(
        "--exclude", type=Path, action="append", default=[],
        help="已有评分卡或评审表，至少包含 repo、commit 列；可重复传入多个文件",
    )
    parser.add_argument("--repo", action="append", help="只扫描指定仓库名；可重复传入")
    parser.add_argument("--out", required=True, type=Path, help="输出候选 TSV；拒绝覆盖已有文件")
    args = parser.parse_args()

    try:
        date.fromisoformat(args.since)
    except ValueError:
        fail(f"--since 必须是 YYYY-MM-DD: {args.since}")
    root = args.workspace_root.resolve()
    if not root.is_dir() or root.is_symlink():
        fail(f"workspace root 不存在或是符号链接: {root}")
    excluded = read_excluded(args.exclude)
    selected_names = set(args.repo or [])
    repositories = [
        child for child in sorted(root.iterdir())
        if (not selected_names or child.name in selected_names)
        and child.is_dir() and not child.is_symlink() and (child / ".git").exists()
    ]
    if selected_names:
        missing = sorted(selected_names - {repo.name for repo in repositories})
        if missing:
            fail(f"指定仓库不存在或不是 workspace 直接子目录: {', '.join(missing)}")
    if not repositories:
        fail("没有找到可扫描的 Git 仓库")

    rows = [row for repo in repositories for row in discover_repo(repo, args.since, excluded)]
    rows.sort(key=lambda row: (row["commit_date"], row["repo"], row["commit"]), reverse=True)
    columns = list(REQUIRED_COLUMNS) + ["commit_date", "commit_subject"]
    if args.out.exists():
        fail(f"拒绝覆盖已有输出: {args.out}")
    try:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        with args.out.open("w", encoding="utf-8", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=columns, delimiter="\t", lineterminator="\n")
            writer.writeheader()
            writer.writerows(rows)
    except OSError as exc:
        fail(f"无法写入输出: {exc}")
    print(f"candidate discovery: repos={len(repositories)} candidates={len(rows)} output={args.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
