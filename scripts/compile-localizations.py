#!/usr/bin/env python3
"""Compile TalkTalk's bilingual catalog using Swift's actual interpolation types.

No Xcode tools or third-party packages are required. Swift's .stringsdata files supply
runtime keys such as %lld; the source scanner intentionally uses generic %@ keys.
"""
from __future__ import annotations

import argparse
from collections import Counter
from dataclasses import dataclass
import json
from pathlib import Path
import re
import sys

LANGUAGES = ("en", "zh-Hans")
# These are the Foundation format types emitted by Swift localization interpolation.
# No whitespace flags: ordinary prose such as "35% if idle" is not a format token.
SPECIFIER = re.compile(r"%(?:(?P<position>[1-9][0-9]*)\$)?(?P<type>@|(?:hh|ll|[hljztqL])?[diuoxXfFeEgGaAcCsSp])")
CJK = re.compile(r"[\u3400-\u9fff\uf900-\ufaff]")


class LocalizationError(ValueError):
    pass


@dataclass(frozen=True)
class Argument:
    index: int
    specifier: str
    positional: bool


@dataclass(frozen=True)
class Format:
    raw: str
    parts: tuple[str | Argument, ...]
    arguments: tuple[Argument, ...]

    @classmethod
    def parse(cls, raw: str) -> "Format":
        parts: list[str | Argument] = []
        arguments: list[Argument] = []
        start = i = 0
        while i < len(raw):
            if raw.startswith("%%", i):
                i += 2
                continue
            match = SPECIFIER.match(raw, i) if raw[i] == "%" else None
            if match is None:
                i += 1
                continue
            parts.append(raw[start:i])
            position = match.group("position")
            arg = Argument(int(position) if position else len(arguments) + 1,
                           match.group("type"), position is not None)
            parts.append(arg)
            arguments.append(arg)
            i = start = match.end()
        parts.append(raw[start:])
        if arguments:
            if len({arg.positional for arg in arguments}) != 1:
                raise LocalizationError(f"mixed positional and unnumbered placeholders: {raw!r}")
            indexes = {arg.index for arg in arguments}
            if indexes != set(range(1, max(indexes) + 1)):
                raise LocalizationError(f"noncontiguous placeholder positions: {raw!r}")
            types: dict[int, str] = {}
            for arg in arguments:
                if arg.index in types and types[arg.index] != arg.specifier:
                    raise LocalizationError(f"conflicting types for argument {arg.index}: {raw!r}")
                types[arg.index] = arg.specifier
        return cls(raw, tuple(parts), tuple(arguments))

    @property
    def normalized(self) -> tuple:
        # Swift escapes literal % to %% only for interpolated strings. Keep static
        # strings byte-for-byte distinct, including intentional consecutive % signs.
        return tuple(("argument", part.index) if isinstance(part, Argument)
                     else ("text", part.replace("%%", "%") if self.arguments else part)
                     for part in self.parts)

    @property
    def signature(self) -> Counter:
        return Counter((arg.index, arg.specifier) for arg in self.arguments)

    def retyped(self, runtime: "Format") -> str:
        if not self.arguments:
            return self.raw
        runtime_types = {arg.index: arg.specifier for arg in runtime.arguments}
        if Counter(arg.index for arg in self.arguments) != Counter(arg.index for arg in runtime.arguments):
            raise LocalizationError(f"placeholder positions do not match runtime key: {self.raw!r}")
        rendered = []
        for part in self.parts:
            if isinstance(part, str):
                rendered.append(part.replace("%%", "%").replace("%", "%%"))
            else:
                position = f"{part.index}$" if part.positional else ""
                rendered.append(f"%{position}{runtime_types[part.index]}")
        return "".join(rendered)


def read_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise LocalizationError(f"cannot read {path}: {error}") from error
    if not isinstance(value, dict):
        raise LocalizationError(f"expected an object in {path}")
    return value


def catalog_entries(path: Path) -> dict[str, dict[str, Format]]:
    catalog = read_json(path)
    if catalog.get("sourceLanguage") != "zh-Hans":
        raise LocalizationError("catalog sourceLanguage must be zh-Hans")
    strings = catalog.get("strings")
    if not isinstance(strings, dict) or not strings:
        raise LocalizationError("catalog must contain a nonempty strings object")
    entries = {}
    for key, entry in strings.items():
        source = Format.parse(key)
        localized = {}
        if not isinstance(entry, dict):
            raise LocalizationError(f"invalid catalog entry: {key!r}")
        for language in LANGUAGES:
            try:
                unit = entry["localizations"][language]["stringUnit"]
                value = unit["value"]
            except (KeyError, TypeError) as error:
                raise LocalizationError(f"missing {language} translation: {key!r}") from error
            if unit.get("state") != "translated" or not isinstance(value, str) or not value.strip():
                raise LocalizationError(f"unfinished or empty {language} translation: {key!r}")
            translated = Format.parse(value)
            if translated.signature != source.signature:
                raise LocalizationError(f"{language} placeholder mismatch: {key!r} -> {value!r}")
            localized[language] = translated
        entries[key] = localized
    return entries


