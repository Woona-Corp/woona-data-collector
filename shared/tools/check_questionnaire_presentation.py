"""Check the native display catalogs against the shared RU/EN UI contract."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def native_catalog(path, block_pattern, pair_pattern):
    source = path.read_text()
    block = re.search(block_pattern, source, re.S)
    if block is None:
        raise ValueError(f"Questionnaire display catalog missing in {path.relative_to(ROOT)}")
    pairs = re.findall(pair_pattern, block.group(1))
    result = {}
    for raw_key, raw_value in pairs:
        key = json.loads('"' + raw_key.replace(r'\$', '$') + '"')
        value = json.loads('"' + raw_value.replace(r'\$', '$') + '"')
        if key in result:
            raise ValueError(f"Duplicate questionnaire display key in {path.relative_to(ROOT)}: {key}")
        result[key] = value
    return result


def main():
    expected = json.loads((ROOT / "shared/testdata/questionnaire-display-en.json").read_text())["translations"]
    quoted = r'"((?:\\.|[^"\\])*)"'
    android = native_catalog(
        ROOT / "android/app/src/main/java/com/example/myapplication/localization/QuestionnaireText.kt",
        r'questionnaireEnglishLabels:.*?linkedMapOf\((.*?)\n\)',
        quoted + r'\s+to\s+' + quoted,
    )
    ios = native_catalog(
        ROOT / "ios/Woona/AppShell/QuestionnaireViews.swift",
        r'englishQuestionnaireText:.*?=\s*\[(.*?)\n\]',
        quoted + r'\s*:\s*' + quoted,
    )
    for name, actual in (("Android", android), ("iOS", ios)):
        missing = sorted(set(expected) - set(actual))
        extra = sorted(set(actual) - set(expected))
        changed = sorted(key for key in set(expected) & set(actual) if expected[key] != actual[key])
        if missing or extra or changed:
            raise ValueError(f"{name} display catalog differs: missing={missing}, extra={extra}, changed={changed}")
    print(f"Questionnaire UI contract: {len(expected)} display translations match Android and iOS; canonical answers are not rewritten by this check.")


if __name__ == "__main__":
    main()
