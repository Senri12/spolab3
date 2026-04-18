import argparse
import csv
from pathlib import Path


def read_rows(path: Path, limit: int | None) -> list[list[str]]:
    with path.open("r", encoding="utf-8-sig", newline="") as fh:
        reader = csv.reader(fh, delimiter=";")
        rows = list(reader)

    if not rows:
        return []

    header = rows[0]
    data = rows[1:]
    if limit is not None:
        data = data[:limit]
    return [header] + data


def to_int(value: str) -> int | None:
    value = value.strip().strip('"')
    if not value:
        return None
    try:
        return int(value)
    except ValueError:
        return None


def run_query(types_rows: list[list[str]], ved_rows: list[list[str]]) -> list[tuple[int | None, int | None]]:
    type_ids_lt_2: set[int] = set()
    for row in types_rows[1:]:
        if not row:
            continue
        type_id = to_int(row[0])
        if type_id is not None and type_id < 2:
            type_ids_lt_2.add(type_id)

    results: list[tuple[int | None, int | None]] = []
    for row in ved_rows[1:]:
        if len(row) <= 7:
            continue

        ved_id = to_int(row[0])
        chlvk_id = to_int(row[1])
        tv_id = to_int(row[7])

        if ved_id is None:
            continue

        if ved_id < 39921 and ved_id > 1250981:
            if tv_id in type_ids_lt_2:
                results.append((tv_id, chlvk_id))
            else:
                results.append((None, chlvk_id))

    return results


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--types-file", required=True)
    parser.add_argument("--ved-file", required=True)
    parser.add_argument("--limit", type=int, default=None)
    args = parser.parse_args()

    types_path = Path(args.types_file)
    ved_path = Path(args.ved_file)

    types_rows = read_rows(types_path, args.limit)
    ved_rows = read_rows(ved_path, args.limit)
    results = run_query(types_rows, ved_rows)

    print(f"types_data_rows={max(len(types_rows) - 1, 0)}")
    print(f"ved_data_rows={max(len(ved_rows) - 1, 0)}")
    print(f"result_count={len(results)}")

    if results:
        for type_id, chlvk_id in results[:20]:
            print(f"{type_id};{chlvk_id}")
    else:
        print("result_is_empty=true")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
