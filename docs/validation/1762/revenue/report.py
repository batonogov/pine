"""Deliberately buggy, offline participant seed for Pine issue #1762."""

import argparse
import csv
from decimal import Decimal
import json
import re


def read_rows(path):
    rows = []
    seen = {}
    with open(path, encoding="utf-8", newline="") as source:
        reader = csv.reader(source, strict=True)
        if next(reader, None) != ["event_id", "kind", "amount"]:
            raise ValueError("expected header event_id,kind,amount")
        for line, fields in enumerate(reader, 2):
            if len(fields) != 3:
                raise ValueError(f"record {line}: expected three fields")
            event_id, kind, amount = fields
            if not re.fullmatch(r"[A-Za-z0-9_-]{1,32}", event_id):
                raise ValueError(f"record {line}: invalid event_id")
            if kind not in ("sale", "refund"):
                raise ValueError(f"record {line}: invalid kind")
            if not re.fullmatch(r"[0-9]{1,9}\.[0-9]{2}", amount):
                raise ValueError(f"record {line}: invalid amount")
            value = (kind, Decimal(amount))
            if event_id in seen and seen[event_id] != value:
                raise ValueError(f"record {line}: conflicting event_id")
            seen[event_id] = value
            rows.append((event_id, kind, value[1]))
    return rows


def total(rows):
    return str(sum((float(amount) for _, kind, amount in rows if kind == "sale"), 0.0))


def main():
    parser = argparse.ArgumentParser(description="Report synthetic EUR events.")
    parser.add_argument("csv_path")
    args = parser.parse_args()
    try:
        result = total(read_rows(args.csv_path))
    except (OSError, UnicodeError, ValueError, csv.Error) as error:
        parser.error(str(error))
    print(json.dumps({"currency": "EUR", "total": result}, sort_keys=True, separators=(",", ":")))


if __name__ == "__main__":
    main()
