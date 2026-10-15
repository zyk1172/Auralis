#!/usr/bin/env python3
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
"""Generate Android's fixed IDs/names/aliases from the Apple taxonomy; --check detects drift."""
import argparse
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
SWIFT = ROOT / "Packages/AuralisCore/Sources/LocalCatalog/RecommendationIndexTaxonomy.swift"
KOTLIN = ROOT / "android/core/domain/src/main/java/com/auralis/core/domain/RecommendationIndexTaxonomy.kt"
BEGIN = "        // BEGIN GENERATED TAXONOMY — Scripts/sync_recommendation_taxonomy.py\n"
END = "        // END GENERATED TAXONOMY"
ENTRY = re.compile(r'^        (mood|scene|theme|genre|style|vocal|instrument|texture|rhythm)\("([^"\n]+)", "([^"\n]+)"(?:, aliases: (\[[^\n]*\]))?\),$')


def generated() -> str:
    rows, seen = [], set()
    for line in SWIFT.read_text().splitlines():
        match = ENTRY.fullmatch(line)
        if not match:
            if re.match(r"^        (mood|scene|theme|genre|style|vocal|instrument|texture|rhythm)\(", line):
                raise ValueError(f"Unrecognized taxonomy entry: {line}")
            continue
        dimension, suffix, name, raw_aliases = match.groups()
        tag_id = f"{dimension}.{suffix}"
        if tag_id in seen:
            raise ValueError(f"Duplicate canonical tag ID: {tag_id}")
        seen.add(tag_id)
        values = [dimension, tag_id, name, *json.loads(raw_aliases or "[]")]
        rows.append("        t(" + ", ".join(json.dumps(value, ensure_ascii=False) for value in values) + "),")
    if not rows:
        raise ValueError("Empty taxonomy")
    return BEGIN + "        listOf(\n" + "\n".join(rows) + "\n        )\n" + END


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    current = KOTLIN.read_text()
    start, end = current.index(BEGIN), current.index(END) + len(END)
    updated = current[:start] + generated() + current[end:]
    if args.check:
        if updated != current:
            raise SystemExit("Android taxonomy differs; run python3 Scripts/sync_recommendation_taxonomy.py")
        print("Taxonomy IDs, display names and aliases match on Apple and Android")
    else:
        KOTLIN.write_text(updated)


if __name__ == "__main__":
    main()
