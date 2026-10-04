#!/usr/bin/env python3
"""Rank pending review candidates without dropping any candidate.

This is a scheduling aid, not a detector. It uses the actual parent-to-commit
diff and commit subject to put boundary-sensitive changes first. Every input
row is copied to the output; a missing repository or invalid ref is a hard
failure rather than an implicit exclusion.
"""

from __future__ import annotations

import argparse
import csv
import re
import subprocess
import sys
from pathlib import Path


SHA_RE = re.compile(r"^[0-9A-Fa-f]{7,64}$")
REQUIRED_COLUMNS = ("repo", "commit", "parent", "feature_cluster", "candidate_reason", "status")

# Each group contributes at most once. This only schedules expensive model
# runs; it never decides whether a finding exists.
RISK_GROUPS: tuple[tuple[str, tuple[str, ...], int], ...] = (
    ("tenant-auth", ("tenant", "permission", "authorize", "authorization", "auth", "acl", "role", "scope", "gateway"), 4),
    ("secret-token", ("token", "secret", "credential", "password", "apikey", "api-key", "header"), 4),
    ("shared-boundary", ("internal", "public", "share", "cross-tenant", "isolation", "menu", "user"), 3),
    ("state-concurrency", ("concurr", "lock", "idempot", "transaction", "callback", "retry", "queue", "batch"), 3),
    ("data-side-effect", ("delete", "remove", "upload", "download", "write", "update", "sql", "mapper", "migration"), 2),
    ("external-runtime", ("http", "url", "oss", "file", "path", "process", "command", "xml", "mcp", "pdf", "config", "yaml", "properties"), 2),
)


def fail(message: str) -> "NoReturn":
    print(f"候选排序失败：{message}", file=sys.stderr)
    raise SystemExit(2)


def read_rows(path: Path) -> tuple[list[str], list[dict[str, str]]]:
    if not path.is_file():
        fail(f"文件不存在: {path}")
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        fail(f"无法读取 {path}: {exc}")
    if any(ord(char) < 32 and char not in "\t\n\r" for char in text):
        fail(f"包含不可安全写入 TSV 的控制字符: {path}")
    reader = csv.DictReader(text.splitlines(), delimiter="\t")
    if reader.fieldnames is None or tuple(reader.fieldnames[: len(REQUIRED_COLUMNS)]) != REQUIRED_COLUMNS:
        fail(f"表头前 {len(REQUIRED_COLUMNS)} 列必须是 {'、'.join(REQUIRED_COLUMNS)}: {path}")
    if len(set(reader.fieldnames)) != len(reader.fieldnames):
        fail(f"表头包含重复列: {path}")
    rows: list[dict[str, str]] = []
    for line_number, row in enumerate(reader, start=2):
        if None in row:
            fail(f"第 {line_number} 行列数不一致: {path}")
        normalized = {key: value or "" for key, value in row.items()}
        for column in REQUIRED_COLUMNS:
            if not normalized[column].strip():
                fail(f"第 {line_number} 行缺少 {column}: {path}")
        if not SHA_RE.fullmatch(normalized["commit"].strip()) or not SHA_RE.fullmatch(normalized["parent"].strip()):
            fail(f"第 {line_number} 行 commit/parent 不是 7-64 位十六进制: {path}")
        rows.append(normalized)
    return list(reader.fieldnames), rows


def git(repo: Path, *args: str) -> str:
    try:
        completed = subprocess.run(
            ["git", "-c", "core.fsmonitor=false", "-C", str(repo), *args],
            check=True,
            capture_output=True,
            text=True,
            errors="replace",
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        detail = getattr(exc, "stderr", "") or str(exc)
        fail(f"git 操作失败（{repo} {' '.join(args)}）: {detail.strip()}")
    return completed.stdout


def score_candidate(repo: Path, row: dict[str, str]) -> dict[str, str]:
    commit = row["commit"].strip()
    parent = row["parent"].strip()
    git(repo, "rev-parse", "--verify", f"{commit}^{{commit}}")
    git(repo, "rev-parse", "--verify", f"{parent}^{{commit}}")
    parents = git(repo, "show", "-s", "--format=%P", commit).split()
    if parent.lower() not in {value.lower() for value in parents}:
        fail(f"{row['repo']} {commit} 的 parent 不是直接父提交: {parent}")

    subject = git(repo, "show", "-s", "--format=%s", commit).strip()
    names = [line for line in git(repo, "diff", "--name-only", parent, commit, "--").splitlines() if line]
    numstat = git(repo, "diff", "--numstat", parent, commit, "--").splitlines()
    additions = deletions = 0
    for line in numstat:
        fields = line.split("\t", 2)
        if len(fields) != 3:
            continue
        if fields[0].isdigit():
            additions += int(fields[0])
        if fields[1].isdigit():
            deletions += int(fields[1])

    corpus = " ".join((row["feature_cluster"], row["candidate_reason"], subject, *names)).lower()
    signals: list[str] = []
    score = 0
    for label, words, weight in RISK_GROUPS:
        if any(word in corpus for word in words):
            signals.append(label)
            score += weight
    if any(name.endswith((".java", ".kt", ".go", ".ts", ".tsx", ".py")) for name in names):
        score += 2
    if any(name.endswith((".sql", ".yml", ".yaml", ".properties", ".xml")) for name in names):
        score += 1
    if len(names) >= 20 or additions + deletions >= 1000:
        signals.append("large-diff")
        score += 1

    band = "first" if score >= 10 else "next" if score >= 6 else "later"
    enriched = dict(row)
    enriched.update(
        priority_band=band,
        priority_score=str(score),
        changed_files=str(len(names)),
        changed_lines=str(additions + deletions),
        risk_signals=",".join(signals) or "none",
        commit_subject=subject,
    )
    return enriched


def main() -> int:
    parser = argparse.ArgumentParser(description="按真实 diff 对候选提交排序；不删除或过滤候选。")
    parser.add_argument("--candidates", required=True, type=Path, help="候选 TSV")
    parser.add_argument("--workspace-root", required=True, type=Path, help="包含各 repo 子目录的工作区根目录")
    parser.add_argument("--out", required=True, type=Path, help="输出 TSV，不覆盖已有文件")
    args = parser.parse_args()

    columns, rows = read_rows(args.candidates)
    root = args.workspace_root.resolve()
    ranked: list[dict[str, str]] = []
    for row in rows:
        repo = root / row["repo"]
        if not repo.is_dir() or repo.is_symlink():
            fail(f"repo 目录不存在或是符号链接: {repo}")
        ranked.append(score_candidate(repo, row))
    derived_columns = ["priority_band", "priority_score", "changed_files", "changed_lines", "risk_signals", "commit_subject"]
    output_columns = columns + [column for column in derived_columns if column not in columns]
    ranked.sort(key=lambda row: (-int(row["priority_score"]), row["repo"], row["commit"].lower()))
    if args.out.exists():
        fail(f"拒绝覆盖已有排序结果: {args.out}")
    try:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        with args.out.open("w", encoding="utf-8", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=output_columns, delimiter="\t", lineterminator="\n")
            writer.writeheader()
            writer.writerows(ranked)
    except OSError as exc:
        fail(f"无法写入排序结果: {exc}")
    print(f"candidate ranking: ranked={len(ranked)} output={args.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    main()
