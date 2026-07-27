#!/usr/bin/env python3
"""Insert new a11y.sidebar.disclosure/expand/collapse/folder.hint keys into
Localizable.xcstrings using targeted text insertion (NOT json.dump)."""

from pathlib import Path

XCSTRINGS = Path("Pine/Localizable.xcstrings")

# Anchor: the end of the a11y.sidebar.file.preview.action block, which is
# immediately followed by the a11y.paneDivider.label block.
ANCHOR = '    "a11y.paneDivider.label": {'

# Languages in the canonical order used throughout the file.
LANGS = ["de", "en", "es", "fr", "ja", "ko", "pt-BR", "ru", "zh-Hans"]

# (key, comment, {lang: value})
NEW_KEYS = [
    (
        "a11y.sidebar.disclosure.expanded",
        "VoiceOver value describing an expanded sidebar folder.",
        {
            "de": "ausgeklappt",
            "en": "expanded",
            "es": "expandido",
            "fr": "déplié",
            "ja": "展開済み",
            "ko": "펼침",
            "pt-BR": "expandido",
            "ru": "развёрнут",
            "zh-Hans": "已展开",
        },
    ),
    (
        "a11y.sidebar.disclosure.collapsed",
        "VoiceOver value describing a collapsed sidebar folder.",
        {
            "de": "eingeklappt",
            "en": "collapsed",
            "es": "colapsado",
            "fr": "replié",
            "ja": "折りたたみ済み",
            "ko": "접힘",
            "pt-BR": "recolhido",
            "ru": "свёрнут",
            "zh-Hans": "已折叠",
        },
    ),
    (
        "a11y.sidebar.folder.hint",
        "VoiceOver hint for a sidebar folder row explaining arrow-key behaviour.",
        {
            "de": "Ordner. Zum Ein- oder Ausklappen Links- oder Rechts-Taste drücken.",
            "en": "Folder. Press Left or Right arrow to collapse or expand.",
            "es": "Carpeta. Pulsa Izquierda o Derecha para colapsar o expandir.",
            "fr": "Dossier. Appuyez sur Flèche gauche ou droite pour replier ou déplier.",
            "ja": "フォルダ。展開または折りたたむには左矢印または右矢印を押してください。",
            "ko": "폴더입니다. 접거나 펼치려면 왼쪽 또는 오른쪽 화살표를 누르십시오.",
            "pt-BR": "Pasta. Pressione Esquerda ou Direita para recolher ou expandir.",
            "ru": "Папка. Нажмите стрелку влево или вправо, чтобы свернуть или развернуть.",
            "zh-Hans": "文件夹。按左箭头或右箭头可折叠或展开。",
        },
    ),
    (
        "a11y.sidebar.expand.action",
        "VoiceOver custom action that expands a collapsed sidebar folder.",
        {
            "de": "Ausklappen",
            "en": "Expand",
            "es": "Expandir",
            "fr": "Déplier",
            "ja": "展開",
            "ko": "펼치기",
            "pt-BR": "Expandir",
            "ru": "Развернуть",
            "zh-Hans": "展开",
        },
    ),
    (
        "a11y.sidebar.collapse.action",
        "VoiceOver custom action that collapses an expanded sidebar folder.",
        {
            "de": "Einklappen",
            "en": "Collapse",
            "es": "Colapsar",
            "fr": "Replier",
            "ja": "折りたたむ",
            "ko": "접기",
            "pt-BR": "Recolher",
            "ru": "Свернуть",
            "zh-Hans": "折叠",
        },
    ),
]


def build_block(key: str, comment: str, translations: dict[str, str]) -> str:
    lines = [
        f'    "{key}": {{',
        f'      "comment": "{comment}",',
        '      "extractionState": "manual",',
        '      "localizations": {',
    ]
    for lang in LANGS:
        value = translations[lang]
        lines.append(f'        "{lang}": {{')
        lines.append('          "stringUnit": {')
        lines.append('            "state": "translated",')
        lines.append(f'            "value": "{value}"')
        lines.append("          }")
        lines.append("        },")
    # Remove trailing comma from the last language entry.
    lines[-1] = "        }"
    lines.append("      }")
    lines.append("    },")
    return "\n".join(lines)


def main() -> None:
    text = XCSTRINGS.read_text(encoding="utf-8")
    assert ANCHOR in text, f"Anchor not found: {ANCHOR!r}"

    blocks = [build_block(key, comment, translations) for key, comment, translations in NEW_KEYS]
    insertion = "\n".join(blocks) + "\n"

    new_text = text.replace(ANCHOR, insertion + ANCHOR, 1)
    assert new_text != text, "Insertion did not modify the file"

    XCSTRINGS.write_text(new_text, encoding="utf-8")
    print(f"Inserted {len(NEW_KEYS)} keys before {ANCHOR!r}")


if __name__ == "__main__":
    main()
