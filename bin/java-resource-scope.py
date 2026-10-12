#!/usr/bin/env python3
"""Classify one Java close() call using its method-local resource scope.

The caller supplies a source file and a one-based close-call line.  The
classifier intentionally recognizes only the same small resource family as
the shell preflight.  It masks comments and literals through
``java-method-window.py`` and distinguishes a finally/TWR scope that actually
contains the candidate close from an unrelated safe resource in the method.
"""

from __future__ import annotations

import importlib.util
from pathlib import Path
import re
import subprocess
import sys


RESOURCE_TYPES = r"FileReader|FileInputStream|BufferedReader|InputStreamReader"


def load_window_module():
    path = Path(__file__).with_name("java-method-window.py")
    spec = importlib.util.spec_from_file_location("java_method_window", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load java-method-window.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def matching_close(text: str, opening: int, left: str, right: str) -> int | None:
    depth = 1
    for index in range(opening + 1, len(text)):
        if text[index] == left:
            depth += 1
        elif text[index] == right:
            depth -= 1
            if depth == 0:
                return index
    return None


def brace_end(text: str, opening: int) -> int | None:
    return matching_close(text, opening, "{", "}")


def method_span(source: Path, target_line: int) -> tuple[int, int]:
    command = [sys.executable, str(Path(__file__).with_name("java-method-window.py")),
               str(source), str(target_line), "--span"]
    completed = subprocess.run(command, capture_output=True, text=True, check=False)
    match = re.fullmatch(r"([0-9]+)\t([0-9]+)\n?", completed.stdout)
    if completed.returncode != 0 or match is None:
        return (0, 0)
    return int(match.group(1)), int(match.group(2))


def classify(source: Path, target_line: int) -> str:
    text = source.read_text(encoding="utf-8", errors="replace")
    start_line, end_line = method_span(source, target_line)
    if not start_line or not (start_line <= target_line <= end_line):
        return "unknown"

    module = load_window_module()
    masked = module.mask_non_code(text)
    lines = masked.splitlines()
    method_lines = lines[start_line - 1:end_line]
    if not method_lines:
        return "unknown"
    method_text = "\n".join(method_lines)
    target_index = target_line - start_line
    if target_index < 0 or target_index >= len(method_lines):
        return "unknown"

    # Bind evidence to the actual receiver on the candidate close line.  This
    # keeps a safe `readerA` finally block from suppressing a later leaking
    # `readerB` in the same method.
    receiver_match = re.search(
        r"\b([A-Za-z_$][A-Za-z0-9_$]*)\s*\.\s*close\s*\(\s*\)",
        method_lines[target_index],
    )
    if receiver_match is None:
        return "unknown"
    receiver = receiver_match.group(1)
    before_target = "\n".join(method_lines[:target_index + 1])
    resource_assignment = re.compile(
        rf"\b{re.escape(receiver)}\s*=\s*new\s+(?:{RESOURCE_TYPES})\s*\("
    )
    if resource_assignment.search(before_target) is None:
        return "unknown"

    # Scan balanced try-with-resources headers and their bodies.  This handles
    # multiline headers and nested constructor parentheses without a fragile
    # single-line grep.
    index = 0
    while index < len(method_text):
        match = re.search(r"\btry\s*\(", method_text[index:])
        if match is None:
            break
        open_paren = index + match.end() - 1
        close_paren = matching_close(method_text, open_paren, "(", ")")
        if close_paren is None:
            break
        header = method_text[open_paren + 1:close_paren]
        body_open = close_paren + 1
        while body_open < len(method_text) and method_text[body_open].isspace():
            body_open += 1
        body_end = brace_end(method_text, body_open) if body_open < len(method_text) and method_text[body_open] == "{" else None
        if body_end is not None and re.search(rf"\b{re.escape(receiver)}\b", header):
            target_offset = sum(len(line) + 1 for line in method_lines[:target_index])
            if body_open <= target_offset <= body_end:
                return "safe"
        index = close_paren + 1

    # Find finally blocks whose balanced body contains this close call.  A
    # finally elsewhere in the same method must not suppress this candidate.
    target_offset = sum(len(line) + 1 for line in method_lines[:target_index])
    for finally_match in re.finditer(r"\bfinally\b", method_text):
        body_open = finally_match.end()
        while body_open < len(method_text) and method_text[body_open].isspace():
            body_open += 1
        body_end = brace_end(method_text, body_open) if body_open < len(method_text) and method_text[body_open] == "{" else None
        if body_end is not None and body_open <= target_offset <= body_end:
            return "safe"

    return "leak"


def main() -> int:
    if len(sys.argv) != 3 or not sys.argv[2].isdigit():
        return 2
    result = classify(Path(sys.argv[1]), int(sys.argv[2]))
    print(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
