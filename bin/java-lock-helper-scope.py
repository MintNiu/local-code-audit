#!/usr/bin/env python3
"""Certify one narrow private-leaf finally release; unknown prints nothing.

This is a bounded source recognizer, not Java compilation or general call-graph
analysis. It only exempts a deterministic missing-release candidate, never a
model paragraph. Source is read as data and is never imported or executed.
"""

from pathlib import Path
import re
import sys


IDENTIFIER = r"[A-Za-z_][A-Za-z0-9_]*"
LOCK_TYPE = r"java\s*\.\s*util\s*\.\s*concurrent\s*\.\s*locks\s*\.\s*ReentrantLock"
MAX_SOURCE_BYTES = 1024 * 1024


def mask_source(source):
    """Reject unsupported lexical forms and preserve offsets and newlines."""
    # This narrow proof supports LF source only. Java also ends // comments at
    # CR: treating a CR-bearing line as LF-only could hide executable code.
    if re.search(r"\\u", source) or '"""' in source or "\x00" in source or "\r" in source:
        return None
    masked = list(source)
    index = 0
    while index < len(source):
        if source.startswith("//", index):
            end = source.find("\n", index)
            end = len(source) if end < 0 else end
        elif source.startswith("/*", index):
            closing = source.find("*/", index + 2)
            if closing < 0:
                return None
            end = closing + 2
        elif source[index] in "\"'":
            quote, end = source[index], index + 1
            while end < len(source) and source[end] != quote:
                if source[end] in "\r\n":
                    return None
                if source[end] == "\\":
                    end += 1
                    if end >= len(source) or source[end] in "\r\n":
                        return None
                end += 1
            if end >= len(source):
                return None
            end += 1
            # Do not erase a literal into an empty executable statement.
            masked[index] = "0"
            for cursor in range(index + 1, end):
                masked[cursor] = " "
            index = end
            continue
        elif source.startswith("*/", index):
            return None
        else:
            index += 1
            continue
        for cursor in range(index, end):
            if source[cursor] not in "\r\n":
                masked[cursor] = " "
        index = end
    return "".join(masked)


def delimiter_pairs(masked):
    stack, pairs = [], {}
    for offset, char in enumerate(masked):
        if char in "({[":
            stack.append((char, offset))
        elif char in ")}]":
            if not stack or stack[-1][0] != {")": "(", "}": "{", "]": "["}[char]:
                return None
            _, opening = stack.pop()
            pairs[opening] = offset
    return None if stack else pairs


def class_members(masked, opening, closing, pairs):
    """Only parse direct member boundaries; do not search nested bodies."""
    fields, methods, cursor = [], [], opening + 1
    while cursor < closing:
        if masked[cursor].isspace():
            cursor += 1
            continue
        start = cursor
        while cursor < closing and masked[cursor] not in ";{":
            if masked[cursor] in "([":
                cursor = pairs[cursor]
            cursor += 1
        if cursor >= closing:
            return None
        header = masked[start:cursor].strip()
        if masked[cursor] == ";":
            fields.append(header)
            cursor += 1
            continue
        end = pairs[cursor]
        method = re.fullmatch(
            r"(?P<modifiers>(?:(?:public|protected|private|static|final|synchronized)\s+)*)"
            r"void\s+(?P<name>" + IDENTIFIER + r")\s*\((?P<params>[^(){};]*)\)"
            r"(?:\s+throws\s+[A-Za-z_$][A-Za-z0-9_$.,\s]*)?", header)
        if not method:
            return None
        methods.append((method, cursor, end))
        cursor = end + 1
    return fields, methods


