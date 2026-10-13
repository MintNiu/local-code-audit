#!/usr/bin/env python3
"""Build bounded Java method context for a unified-diff shard.

This is an optional, evidence-only sidecar. It includes only methods that
contain added lines in the current shard, never follows symlinks, and omits a
whole method when the byte budget cannot hold it. The caller still sends the
diff and runs the normal prompt-budget guard.
"""

from __future__ import annotations

import re
import subprocess
import sys
from bisect import bisect_left
from pathlib import Path


HUNK_RE = re.compile(r"^@@ -\d+(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")
SIDECAR_PREFIX = (
    "--- 当前变更方法窗口（源码证据，非预检；仅包含新增行所在方法） ---\n"
    "以下是当前快照的有限源码上下文，不是本分片的新增差异；只能用来理解新增行的类型、调用边界和控制流。问题必须由当前差异或明确预检证据支持，不得仅凭未变更行创建 finding。\n"
)
SIDECAR_SUFFIX = "--- 变更方法窗口结束 ---"


def safe_repo_path(repo_root: Path, relative: str) -> Path | None:
    path = Path(relative)
    if path.is_absolute() or "\x00" in relative or "\n" in relative or "\r" in relative:
        return None
    if any(part in ("", ".", "..") for part in path.parts):
        return None
    current = repo_root
    for part in path.parts:
        current = current / part
        if current.is_symlink():
            return None
    if not current.is_file() or current.suffix != ".java":
        return None
    return current


def added_lines_by_path(diff_text: str) -> dict[str, list[int]]:
    result: dict[str, list[int]] = {}
    path: str | None = None
    new_line = 0
    in_hunk = False
    old_remaining = new_remaining = 0
    for line in diff_text.splitlines():
        # Reset state at every file boundary. A deleted file's `+++ /dev/null`
        # must not leave the preceding Java path active, and metadata between
        # files must never be interpreted as hunk content.
        if line.startswith("diff --git "):
            path = None
            new_line = 0
            in_hunk = False
            continue
        # File headers are only meaningful outside a hunk. This ordering is
        # important: a real added source line may itself begin with `+++`.
        if not in_hunk and line.startswith("+++ "):
            marker = line[4:].rstrip()
            if marker == "/dev/null":
                path = None
            elif marker.startswith("b/"):
                path = marker[2:]
                result.setdefault(path, [])
            else:
                path = None
            continue
        hunk = HUNK_RE.match(line)
        if hunk:
            old_remaining = int(hunk.group(1) or "1")
            new_line = int(hunk.group(2))
            new_remaining = int(hunk.group(3) or "1")
            in_hunk = path is not None and old_remaining + new_remaining > 0
            continue
        if not in_hunk or path is None or new_line <= 0 or line.startswith("\\ No newline"):
            continue
        if line.startswith("+") and new_remaining > 0:
            result[path].append(new_line)
            new_line += 1
            new_remaining -= 1
        elif line.startswith("-") and old_remaining > 0:
            old_remaining -= 1
        elif line.startswith(" ") and old_remaining > 0 and new_remaining > 0:
            new_line += 1
            old_remaining -= 1
            new_remaining -= 1
        else:
            # An unexpected line terminates this hunk; a following hunk must
            # establish its own line cursor before any additions count.
            in_hunk = False
        if old_remaining == 0 and new_remaining == 0:
            in_hunk = False
    return {path: sorted(set(lines)) for path, lines in result.items() if lines}


def merge_spans(spans: list[tuple[int, int]]) -> list[tuple[int, int]]:
    merged: list[list[int]] = []
    for start, end in sorted(spans):
        # Do not join adjacent methods: a method may end immediately before
        # the next declaration when the source has no blank separator.
        if merged and start <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([start, end])
    return [(start, end) for start, end in merged]


def method_spans(repo_root: Path, relative: str, lines: list[int]) -> list[tuple[int, int]]:
    source = safe_repo_path(repo_root, relative)
    if source is None:
        return []
    window_script = Path(__file__).with_name("java-method-window.py")
    try:
        output = subprocess.check_output(
            [sys.executable, str(window_script), str(source), "0", "--all-spans"],
            text=True,
            stderr=subprocess.DEVNULL,
            timeout=3,
        )
    except (OSError, subprocess.SubprocessError):
        return []
    spans: list[tuple[int, int]] = []
    lines = sorted(set(lines))
    for match in re.finditer(r"^(\d+)\t(\d+)$", output, re.MULTILINE):
        start, end = int(match.group(1)), int(match.group(2))
        first_added = bisect_left(lines, start)
        if first_added < len(lines) and lines[first_added] <= end:
            spans.append((start, end))
    return merge_spans(spans)


def build_sidecar(
    repo_root: Path,
    diff_text: str,
    max_bytes: int = 6000,
    max_method_bytes: int = 4000,
    max_methods: int = 6,
) -> str:
    if max_bytes <= 0 or max_method_bytes <= 0 or max_methods <= 0:
        return ""
    sections: list[str] = []
    used_bytes = len((SIDECAR_PREFIX + SIDECAR_SUFFIX).encode("utf-8"))
    if used_bytes >= max_bytes:
        return ""
    method_count = 0
    for relative, lines in sorted(added_lines_by_path(diff_text).items()):
        if method_count >= max_methods:
            break
        source = safe_repo_path(repo_root, relative)
        if source is None:
            continue
        try:
            source_lines = source.read_text(encoding="utf-8", errors="replace").splitlines(keepends=True)
        except OSError:
            continue
        for start, end in method_spans(repo_root, relative, lines):
            if method_count >= max_methods:
                break
            if start < 1 or end < start or end > len(source_lines):
                continue
            body = "".join(source_lines[start - 1 : end])
            if not body.endswith("\n"):
                body += "\n"
            header = f"文件: {relative}:{start}-{end}\n"
            section = header + body
            section_bytes = len(section.encode("utf-8"))
            separator_bytes = 1 if sections else 0
            if section_bytes > max_method_bytes or used_bytes + separator_bytes + section_bytes > max_bytes:
                continue
            sections.append(section)
            used_bytes += separator_bytes + section_bytes
            method_count += 1
    if not sections:
        return ""
    return SIDECAR_PREFIX + "\n".join(sections) + SIDECAR_SUFFIX


def main() -> int:
    if len(sys.argv) not in (3, 6):
        return 2
    repo_root = Path(sys.argv[1]).resolve()
    diff_path = Path(sys.argv[2])
    try:
        diff_text = diff_path.read_text(encoding="utf-8", errors="replace")
        if len(sys.argv) == 6:
            max_bytes, max_method_bytes, max_methods = (int(value) for value in sys.argv[3:6])
        else:
            max_bytes, max_method_bytes, max_methods = 6000, 4000, 6
    except (OSError, ValueError):
        return 2
    sys.stdout.write(build_sidecar(repo_root, diff_text, max_bytes, max_method_bytes, max_methods))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
