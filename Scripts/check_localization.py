#!/usr/bin/env python3
"""
Localization audit for Auralis.

Checks:
1. All *.xcstrings have sourceLanguage == zh-Hans
2. For each user-visible key, en and zh-Hant must exist with state == translated and non-empty value
3. **English translation must not contain Han (simplified/traditional CJK)** — an en value that is
   still Chinese is a "fake translation" failure, NOT a warning.
4. **zh-Hant must not show obvious simplified-Chinese leakage** (heuristic char set, no OpenCC dep).
5. Invalid JSON, stale reporting.
6. `--hardcoded`: user-visible hardcoded Chinese in Swift → ERROR (not a threshold); internal
   fixed strings excluded via `// i18n:ignore - <reason>`.

Exit code 0 = pass, 1 = fail.
"""
import json, pathlib, sys, argparse, re, shutil, subprocess

HAN_RE = re.compile(r"[\u3400-\u4DBF\u4E00-\u9FFF]")

def contains_han(text: str) -> bool:
    return bool(HAN_RE.search(text))

# 明显简体释放检测字符集：只收「绝不会出现在规范繁体里的简体字」（有繁体区分度的）。
# 两岸同形字（如 入/引/示/列/索/置/接/理/限/清）不在此列，避免误报。
SIMPLIFIED_INDICATORS = set(
    "设网络连数据资讯库载队显录历标签发现开关页张专辑艺术听话这为后从还删选"
    "择导维护处权优级项单时间进过给认证计错协联门问题义图际线总结复预视觉压评请"
    "识读讲检误环详费监编续断围测试执号组应质声频仅键传备护择导关产华卫层业汇"
)

# 允许 en 保留原名（品牌/专有名词），但这类 source 本身不应含汉字。
EN_ALLOWLIST = {
    "Auralis", "API", "OpenAI", "AirPlay", "Wi-Fi", "ReplayGain", "MusicBrainz",
    "ListenBrainz", "JSON", "SQLite", "Keychain", "OpenSubsonic", "Navidrome",
    "Siri", "CritiqueBrainz", "AppIntents", "token", "Base URL", "Token",
}

def get_value(loc_entry):
    """从 localization entry 提取 (value, state)。处理 variations(复数)。"""
    if not loc_entry:
        return None, None
    if "variations" in loc_entry:
        plural = loc_entry.get("variations", {}).get("plural", {})
        # 取 'other' 或任一变体作为代表
        for key in ("other", "one", "zero", "two", "few", "many"):
            if key in plural:
                su = plural[key].get("stringUnit", {})
                return su.get("value", ""), su.get("state", "")
        return None, None
    su = loc_entry.get("stringUnit", {})
    return su.get("value", ""), su.get("state", "")

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

        # ---- en ----
        if "en" not in locs:
            errors.append(f"[Missing en] {path}: {key}")
        else:
            en_val, en_state = get_value(locs["en"])
            if en_val is None or not en_val.strip():
                errors.append(f"[Empty en] {path}: {key}")
            elif en_state != "translated":
                warnings.append(f"[Not translated en] {path}: {key} state={en_state}")
            else:
                # 英文翻译必须不含汉字（假翻译）。
                if contains_han(en_val):
                    errors.append(f"[English contains Han] {path}: key={key} value={en_val[:40]}")
                elif contains_han(key) and en_val.strip() == key.strip():
                    errors.append(f"[English equals source] {path}: key={key}")

        # ---- zh-Hant ----
        if "zh-Hant" not in locs:
            errors.append(f"[Missing zh-Hant] {path}: {key}")
        else:
            hant_val, hant_state = get_value(locs["zh-Hant"])
            if hant_val is None or not hant_val.strip():
                errors.append(f"[Empty zh-Hant] {path}: {key}")
            elif hant_state != "translated":
                warnings.append(f"[Not translated zh-Hant] {path}: {key} state={hant_state}")
            else:
                # 明显简体泄漏：zh-Hant 出现简体特征字符。
                leaked = sorted({c for c in hant_val if c in SIMPLIFIED_INDICATORS})
                if leaked:
                    errors.append(
                        f"[zh-Hant simplified leak] {path}: key={key} value={hant_val[:40]} leaked={''.join(leaked)[:12]}"
                    )
                elif (
                    hant_val.strip() == key.strip()
                    and contains_han(key)
                    and any(c in SIMPLIFIED_INDICATORS for c in key)
                ):
                    # zh-Hant 完全等于简体源，且源含简体特征字 → 才算泄漏；
                    # 两岸同形的词（如 未知）不算。
                    errors.append(f"[zh-Hant equals source] {path}: key={key}")

        if extraction == "stale":
            msg = f"[Stale] {path}: {key}"
            if strict_stale:
                warnings.append(msg)
    return errors, warnings

# 目录级 / 文件级 allowlist：内部固定中文、不面向用户的文件（保持项目既有约定）。
HARDCODED_DIR_ALLOWLIST = ["TestSupport", "/Tests/"]
HARDCODED_FILE_ALLOWLIST = [
    "AgentTaskArchitecture.swift",
    "AgentToolkit",
    "AgentToolRegistry.swift",
    "SystemToolExecutor.swift",
    "RecommendationIndex",
]

def _source_files(roots):
    """Yield repository files without requiring ripgrep on CI runners."""
    for root in roots:
        path = pathlib.Path(root)
        if not path.exists():
            continue
        if path.is_file():
            yield path
            continue
        yield from (candidate for candidate in path.rglob("*") if candidate.is_file())


def _search_lines_with_rg(args):
    """Return rg output when available, otherwise let callers use Python fallback."""
    rg = shutil.which("rg")
    if not rg:
        return None
    result = subprocess.run([rg, *args], capture_output=True, text=True)
    return result.stdout


