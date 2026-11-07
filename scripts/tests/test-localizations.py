#!/usr/bin/env python3
"""Exercise catalog validation and the compiled resources without audio or network."""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "compile-localizations.py"
spec = importlib.util.spec_from_file_location("talktalk_localizations", SCRIPT)
assert spec is not None and spec.loader is not None
compiler = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = compiler
spec.loader.exec_module(compiler)


def unit(value, state="translated"):
    return {"stringUnit": {"state": state, "value": value}}


def entry(key, english):
    return {"localizations": {"en": unit(english), "zh-Hans": unit(key)}}


class LocalizationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="tt-localizations-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.catalog = self.root / "Resources" / "Localizable.xcstrings"
        self.catalog.parent.mkdir()
        self.extracted = self.root / "extracted"
        self.extracted.mkdir()
        self.output = self.root / "bundle"
        self.source = self.root / "Sources" / "App" / "Fixture.swift"
        self.source.parent.mkdir(parents=True)
        self.source.write_text("// localization test fixture\n", encoding="utf-8")
        self.metadata([])

    def write_catalog(self, strings):
        self.catalog.write_text(json.dumps({"sourceLanguage": "zh-Hans", "strings": strings, "version": "1.0"},
                                           ensure_ascii=False), encoding="utf-8")

    def metadata(self, keys, source=None, filename="Fixture.stringsdata"):
        data = {"source": str(source or self.source), "tables": {"Localizable": [{"key": key} for key in keys]},
                "version": 1}
        (self.extracted / filename).write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")

    def compile(self):
        return compiler.compile_catalog(self.catalog, self.extracted, self.output)

    def table(self, language="en"):
        path = self.output / f"{language}.lproj" / "Localizable.strings"
        plutil = shutil.which("plutil")
        if plutil:
            result = subprocess.run([plutil, "-convert", "json", "-o", "-", str(path)],
                                    check=True, capture_output=True, text=True)
            return json.loads(result.stdout)
        # Keep ordinary format tests portable; macOS additionally parses with its
        # native plist reader, including the escaping case below.
        table = {}
        for line in path.read_text(encoding="utf-8").splitlines()[1:]:
            key, value = line.removesuffix(";").split(" = ", 1)
            table[json.loads(key)] = json.loads(value)
        return table

    def test_all_typed_aliases_and_both_languages(self):
        key = "已跳过 %@ 段"
        self.write_catalog({key: entry(key, "Skipped %@ segments")})
        self.metadata(["已跳过 %lld 段", "已跳过 %lf 段", "已跳过 %llu 段"])
        counts = self.compile()
        self.assertEqual(counts, {"en": 4, "zh-Hans": 4})
        english, chinese = self.table(), self.table("zh-Hans")
        for kind in ("@", "lld", "lf", "llu"):
            self.assertEqual(english[f"已跳过 %{kind} 段"], f"Skipped %{kind} segments")
            self.assertEqual(chinese[f"已跳过 %{kind} 段"], f"已跳过 %{kind} 段")

    def test_positional_translation_reorders_actual_argument_types(self):
        key = "从 %@ 到 %@"
        self.write_catalog({key: entry(key, "To %2$@ from %1$@")})
        self.metadata(["从 %@ 到 %lld"])
        self.compile()
        self.assertEqual(self.table()["从 %@ 到 %lld"], "To %2$lld from %1$@")
        self.assertEqual(self.table("zh-Hans")["从 %@ 到 %lld"], "从 %@ 到 %lld")

    def test_positional_source_keys_and_repeated_arguments(self):
        key = "值 %1$@ 再次 %1$@"
        self.write_catalog({key: entry(key, "Value %1$@, again %1$@")})
        self.metadata(["值 %1$lld 再次 %1$lld"])
        self.compile()
        self.assertEqual(self.table()["值 %1$lld 再次 %1$lld"], "Value %1$lld, again %1$lld")

    def test_literal_percent_and_escaped_percent(self):
        key = "进度 %@%"
        static = "恢复默认 85%"
        escaped = "完成 %@%%"
        self.write_catalog({key: entry(key, "Progress %@% (100% maximum)"),
                            static: entry(static, "Reset to default 85%"),
                            escaped: entry(escaped, "Done %@%%")})
        self.metadata(["进度 %lld%%", "完成 %lf%%", static])
        self.compile()
        self.assertEqual(self.table()["进度 %lld%%"], "Progress %lld%% (100%% maximum)")
        self.assertEqual(self.table()[static], "Reset to default 85%")
        self.assertEqual(self.table()["完成 %lf%%"], "Done %lf%%")

    def test_missing_language_untranslated_and_empty_values_fail_before_output(self):
        for mutation in ("missing", "state", "empty"):
            with self.subTest(mutation=mutation):
                data = entry("通用", "General")
                if mutation == "missing":
                    del data["localizations"]["en"]
                elif mutation == "state":
                    data["localizations"]["en"]["stringUnit"]["state"] = "new"
                else:
                    data["localizations"]["en"]["stringUnit"]["value"] = "  "
                self.write_catalog({"通用": data})
                with self.assertRaises(compiler.LocalizationError):
                    self.compile()
                self.assertFalse(self.output.exists())

    def test_missing_extra_or_wrong_type_placeholders_fail(self):
        for english in ("No placeholders", "One %@, extra %@", "Wrong type %lld"):
            with self.subTest(english=english):
                self.write_catalog({"数量 %@": entry("数量 %@", english)})
                with self.assertRaisesRegex(compiler.LocalizationError, "placeholder mismatch"):
                    self.compile()

    def test_invalid_positional_placeholders_fail(self):
        for english in ("Mixed %1$@ and %@", "Missing first %2$@", "Repeated %1$@ and %1$@"):
            with self.subTest(english=english):
                self.write_catalog({"从 %@ 到 %@": entry("从 %@ 到 %@", english)})
                with self.assertRaises(compiler.LocalizationError):
                    self.compile()

    def test_unknown_chinese_key_fails_but_ascii_can_fall_back(self):
        self.write_catalog({"通用": entry("通用", "General")})
        self.metadata(["Framework ASCII label", "通用"])
        self.compile()
        self.assertNotIn("Framework ASCII label", self.table())
        self.metadata(["缺少翻译"])
        with self.assertRaisesRegex(compiler.LocalizationError, "compiler key missing"):
            self.compile()

    def test_deleted_source_metadata_is_ignored(self):
        self.write_catalog({"通用": entry("通用", "General")})
        self.metadata(["通用"])
        self.metadata(["已删除源码的旧文案"], self.root / "Sources" / "Deleted.swift", "Deleted.stringsdata")
        self.compile()
        self.assertEqual(self.table(), {"通用": "General"})

    def test_all_source_files_need_metadata_even_empty_tables(self):
        self.write_catalog({"通用": entry("通用", "General")})
        extra = self.source.with_name("NoStrings.swift")
        extra.write_text("// intentionally no localized strings\n", encoding="utf-8")
        with self.assertRaisesRegex(compiler.LocalizationError, "NoStrings.swift"):
            self.compile()
        self.assertFalse(self.output.exists())
        self.metadata([], extra, "NoStrings.stringsdata")
        self.compile()
        self.assertEqual(self.table(), {"通用": "General"})

    def test_empty_extraction_does_not_silently_omit_typed_keys(self):
        self.write_catalog({"数量 %@": entry("数量 %@", "Count %@")})
        for path in self.extracted.iterdir():
            path.unlink()
        with self.assertRaisesRegex(compiler.LocalizationError, "missing compiler extraction"):
            self.compile()
        self.assertFalse(self.output.exists())

    def test_dev_only_canonical_entries_remain_without_compiler_key(self):
        self.write_catalog({"开发 %@": entry("开发 %@", "Development %@")})
        self.compile()
        self.assertEqual(self.table(), {"开发 %@": "Development %@"})

    def test_apple_plist_escaping_round_trips(self):
        if not shutil.which("plutil"):
            self.skipTest("native Apple plist parser is only available on macOS")
        key = '引号 "、换行\n、斜线\\'
        value = 'Quotes " \n tab\t backslash \\ literal \\u0001 control \x01 emoji 💬'
        self.write_catalog({key: entry(key, value)})
        self.compile()
        self.assertEqual(self.table(), {key: value})

    def test_validate_only_needs_no_extraction_or_output(self):
        self.write_catalog({"通用": entry("通用", "General")})
        result = subprocess.run([sys.executable, str(SCRIPT), "--catalog", str(self.catalog), "--validate-only"],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("catalog valid", result.stdout)
        self.assertFalse(self.output.exists())

    def test_compilation_is_deterministic(self):
        self.write_catalog({"乙": entry("乙", "B"), "甲": entry("甲", "A")})
        self.metadata(["乙", "甲", "甲"])
        self.compile()
        first = (self.output / "en.lproj" / "Localizable.strings").read_bytes()
        self.metadata(["甲", "乙"])
        self.compile()
        self.assertEqual(first, (self.output / "en.lproj" / "Localizable.strings").read_bytes())


if __name__ == "__main__":
    unittest.main()