def resolved_source(source: str, project: Path) -> Path | None:
    path = Path(source)
    candidates = [path] if path.is_absolute() else [project / path, path]
    return next((candidate.resolve() for candidate in candidates if candidate.is_file()), None)


def project_root(catalog: Path) -> Path:
    for parent in catalog.resolve().parents:
        if (parent / "Sources").is_dir():
            return parent
    raise LocalizationError(f"cannot find project Sources directory above {catalog}")


def runtime_keys(extracted: Path, project: Path):
    if not extracted.is_dir():
        raise LocalizationError(f"extraction directory is missing: {extracted}")
    covered: set[Path] = set()
    for path in sorted(extracted.rglob("*.stringsdata")):
        data = read_json(path)
        source = data.get("source")
        if not isinstance(source, str) or not source:
            raise LocalizationError(f"missing source path in {path}")
        # Incremental build metadata can retain entries from deleted source files.
        source_file = resolved_source(source, project)
        if source_file is None:
            continue
        covered.add(source_file)
        tables = data.get("tables")
        if not isinstance(tables, dict):
            raise LocalizationError(f"invalid tables in {path}")
        rows = tables.get("Localizable", [])
        if not isinstance(rows, list):
            raise LocalizationError(f"invalid Localizable table in {path}")
        for row in rows:
            if not isinstance(row, dict) or not isinstance(row.get("key"), str):
                raise LocalizationError(f"invalid localization key in {path}")
            yield row["key"], source
    expected = {path.resolve() for path in (project / "Sources").rglob("*.swift")}
    missing = sorted(str(path.relative_to(project)) for path in expected - covered)
    if missing:
        raise LocalizationError("missing compiler extraction metadata for: " + ", ".join(missing)
                                + "; rebuild all Swift sources with localization extraction enabled")


def strings_quote(value: str) -> str:
    # JSON quoting handles quotes, backslashes and the ordinary control characters.
    # OpenStep plist strings use \Uhhhh for Unicode escapes rather than JSON's \uhhhh.
    return re.sub(r"(?<!\\)((?:\\\\)*)\\u([0-9a-fA-F]{4})",
                  lambda match: match.group(1) + "\\U" + match.group(2),
                  json.dumps(value, ensure_ascii=False))


def compile_catalog(catalog: Path, extracted: Path, output: Path) -> dict[str, int]:
    entries = catalog_entries(catalog)
    by_normalized = {}
    output_tables: dict[str, dict[str, str]] = {language: {} for language in LANGUAGES}
    for key, translations in entries.items():
        source = Format.parse(key)
        if source.normalized in by_normalized:
            raise LocalizationError(f"ambiguous normalized catalog keys: {by_normalized[source.normalized]!r}, {key!r}")
        by_normalized[source.normalized] = key
        for language, value in translations.items():
            output_tables[language][key] = value.retyped(source)

    for key, source_path in runtime_keys(extracted, project_root(catalog)):
        runtime = Format.parse(key)
        canonical = by_normalized.get(runtime.normalized)
        if canonical is None:
            # Unmarked ASCII-only labels and framework strings retain native fallback.
            if CJK.search(key):
                raise LocalizationError(f"compiler key missing from catalog ({source_path}): {key!r}")
            continue
        for language, value in entries[canonical].items():
            translated = value.retyped(runtime)
            previous = output_tables[language].get(key)
            if previous is not None and previous != translated:
                raise LocalizationError(f"conflicting translations for runtime key {key!r}")
            output_tables[language][key] = translated

    # Validate everything before writing either language, so a failed build cannot
    # silently ship a partially populated bundle. Outputs are deterministic.
    for language, table in output_tables.items():
        destination = output / f"{language}.lproj" / "Localizable.strings"
        destination.parent.mkdir(parents=True, exist_ok=True)
        text = "/* Generated from Localizable.xcstrings and Swift localization metadata. */\n"
        text += "".join(f"{strings_quote(key)} = {strings_quote(value)};\n" for key, value in sorted(table.items()))
        destination.write_text(text, encoding="utf-8")
    return {language: len(table) for language, table in output_tables.items()}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", required=True, type=Path)
    parser.add_argument("--extracted", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--validate-only", action="store_true", help="validate catalog coverage and placeholders without compiling")
    args = parser.parse_args()
    if not args.validate_only and (args.extracted is None or args.output is None):
        parser.error("--extracted and --output are required unless --validate-only is used")
    try:
        if args.validate_only:
            entries = catalog_entries(args.catalog)
            print(f"compile-localizations: catalog valid ({len(entries)} keys, en and zh-Hans)")
            return 0
        counts = compile_catalog(args.catalog, args.extracted, args.output)
    except LocalizationError as error:
        print(f"compile-localizations: {error}", file=sys.stderr)
        return 1
    print("compile-localizations: " + ", ".join(f"{language}: {count} keys" for language, count in counts.items()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
