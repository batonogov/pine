"""Deliberately buggy, offline participant seed for Pine issue #1762 (ledger T1)."""

import argparse
import csv
import json
import re


def read_rows(path):
    rows = []
    with open(path, encoding="utf-8", newline="") as source:
        reader = csv.reader(source, strict=True)
        if next(reader, None) != ["shipment_id", "weight_kg"]:
            raise ValueError("expected header shipment_id,weight_kg")
        for line, fields in enumerate(reader, 2):
            if len(fields) != 2:
                raise ValueError(f"record {line}: expected two fields")
            shipment_id, weight = fields
            if not re.fullmatch(r"[A-Za-z0-9_-]{1,32}", shipment_id):
                raise ValueError(f"record {line}: invalid shipment_id")
            if not re.fullmatch(r"[0-9]{1,5}", weight):
                raise ValueError(f"record {line}: invalid weight_kg")
            value = int(weight)
            if not 1 <= value <= 99999:
                raise ValueError(f"record {line}: weight_kg out of range")
            rows.append((shipment_id, value))
    return rows


def aggregate(rows):
    seen = {}
    for shipment_id, weight in rows:
        if shipment_id not in seen:
            seen[shipment_id] = weight
    return sum(seen.values())


def main():
    parser = argparse.ArgumentParser(description="Sum synthetic shipment weights.")
    parser.add_argument("csv_path")
    args = parser.parse_args()
    try:
        total = aggregate(read_rows(args.csv_path))
    except (OSError, UnicodeError, ValueError, csv.Error) as error:
        parser.error(str(error))
    print(json.dumps({"total_kg": total}, separators=(",", ":")))


if __name__ == "__main__":
    main()
