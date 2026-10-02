#!/usr/bin/env python3
"""Print the Java method containing a one-based source line."""

from pathlib import Path
import re
import sys


def mask_non_code(text: str) -> str:
    masked = list(text)
    state = "normal"
    index = 0
    while index < len(text):
        if state == "normal":
            if text.startswith("//", index):
                masked[index] = masked[index + 1] = " "
                index += 2
                state = "line"
                continue
            if text.startswith("/*", index):
                masked[index] = masked[index + 1] = " "
                index += 2
                state = "block"
                continue
            if text.startswith('"""', index):
                masked[index] = masked[index + 1] = masked[index + 2] = " "
                index += 3
                state = "text"
                continue
            if text[index] == '"':
                masked[index] = " "
                index += 1
                state = "string"
                continue
            if text[index] == "'":
                masked[index] = " "
                index += 1
                state = "char"
                continue
            index += 1
            continue
        if state == "line":
            if text[index] == "\n":
                state = "normal"
            else:
                masked[index] = " "
            index += 1
            continue
        if state == "block":
            if text.startswith("*/", index):
                masked[index] = masked[index + 1] = " "
                index += 2
                state = "normal"
            else:
                if text[index] != "\n":
                    masked[index] = " "
                index += 1
            continue
        if state == "text":
            if text.startswith('"""', index):
                masked[index] = masked[index + 1] = masked[index + 2] = " "
                index += 3
                state = "normal"
            else:
                if text[index] != "\n":
                    masked[index] = " "
                index += 1
            continue
        if text[index] == "\\":
            masked[index] = " "
            if index + 1 < len(text):
                if text[index + 1] != "\n":
                    masked[index + 1] = " "
                index += 2
            else:
                index += 1
            continue
        if (state == "string" and text[index] == '"') or (state == "char" and text[index] == "'"):
            masked[index] = " "
            index += 1
            state = "normal"
        else:
            if text[index] != "\n":
                masked[index] = " "
            index += 1
    return "".join(masked)


def main() -> int:
    if len(sys.argv) != 3 or not sys.argv[2].isdigit():
        return 2
    path = Path(sys.argv[1])
    target_line = int(sys.argv[2])
    text = path.read_text(encoding="utf-8", errors="replace")
    masked = mask_non_code(text)
    starts = [0]
    starts.extend(match.end() for match in re.finditer("\n", text))
    if target_line < 1 or target_line > len(starts):
        return 0
    target_offset = starts[target_line - 1]
    lines = text.splitlines(keepends=True)
    # Match every closing parenthesis to its opening parenthesis first. This
    # handles nested parameter annotations such as @Anno(value = "x"),
    # generic calls, and signatures whose parameters span multiple lines.
    paren_stack = []
    paren_open_for_close = {}
    for index, character in enumerate(masked):
        if character == "(":
            paren_stack.append(index)
        elif character == ")" and paren_stack:
            paren_open_for_close[index] = paren_stack.pop()

    method_name_re = re.compile(r"[A-Za-z_$][A-Za-z0-9_$]*[ \t]*$")
    control_names = {"if", "for", "while", "switch", "catch", "try", "synchronized"}
    for brace_index, character in enumerate(masked):
        if character != "{":
            continue

        close_paren = brace_index - 1
        while close_paren >= 0 and masked[close_paren].isspace():
            close_paren -= 1
        if close_paren < 0 or masked[close_paren] != ")":
            # A method may put a checked-exception clause between the
            # parameter list and the body brace.
            close_paren = masked.rfind(")", 0, brace_index)
            if close_paren < 0 or not re.fullmatch(
                r"[ \t\r\n]*throws\b[^{}]*", masked[close_paren + 1 : brace_index]
            ):
                continue
        open_paren = paren_open_for_close.get(close_paren)
        if open_paren is None:
            continue
        prefix = masked[:open_paren]
        name_match = method_name_re.search(prefix)
        if name_match is None:
            continue
        method_name = name_match.group(0).strip()
        if method_name in control_names:
            continue

        header_start = max(
            masked.rfind(";", 0, name_match.start()),
            masked.rfind("{", 0, name_match.start()),
            masked.rfind("}", 0, name_match.start()),
        ) + 1
        header = masked[header_start:brace_index]
        # Anonymous classes and lambdas can also have a parenthesized prefix
        # followed by a brace, but they are not Java method declarations.
        if re.search(r"\bnew\s+[A-Za-z_$][A-Za-z0-9_$.<>$]*\s*$", header):
            continue
        if "->" in header or re.search(r"\b(?:return|throw)\s*$", header):
            continue

        depth = 1
        close = None
        for index in range(brace_index + 1, len(masked)):
            if masked[index] == "{":
                depth += 1
            elif masked[index] == "}":
                depth -= 1
                if depth == 0:
                    close = index
                    break
        if close is None or not (header_start <= target_offset <= close):
            continue
        start_line = text.count("\n", 0, header_start)
        end_line = text.count("\n", 0, close) + 1
        sys.stdout.write("".join(lines[start_line:end_line]))
        return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
