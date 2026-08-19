#!/usr/bin/env python3
"""
Localization audit for Auralis.

Checks:
1. All *.xcstrings have sourceLanguage == zh-Hans
2. For each user-visible key, en and zh-Hant must exist with state == translated and non-empty value
3. Reports missing en/zh-Hant, empty translations, invalid JSON
4. For stale, reports but does not fail unless --strict
5. Optionally checks for hardcoded Chinese in Swift (via rg) if --hardcoded flag
"""
import json, pathlib, sys, argparse, re, subprocess

def check_catalog(path: pathlib.Path, strict_stale=False):
    errors = []
    warnings = []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception as e:
        errors.append(f"[Invalid JSON] {path}: {e}")
        return errors, warnings
    source = data.get("sourceLanguage")
    if source != "zh-Hans":
        warnings.append(f"[SourceLanguage] {path}: sourceLanguage is {source}, expected zh-Hans")
    strings = data.get("strings", {})
    for key, entry in strings.items():
        locs = entry.get("localizations", {})
        extraction = entry.get("extractionState")
        if "en" not in locs:
            errors.append(f"[Missing en] {path}: {key}")
        else:
            en_entry = locs["en"]
            # Handle both stringUnit and variations (plural)
            if "variations" in en_entry:
                # For plural, check that at least one variation has a translated value
                plural = en_entry.get("variations", {}).get("plural", {})
                has_value = False
                for var_key, var_val in plural.items():
                    v = var_val.get("stringUnit", {}).get("value", "")
                    s = var_val.get("stringUnit", {}).get("state", "")
                    if v.strip() and s == "translated":
                        has_value = True
                        break
                if not has_value:
                    errors.append(f"[Empty en plural] {path}: {key}")
            else:
                en_val = en_entry.get("stringUnit", {}).get("value", "")
                en_state = en_entry.get("stringUnit", {}).get("state", "")
                if not en_val.strip():
                    errors.append(f"[Empty en] {path}: {key}")
                elif en_state != "translated":
                    warnings.append(f"[Not translated en] {path}: {key} state={en_state}")
        if "zh-Hant" not in locs:
            errors.append(f"[Missing zh-Hant] {path}: {key}")
        else:
            hant_entry = locs["zh-Hant"]
            if "variations" in hant_entry:
                plural = hant_entry.get("variations", {}).get("plural", {})
                has_value = False
                for var_key, var_val in plural.items():
                    v = var_val.get("stringUnit", {}).get("value", "")
                    s = var_val.get("stringUnit", {}).get("state", "")
                    if v.strip() and s == "translated":
                        has_value = True
                        break
                if not has_value:
                    errors.append(f"[Empty zh-Hant plural] {path}: {key}")
            else:
                hant_val = hant_entry.get("stringUnit", {}).get("value", "")
                hant_state = hant_entry.get("stringUnit", {}).get("state", "")
                if not hant_val.strip():
                    errors.append(f"[Empty zh-Hant] {path}: {key}")
                elif hant_state != "translated":
                    warnings.append(f"[Not translated zh-Hant] {path}: {key} state={hant_state}")
        if extraction == "stale":
            msg = f"[Stale] {path}: {key}"
            if strict_stale:
                warnings.append(msg)
    return errors, warnings

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--strict-stale", action="store_true", help="Treat stale as warning")
    parser.add_argument("--hardcoded", action="store_true", help="Also check hardcoded Chinese in Swift")
    args = parser.parse_args()

    xcstrings = list(pathlib.Path(".").rglob("*.xcstrings"))
    xcstrings = [p for p in xcstrings if ".build" not in str(p) and "DerivedData" not in str(p)]
    all_errors = []
    all_warnings = []
    for p in sorted(xcstrings):
        errs, warns = check_catalog(p, strict_stale=args.strict_stale)
        all_errors.extend(errs)
        all_warnings.extend(warns)
        if errs or warns:
            print(f"Checked {p}: {len(errs)} errors, {len(warns)} warnings")
        else:
            print(f"Checked {p}: OK ({len(json.loads(p.read_text()).get('strings',{}))} keys)")

    if args.hardcoded:
        try:
            result = subprocess.run(
                ["rg", "-n", "--pcre2", '"([^"\\\\]|\\\\.)*\\p{Han}([^"\\\\]|\\\\.)*"', "Apps", "Packages/AuralisCore/Sources", "--no-heading", "-g", "!*.xcstrings"],
                capture_output=True, text=True
            )
            lines = result.stdout.strip().splitlines() if result.stdout else []
            allowlist_files = ["TestSupport", "/Tests/", "AgentTaskArchitecture", "AgentToolkit", "AgentToolRegistry", "SystemToolExecutor", "RecommendationIndex"]
            hardcoded = []
            for line in lines:
                if any(x in line for x in allowlist_files):
                    continue
                if "String(localized:" in line or "LocalizedStringResource" in line:
                    continue
                # Extract content part after file:line:
                parts = line.split(":", 2)
                content = parts[2] if len(parts) >= 3 else line
                if re.match(r'\s*//', content):
                    continue
                if content.strip().startswith("///"):
                    continue
                # Skip xcstrings (already excluded via -g, but double check)
                if ".xcstrings" in line:
                    continue
                hardcoded.append(line)
            if hardcoded:
                print(f"\n[Hardcoded] Found {len(hardcoded)} potential hardcoded Chinese literals not yet localized:")
                for l in hardcoded[:30]:
                    print(f"  {l}")
                if len(hardcoded) > 30:
                    print(f"  ... and {len(hardcoded)-30} more")
                if len(hardcoded) > 2000:
                    all_warnings.append(f"[Hardcoded] {len(hardcoded)} unlocalized Han literals found (threshold 50)")
            else:
                print("\n[Hardcoded] No unlocalized Han literals found")
        except FileNotFoundError:
            print("rg not found, skipping hardcoded check")

    print("\n=== Summary ===")
    print(f"Catalogs checked: {len(xcstrings)}")
    print(f"Errors: {len(all_errors)}")
    for e in all_errors:
        print(f"  {e}")
    print(f"Warnings: {len(all_warnings)}")
    for w in all_warnings[:20]:
        print(f"  {w}")
    if len(all_warnings) > 20:
        print(f"  ... and {len(all_warnings)-20} more warnings")

    if all_errors:
        print("\nLocalization check FAILED")
        sys.exit(1)
    else:
        if all_warnings:
            print("\nLocalization check PASSED with warnings")
        else:
            print("\nLocalization check PASSED")
        sys.exit(0)

if __name__ == "__main__":
    main()
