#!/usr/bin/env python3
"""Extract a small, license-aware Java audit set from a local Juliet archive.

The archive is supplied by the caller and is never downloaded here. Generated
records are intended for private smoke/training experiments, not the Platform
independent holdout.
"""

from __future__ import annotations

import argparse
import json
import re
import zipfile
from pathlib import Path


DEFAULT_CWES = [
    "CWE259",
    "CWE321",
    "CWE327",
    "CWE328",
    "CWE338",
    "CWE369",
    "CWE400",
    "CWE404",
    "CWE566",
    "CWE598",
    "CWE601",
    "CWE609",
    "CWE613",
    "CWE614",
    "CWE667",
    "CWE833",
    "CWE835",
]

SECURITY_CWES = {
    "CWE259",
    "CWE321",
    "CWE327",
    "CWE328",
    "CWE338",
    "CWE566",
    "CWE598",
    "CWE601",
    "CWE613",
    "CWE614",
}


def cwe_for_path(path: str) -> str | None:
    match = re.search(r"/(CWE\d{3})_", path)
    return match.group(1) if match else None


def normalize_manifest_path(value: str) -> str:
    """Normalize Juliet manifest paths without collapsing distinct files."""
    normalized = value.replace("\\", "/").strip()
    while normalized.startswith("./"):
        normalized = normalized[2:]
    if normalized.startswith("Java/"):
        normalized = normalized[5:]
    return normalized


def read_manifest(archive: zipfile.ZipFile) -> dict[str, list[tuple[int, str]]]:
    manifest_name = next(
        (name for name in archive.namelist() if name.endswith("/manifest.xml")), None
    )
    if not manifest_name:
        raise ValueError("archive does not contain a Juliet manifest.xml")
    result: dict[str, list[tuple[int, str]]] = {}
    basename_entries: dict[str, list[list[tuple[int, str]]]] = {}
    # The published Juliet manifest contains legacy malformed XML near the end
    # of the file. Parse only its stable file/flaw line records instead of
    # silently repairing the document with a permissive XML parser.
    current: str | None = None
    for raw_line in archive.read(manifest_name).decode("utf-8", errors="replace").splitlines():
        file_match = re.search(r'<file\s+path="([^"]+)"', raw_line)
        if file_match:
            current = normalize_manifest_path(file_match.group(1))
            result.setdefault(current, [])
            basename_entries.setdefault(Path(current).name, []).append(result[current])
        flaw_match = re.search(r'<flaw\s+line="([0-9]+)"\s+name="([^"]*)"', raw_line)
        if current and flaw_match:
            result[current].append((int(flaw_match.group(1)), flaw_match.group(2)))
        if "</file>" in raw_line:
            current = None
    # Keep a basename fallback only when it is unambiguous.  Juliet contains
    # repeated testcase names in different CWE directories; a plain basename
    # lookup would otherwise attach one file's flaw lines to another file.
    for basename, entries in basename_entries.items():
        if len(entries) == 1:
            result.setdefault(basename, entries[0])
    return result


def manifest_flaws(manifest: dict[str, list[tuple[int, str]]], path: str) -> list[tuple[int, str]]:
    """Return flaws for an archive path, with a safe unique-basename fallback."""
    normalized = normalize_manifest_path(path)
    return manifest.get(normalized, manifest.get(Path(normalized).name, []))


def record(source_name: str, source_url: str, split: str, path: str, code: str,
           cwe: str, label: str, flaws: list[tuple[int, str]]) -> dict:
    if label == "positive":
        severity = "P1" if cwe in SECURITY_CWES else "P2"
        findings = [
            {
                "severity": severity,
                "path": path,
                "line": line,
                "evidence": f"{name}; NIST Juliet synthetic testcase ({cwe})",
                "impact": "The testcase contains the labeled weakness and should not be treated as safe production code.",
                "fix": "Apply the CWE-specific safe-source/sink or validation pattern and preserve the surrounding contract.",
                "verification": "Run the matching negative/positive static-analysis or unit-test pair and inspect the labeled line.",
            }
            for line, name in flaws
        ]
        root_causes = [cwe.lower()]
    else:
        findings = []
        root_causes = []
    return {
        "id": f"juliet-java-1.3:{path}:{label}",
        "source": {"name": source_name, "url": source_url},
        "license": "Public-Domain",
        "split": split,
        "repository": "nist-sard/juliet-java-1.3",
        "commit": "2017-10-01",
        "language": "java",
        "framework": "servlet-testcase",
        "task": "audit-finding",
        "label": label,
        "root_causes": root_causes,
        "file_path": path,
        "source_code": code,
        "findings": findings,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--limit-per-cwe", type=int, default=1)
    parser.add_argument("--cwe", nargs="*", default=DEFAULT_CWES)
    parser.add_argument("--split", default="external-smoke")
    args = parser.parse_args()
    if args.limit_per_cwe < 1:
        parser.error("--limit-per-cwe must be positive")

    wanted = set(args.cwe)
    with zipfile.ZipFile(args.archive) as archive:
        manifest = read_manifest(archive)
        names = sorted(
            name for name in archive.namelist()
            if name.startswith("Java/src/testcases/")
            and name.endswith(".java")
            and "/antbuild/" not in name
            and "/testcasesupport/" not in name
            and not name.endswith("/Main.java")
            and not name.endswith("/ServletMain.java")
            and cwe_for_path(name) in wanted
        )
        by_cwe: dict[str, list[str]] = {cwe: [] for cwe in wanted}
        for name in names:
            cwe = cwe_for_path(name)
            if cwe:
                by_cwe.setdefault(cwe, []).append(name)

        selected: list[dict] = []
        source_name = "NIST SARD Juliet Java Test Suite 1.3"
        source_url = "https://samate.nist.gov/SARD/test-suites/111"
        for cwe in sorted(wanted):
            files = by_cwe.get(cwe, [])
            bad = [name for name in files if "_good" not in Path(name).name and manifest_flaws(manifest, name)]
            good = [name for name in files if "_good" in Path(name).name]
            for name, label in [*( (name, "positive") for name in bad[:args.limit_per_cwe]),
                                *( (name, "clean") for name in good[:args.limit_per_cwe])]:
                relative = name.removeprefix("Java/")
                code = archive.read(name).decode("utf-8", errors="replace")
                selected.append(record(source_name, source_url, args.split, relative, code,
                                       cwe, label, manifest_flaws(manifest, name)))

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8") as handle:
        for item in selected:
            handle.write(json.dumps(item, ensure_ascii=False) + "\n")
    print(f"wrote {len(selected)} Juliet records to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
