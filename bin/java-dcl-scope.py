#!/usr/bin/env python3
"""Recognize method-local DCL structure in comment/literal-masked Java.

This is a narrow evidence check, not a Java parser or a whole-program proof.
The caller separately checks that the name denotes a non-volatile static
field. Unsupported syntax produces no deterministic finding.
"""

from __future__ import annotations

import re
import sys
from typing import NamedTuple


class Block(NamedTuple):
    kind: str
    start: int
    condition: str
    opening: int
    closing: int


def delimiter_pairs(text: str) -> dict[int, int]:
    stack = []
    pairs = {}
    for index, char in enumerate(text):
        if char in "({[":
            stack.append((char, index))
        elif char in ")}]":
            if not stack or stack[-1][0] != {")": "(", "}": "{", "]": "["}[char]:
                return {}
            _, opening = stack.pop()
            pairs[opening] = index
    return {} if stack else pairs


def has_dcl(method: str, field: str) -> bool:
    if not re.fullmatch(r"[A-Za-z_$][A-Za-z0-9_$]*", field):
        return False
    pairs = delimiter_pairs(method)
    # Skip annotation argument lists, including arrays, before the body.
    method_open = 0
    while method_open < len(method):
        if method[method_open] == "(" and method_open in pairs:
            method_open = pairs[method_open] + 1
        elif method[method_open] == "{":
            break
        else:
            method_open += 1
    if method_open not in pairs:
        return False
    header = method[:method_open]
    # Method-wide synchronization and parameter shadowing invalidate this
    # particular unsynchronized-field evidence. Include multiline headers.
    if re.search(r"\bsynchronized\b", header):
        return False
    name = re.escape(field)
    # Ignore annotation literals/attributes when checking parameters.
    parameter_close = header.rfind(")")
    parameter_open = next((opening for opening, closing in pairs.items()
                           if closing == parameter_close), -1)
    if parameter_open >= 0 and re.search(rf"(?<![\w$]){name}\s*(?:\[\s*\]\s*)*(?:,|$)", header[parameter_open + 1:parameter_close]):
        return False
    body = method[method_open + 1:pairs[method_open]]
    # Local declarations, deferred lambdas and nested/anonymous classes need
    # ownership/control-flow analysis beyond this small structural check.
    declarations = re.finditer(rf"\b([A-Za-z_$][\w$<>.,?\[\]]*)\s+{name}\s*(?:=|;|:)", body)
    if any(match[1] not in {"return", "throw", "yield"} for match in declarations):
        return False

    blocks = []
    for match in re.finditer(r"\b(if|synchronized)\s*\(", method):
        paren = match.end() - 1
        if paren not in pairs:
            continue
        end = pairs[paren]
        opening = end + 1
        while opening < len(method) and method[opening].isspace():
            opening += 1
        if opening in pairs and method[opening] == "{":
            blocks.append(Block(match[1], match.start(), method[paren + 1:end].strip(),
                                opening, pairs[opening]))

    guards = [block for block in blocks if block.kind == "if" and re.fullmatch(
        rf"{name}\s*==\s*null|null\s*==\s*{name}", block.condition)]
    locks = [block for block in blocks if block.kind == "synchronized"]
    assignments = list(re.finditer(rf"(?<![\w$.]){name}\s*=\s*new\s+[A-Za-z_$]", method))
    deferred = []
    for match in re.finditer(r"->|\bnew\s+[\w$.<>]+\s*\(|\b(?:class|interface|enum|record)\s+[\w$]+", method):
        if match[0] == "->" and re.search(r"\b(?:case\s+[^;{}]+|default)\s*$", method[:match.start()]):
            continue  # switch rules execute now; they are not lambda bodies.
        opening = match.end()
        if match[0].endswith("("):
            if opening - 1 not in pairs:
                continue
            opening = pairs[opening - 1] + 1
        elif match[0] != "->":
            # A local class may have type parameters or an extends clause.
            while opening < len(method) and method[opening] not in "{;}":
                opening += 1
        while opening < len(method) and method[opening].isspace():
            opening += 1
        if opening < len(method) and method[opening] == "{" and opening in pairs:
            deferred.append((opening, pairs[opening]))
        elif match[0] == "->":
            end = method.find(";", opening)
            deferred.append((opening - 1, end if end >= 0 else len(method)))
    assignments = [assignment for assignment in assignments
                   if not method[:assignment.start()].rstrip().endswith(".")
                   and not any(start < assignment.start() < end for start, end in deferred)]
    for outer in guards:
        if any(lock.opening < outer.start < lock.closing for lock in locks):
            continue
        for lock in locks:
            if not outer.opening < lock.start < lock.closing < outer.closing:
                continue
            for inner in guards:
                if not lock.opening < inner.start < inner.closing < lock.closing:
                    continue
                if any(inner.opening < assignment.start() < inner.closing for assignment in assignments):
                    return True
    return False


def main() -> int:
    if len(sys.argv) != 2:
        return 2
    print("unsafe" if has_dcl(sys.stdin.read(), sys.argv[1]) else "unknown")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