def check_hardcoded():
    """扫描用户可见硬编码中文（Swift 字符串字面量）。忽略：注释、log、协议/JSON key、
    通过 // i18n:ignore - <reason> 声明忽略的内部固定字符串。"""
    errors = []
    rg_output = _search_lines_with_rg(
        ["-n", "--pcre2",
         '"([^"\\\\]|\\\\.)*\\p{Han}([^"\\\\]|\\\\.)*"',
         "Apps", "Packages/AuralisCore/Sources",
         "--no-heading", "-g", "!*.xcstrings"]
    )
    if rg_output is not None:
        lines = rg_output.strip().splitlines() if rg_output else []
    else:
        # GitHub's macos-15 image does not guarantee rg. Keep the audit
        # hermetic by matching Swift string literals with the standard library.
        literal_re = re.compile(r'"([^"\\]|\\.)*"')
        lines = []
        for path in _source_files(["Apps", "Packages/AuralisCore/Sources"]):
            if path.suffix != ".swift":
                continue
            try:
                contents = path.read_text(encoding="utf-8").splitlines()
            except Exception:
                continue
            for lineno, content in enumerate(contents, 1):
                if any(contains_han(match.group()) for match in literal_re.finditer(content)):
                    lines.append(f"{path}:{lineno}:{content}")
    # 收集所在行可被识别的 i18n:ignore 注释（用 rg 单独抓取在文件名/行号层面处理）。
    ignore_spans = _collect_ignores()
    for line in lines:
        parts = line.split(":", 2)
        if len(parts) < 3:
            continue
        fpath, lineno, content = parts[0], int(parts[1]), parts[2]
        if any(x in fpath for x in HARDCODED_DIR_ALLOWLIST):
            continue
        if any(x in fpath for x in HARDCODED_FILE_ALLOWLIST):
            continue
        # 注释行
        if re.match(r'\s*//', content) or content.strip().startswith("///"):
            continue
        # 已通过 i18n:ignore 忽略的行（covers 前后 1 行）
        if ignore_spans.get(fpath, set()).intersection({lineno - 1, lineno, lineno + 1}):
            continue
        # 已包裹在 String(localized:) / LocalizedStringResource 中的内存字面量
        # 由 catalog 承载，不是硬编码——跳过（含同一行内出现 localize 的）。
        if "String(localized:" in content or "LocalizedStringResource" in content:
            continue
        errors.append(line)
    return errors

def _collect_ignores():
    """收集所有 `// i18n:ignore - <reason>` 覆盖的行号。
    行内 ignore 覆盖当前行 + 下一行；独立注释行的 block-ignore 一直延伸到空行/文件尾。"""
    spans = {}
    rg_output = _search_lines_with_rg(["-n", "i18n:ignore", "Apps", "Packages"])
    if rg_output is not None:
        lines = rg_output.strip().splitlines()
    else:
        lines = []
        for path in _source_files(["Apps", "Packages"]):
            try:
                contents = path.read_text(encoding="utf-8").splitlines()
            except Exception:
                continue
            lines.extend(
                f"{path}:{lineno}:{content}"
                for lineno, content in enumerate(contents, 1)
                if "i18n:ignore" in content
            )
    cache = {}
    for line in lines:
        parts = line.split(":", 2)
        if len(parts) < 3:
            continue
        fpath, lineno = parts[0], int(parts[1])
        comment = parts[2]
        contents = cache.get(fpath)
        if contents is None:
            try:
                contents = pathlib.Path(fpath).read_text(encoding="utf-8").splitlines()
            except Exception:
                contents = []
            cache[fpath] = contents
        # 独立注释行（前面只有空白）→ block ignore：延伸到空行为止
        if comment.strip().startswith("//"):
            idx = lineno  # 1-based
            end = idx + 1
            while end - 1 < len(contents) and contents[end - 1].strip() != "":
                end += 1
            spans.setdefault(fpath, set()).update(range(idx, end + 1))
        else:
            spans.setdefault(fpath, set()).update({lineno, lineno + 1})
    return spans

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--strict-stale", action="store_true")
    parser.add_argument("--hardcoded", action="store_true")
    args = parser.parse_args()

    xcstrings = [p for p in pathlib.Path(".").rglob("*.xcstrings")
                 if ".build" not in str(p) and "DerivedData" not in str(p)]
    all_errors, all_warnings = [], []
    for p in sorted(xcstrings):
        errs, warns = check_catalog(p, strict_stale=args.strict_stale)
        all_errors.extend(errs); all_warnings.extend(warns)
        if errs or warns:
            print(f"Checked {p}: {len(errs)} errors, {len(warns)} warnings")
        else:
            print(f"Checked {p}: OK ({len(json.loads(p.read_text()).get('strings', {}))} keys)")

    if args.hardcoded:
        hardcoded = check_hardcoded()
        if hardcoded:
            print(f"\n[Hardcoded UI] found {len(hardcoded)} candidates:")
            for l in hardcoded[:40]:
                print(f"  {l}")
            all_errors.extend(f"[Hardcoded] {l}" for l in hardcoded)
        else:
            print("\n[Hardcoded] no candidates")

    print("\n=== Summary ===")
    print(f"Catalogs checked: {len(xcstrings)}")
    print(f"Errors: {len(all_errors)}")
    # 聚合输出（去重按消息前缀）
    from collections import Counter
    cats = Counter()
    for e in all_errors:
        kind = e.split(":", 1)[0]
        print(f"  {e[:80]}")
    print(f"Warnings: {len(all_warnings)}")
    if all_errors:
        print("\nLocalization check FAILED")
        sys.exit(1)
    print("\nLocalization check PASSED")
    sys.exit(0)

if __name__ == "__main__":
    main()
