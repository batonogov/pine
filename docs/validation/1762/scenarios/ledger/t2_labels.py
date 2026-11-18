"""Deliberately buggy, offline participant seed for Pine issue #1762 (ledger T2)."""

import argparse
import csv
import json
import re


def read_rows(path):
    rows = []
    with open(path, encoding="utf-8", newline="") as source:
        reader = csv.reader(source, strict=True)
        if next(reader, None) != ["item_id", "label"]:
            raise ValueError("expected header item_id,label")
        for line, fields in enumerate(reader, 2):
            if len(fields) != 2:
                raise ValueError(f"record {line}: expected two fields")
            item_id, label = fields
            if not re.fullmatch(r"[A-Za-z0-9_-]{1,32}", item_id):
                raise ValueError(f"record {line}: invalid item_id")
            if not re.fullmatch(r"[A-Za-z0-9_-]{1,16}", label):
                raise ValueError(f"record {line}: invalid label")
            rows.append((item_id, label))
    return rows


def aggregate(rows):
    counts = {}
    for _, label in rows:
        label = label.lower()
        counts[label] = counts.get(label, 0) + 1
    return {label: counts[label] for label in sorted(counts)}


def main():
    parser = argparse.ArgumentParser(description="Count synthetic item labels.")
    parser.add_argument("csv_path")
    args = parser.parse_args()
    try:
        counts = aggregate(read_rows(args.csv_path))
    except (OSError, UnicodeError, ValueError, csv.Error) as error:
        parser.error(str(error))
    print(json.dumps({"labels": counts}, separators=(",", ":")))


if __name__ == "__main__":
    main()
