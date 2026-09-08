#!/usr/bin/env python3
"""Check SPDX headers on audited project-owned source and build files."""

from __future__ import annotations

import pathlib
import subprocess
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPDX = "SPDX-License-Identifier: GPL-3.0-only"
SOURCE_SUFFIXES = {
    ".swift",
    ".kt",
    ".java",
    ".kts",
    ".gradle",
    ".py",
    ".sh",
    ".bash",
    ".zsh",
    ".m",
    ".mm",
    ".h",
    ".hh",
    ".hpp",
    ".c",
    ".cc",
    ".cpp",
    ".js",
    ".jsx",
    ".ts",
    ".tsx",
}
SPECIAL_FILES = {
    pathlib.Path("project.yml"),
    pathlib.Path("Package.swift"),
    pathlib.Path("android/gradle/libs.versions.toml"),
}
CONFIG_SUFFIXES = {".yml", ".yaml", ".toml", ".xcconfig"}
EXCLUDED_PREFIXES = (
    pathlib.Path(".build"),
    pathlib.Path("DerivedData"),
    pathlib.Path("android/gradle/wrapper"),
)
EXCLUDED_FILES = {
    pathlib.Path("Apps/iOS/BuildProvenance.generated.swift"),
    pathlib.Path("android/gradlew"),
    pathlib.Path("android/gradlew.bat"),
}


def tracked_paths() -> list[pathlib.Path]:
    result = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=ROOT,
        check=True,
        stdout=subprocess.PIPE,
    )
    return [pathlib.Path(item) for item in result.stdout.decode().split("\0") if item]


def is_excluded(relative: pathlib.Path) -> bool:
    return relative in EXCLUDED_FILES or any(
        relative == prefix or prefix in relative.parents for prefix in EXCLUDED_PREFIXES
    )


def is_audited_source(relative: pathlib.Path) -> bool:
    if is_excluded(relative):
        return False
    if relative in SPECIAL_FILES:
        return True
    if relative.name == "Secrets.example.xcconfig":
        return True
    return relative.suffix.lower() in SOURCE_SUFFIXES or relative.suffix.lower() in CONFIG_SUFFIXES


def has_header(relative: pathlib.Path) -> bool:
    try:
        lines = (ROOT / relative).read_text(encoding="utf-8").splitlines()[:24]
    except (UnicodeDecodeError, OSError):
        return False
    return any(SPDX in line for line in lines)


def main() -> int:
    missing = [path for path in tracked_paths() if is_audited_source(path) and not has_header(path)]
    if missing:
        for path in missing:
            print(f"missing SPDX header: {path}")
        return 1
    print("SPDX header check passed for audited project-owned source and build files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