def proves_release(source, line, receiver):
    if not re.fullmatch(IDENTIFIER, receiver) or line < 1:
        return False
    masked = mask_source(source)
    # Java's ignorable identifier characters include ASCII controls as well as
    # Unicode format characters. Only printable ASCII and Java LF/TAB/FF
    # whitespace are recognized; comments and literals may contain Unicode.
    if masked is None or any(not (" " <= char <= "~" or char in "\n\t\f") for char in masked):
        return False
    pairs = delimiter_pairs(masked)
    if pairs is None or len(re.findall(r"\b(?:class|interface|enum|record)\b", masked)) != 1:
        return False
    declaration = re.match(
        r"\s*(?:package\s+[A-Za-z_$][\w$]*(?:\s*\.\s*[\w$]+)*\s*;\s*)?"
        r"(?:import\s+(?:static\s+)?[\w$.*\s]+;\s*)*"
        r"(?:public\s+)?(?:final\s+)?class\s+" + IDENTIFIER + r"\s*\{", masked)
    if not declaration:
        return False
    opening = declaration.end() - 1
    closing = pairs[opening]
    if masked[closing + 1:].strip():
        return False
    members = class_members(masked, opening, closing, pairs)
    if members is None:
        return False
    fields, methods = members
    field_pattern = (r"private\s+final\s+" + LOCK_TYPE + r"\s+" + re.escape(receiver) +
                     r"\s*=\s*new\s+" + LOCK_TYPE + r"\s*\(\s*\)")
    if sum(bool(re.fullmatch(field_pattern, field)) for field in fields) != 1:
        return False
    # No other direct field may re-declare the same name, even in invalid input.
    if sum(bool(re.search(r"\b" + re.escape(receiver) + r"\s*(?:=|$)", field))
           for field in fields) != 1:
        return False
    field_access = r"(?:this\s*\.\s*)?" + re.escape(receiver)
    acquire = re.compile(r"(?<![\w$.])" + field_access +
                         r"\s*\.\s*(?:lock|lockInterruptibly)\s*\(\s*\)\s*;")
    targets = []
    for method, start, end in methods:
        body = masked[start + 1:end]
        acquisitions = list(acquire.finditer(body))
        if len(acquisitions) != 1:
            continue
        call = acquisitions[0]
        if source.count("\n", 0, start + 1 + call.start()) + 1 == line:
            targets.append((method, start, end, body, call))
    if len(targets) != 1:
        return False
    method, start, end, body, call = targets[0]
    if "static" in method["modifiers"].split() or re.search(r"\b" + re.escape(receiver) + r"\b", method["params"]):
        return False
    if body[:call.start()].strip():
        return False
    # Any other reference to the field/name may introduce another acquisition,
    # a shadow, alias or receiver. Unknown remains on the original preflight path.
    if re.search(r"\b" + re.escape(receiver) + r"\b", body[call.end():]):
        return False
    after_call = start + 1 + call.end()
    try_match = re.match(r"\s*try\s*\{", masked[after_call:end])
    if not try_match:
        return False
    try_open = after_call + try_match.end() - 1
    try_end = pairs[try_open]
    finally_match = re.match(r"\s*finally\s*\{", masked[try_end + 1:end])
    if not finally_match:
        return False
    finally_open = try_end + 1 + finally_match.end() - 1
    finally_end = pairs[finally_open]
    if finally_end >= end or masked[finally_end + 1:end].strip():
        return False
    release = re.fullmatch(r"\s*(?:this\s*\.\s*)?(" + IDENTIFIER +
                           r")\s*\(\s*\)\s*;\s*", masked[finally_open + 1:finally_end])
    if not release:
        return False
    helpers = [(item, begin, finish) for item, begin, finish in methods
               if item["name"] == release[1]]
    if len(helpers) != 1:
        return False
    helper, helper_start, helper_end = helpers[0]
    if helper["params"].strip() or helper["modifiers"].split() != ["private"]:
        return False
    if not re.fullmatch(r"\s*" + field_access + r"\s*\.\s*unlock\s*\(\s*\)\s*;\s*",
                        masked[helper_start + 1:helper_end]):
        return False
    # Do not build a call graph: another member may acquire this reentrant lock
    # or expose an alias. Only the declared field and the proved pair may use it.
    name = re.compile(r"(?<![\w$])" + re.escape(receiver) + r"(?![\w$])")
    if any(name.search(field) for field in fields if not re.fullmatch(field_pattern, field)):
        return False
    for other, other_start, other_end in methods:
        if other_start not in (start, helper_start):
            if name.search(other["params"]) or name.search(masked[other_start + 1:other_end]):
                return False
    return True


def main():
    if len(sys.argv) != 4:
        return
    try:
        source_path = Path(sys.argv[1])
        if source_path.is_symlink() or source_path.stat().st_size > MAX_SOURCE_BYTES:
            return
        with source_path.open("rb") as source_file:
            data = source_file.read(MAX_SOURCE_BYTES + 1)
        if len(data) <= MAX_SOURCE_BYTES and proves_release(data.decode("utf-8"), int(sys.argv[2]), sys.argv[3]):
            print("released")
    except (OSError, UnicodeError, ValueError, KeyError, IndexError, RecursionError):
        return


if __name__ == "__main__":
    main()
