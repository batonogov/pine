"""Deliberately buggy, offline participant seed for Pine issue #1762 (ledger T3)."""

import argparse
import csv
import json
import re


def read_rows(path):
    rows = []
    with open(path, encoding="utf-8", newline="") as source:
        reader = csv.reader(source, strict=True)
        if next(reader, None) != ["sku", "units"]:
            raise ValueError("expected header sku,units")
        for line, fields in enumerate(reader, 2):
            if len(fields) != 2:
                raise ValueError(f"record {line}: expected two fields")
            sku, units = fields
            if not re.fullmatch(r"[A-Za-z0-9_-]{1,32}", sku):
                raise ValueError(f"record {line}: invalid sku")
            if not re.fullmatch(r"[0-9]{1,6}", units):
                raise ValueError(f"record {line}: invalid units")
            value = int(units)
            if value > 999999:
                raise ValueError(f"record {line}: units out of range")
            rows.append((sku, value))
    return rows


def aggregate(rows_a, rows_b):
    counts = {}
    for sku, units in rows_a:
        counts[sku] = units
    for sku, units in rows_b:
        counts[sku] = units
    return {sku: counts[sku] for sku in sorted(counts)}


def main():
    parser = argparse.ArgumentParser(description="Merge synthetic stock files.")
    parser.add_argument("first_csv")
    parser.add_argument("second_csv")
    args = parser.parse_args()
    try:
        stock = aggregate(read_rows(args.first_csv), read_rows(args.second_csv))
    except (OSError, UnicodeError, ValueError, csv.Error) as error:
        parser.error(str(error))
    print(json.dumps({"stock": stock}, separators=(",", ":")))


if __name__ == "__main__":
    main()
