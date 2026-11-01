---
paths:
  - "Pine/Localizable.xcstrings"
  - "Pine/Strings.swift"
---

# Localization

- **Localizable.xcstrings** — never use `json.dump` or standard JSON serializers to write this file. Xcode uses non-standard formatting (`"key" : "value"` with a space before the colon). Reserializing the entire file creates thousands of lines of whitespace noise in diffs. Instead, insert new translations by reading the file as text and making targeted insertions preserving the existing format
- **Localization** — 9 languages supported (en, de, es, fr, ja, ko, pt-BR, ru, zh-Hans). All user-facing strings go through `Localizable.xcstrings`. To add a new language: add the language key to the xcstrings dict with translations for every existing key
