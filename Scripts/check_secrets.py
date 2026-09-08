#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Scan tracked repository files for high-confidence credential material.

The scanner intentionally reports only a path, line number, and finding class.
It never prints the matched value. It is a lightweight CI guard, not a claim
that a repository is mathematically free of secrets.
"""

from __future__ import annotations

import pathlib
import re
import subprocess
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
SENSITIVE_SUFFIXES = (
    ".p8",
    ".pem",
    ".key",
    ".mobileprovision",
    ".provisionprofile",
    ".p12",
    ".pfx",
)

PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("private-key-marker", re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----")),
    ("openai-style-key", re.compile(r"\b(?:sk|rk)-[A-Za-z0-9_-]{20,}\b")),
    ("google-api-key", re.compile(r"\bAIza[0-9A-Za-z_-]{20,}\b")),
    ("github-token", re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})\b")),
    ("slack-token", re.compile(r"\bxox[baprs]-[0-9A-Za-z-]{20,}\b")),
    ("aws-access-key", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("bearer-token", re.compile(r"\bBearer\s+[A-Za-z0-9._~+/=-]{24,}\b", re.IGNORECASE)),
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b")),
    (
        "credential-assignment",
        re.compile(
            r"(?m)^\s*(?:API_KEY|SECRET|SECRET_KEY|TOKEN|AUTH_TOKEN|PASSWORD|PRIVATE_KEY|"
            r"OPENAI_API_KEY|GEMINI_API_KEY|ANTHROPIC_API_KEY|DEVELOPMENT_TEAM|"
            r"PROVISIONING_PROFILE_SPECIFIER)\s*[:=]\s*['\"]?"
            r"(?!['\"]?\s*(?:$|#|//|\$\(|\{\{|YOUR_|CHANGE_ME|REPLACE_ME|"
            r"EXAMPLE|PLACEHOLDER|TODO|NONE|NIL|null|false)\b)[^\s'\"#]+"
        ),
    ),
)


def tracked_paths() -> list[pathlib.Path]:
    result = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=ROOT,
        check=True,
        stdout=subprocess.PIPE,
    )
    return [ROOT / item for item in result.stdout.decode().split("\0") if item]


def report(path: pathlib.Path, line_number: int, kind: str) -> None:
    relative = path.relative_to(ROOT)
    print(f"{relative}:{line_number}: {kind}")


def scan_file(path: pathlib.Path) -> int:
    if path.suffix.lower() in SENSITIVE_SUFFIXES:
        report(path, 1, "sensitive-file-extension")
        return 1

    try:
        text = path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        return 0

    findings = 0
    for line_number, line in enumerate(text.splitlines(), 1):
        if re.search(r"/(?:Users|Volumes)/[^/\s]+/", line):
            report(path, line_number, "personal-absolute-path")
            findings += 1
        for kind, pattern in PATTERNS:
            if pattern.search(line):
                report(path, line_number, kind)
                findings += 1
    return findings


def main() -> int:
    findings = sum(scan_file(path) for path in tracked_paths())
    if findings:
        print(f"secret scan failed: {findings} finding(s); values were intentionally omitted", file=sys.stderr)
        return 1
    print("secret scan passed: no high-confidence credential material found in tracked files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
