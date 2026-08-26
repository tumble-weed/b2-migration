#!/usr/bin/env python3
"""Produce a path+size census of a corpus tree.

The census is ~324 MB for 4M files, so it is gitignored -- regenerate it rather
than committing it. Used to size the transfer, pick test payloads, and build
--files-from lists.

Usage:
    ./bin/census.py --root /data/bigfiles/other/results-torchray \
        --out manifests/corpus_sizes.tsv
    ./bin/census.py --root ... --out ... --summary
"""

from __future__ import annotations

import argparse
import bisect
import logging
import os
from collections import defaultdict
from pathlib import Path
from typing import Dict, List, Tuple

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
logger = logging.getLogger("census")

BANDS: List[Tuple[int, str]] = [
    (1024, "<1 KB"),
    (10 * 1024, "1-10 KB"),
    (100 * 1024, "10-100 KB"),
    (1024 ** 2, "100 KB-1 MB"),
    (10 * 1024 ** 2, "1-10 MB"),
    (100 * 1024 ** 2, "10-100 MB"),
    (1 << 62, ">100 MB"),
]


def walk(root: Path, out: Path) -> int:
    """Write '<size>\\t<relpath>' per file. Does not follow symlinks."""
    out.parent.mkdir(parents=True, exist_ok=True)
    count = 0
    with open(out, "w") as fh:
        for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
            dirnames[:] = [d for d in dirnames
                           if not os.path.islink(os.path.join(dirpath, d))]
            for name in filenames:
                p = os.path.join(dirpath, name)
                if os.path.islink(p):
                    continue
                fh.write(f"{os.path.getsize(p)}\t{os.path.relpath(p, root)}\n")
                count += 1
    return count


def summarise(census: Path) -> None:
    sizes: List[int] = []
    by_top: Dict[str, List[int]] = defaultdict(lambda: [0, 0])
    with open(census, errors="replace") as fh:
        for line in fh:
            raw, _, path = line.rstrip("\n").partition("\t")
            if not raw.isdigit():
                continue
            size = int(raw)
            sizes.append(size)
            if path.startswith("./"):      # tolerate find-generated censuses
                path = path[2:]
            top = path.split("/")[0]
            by_top[top][0] += 1
            by_top[top][1] += size

    sizes.sort()
    total = sum(sizes)
    n = len(sizes)
    logger.info("files=%s bytes=%.1f GB mean=%.0f KB", f"{n:,}", total / 1e9,
                total / n / 1024 if n else 0)

    print("\nsize band       files       % count      bytes     % bytes")
    prev = 0
    for edge, label in BANDS:
        i = bisect.bisect_left(sizes, edge)
        cnt = i - prev
        b = sum(sizes[prev:i])
        print(f"{label:>13}  {cnt:>10,}  {100*cnt/n:9.1f}%  {b/1e9:8.2f} GB  {100*b/total:7.1f}%")
        prev = i

    print("\ntop 10 dirs by file count")
    for top in sorted(by_top, key=lambda k: -by_top[k][0])[:10]:
        cnt, b = by_top[top]
        print(f"  {cnt:>9,}  {b/1e9:7.2f} GB  mean {b/cnt/1024:8.1f} KB  {top}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--summary", action="store_true")
    ap.add_argument("--reuse", action="store_true",
                    help="skip the walk and summarise an existing census")
    args = ap.parse_args()

    if args.reuse:
        if not args.out.exists():
            raise SystemExit(f"--reuse given but {args.out} does not exist")
        logger.info("reusing %s", args.out)
    else:
        if not args.root.is_dir():
            raise SystemExit(f"--root is not a directory: {args.root}")
        count = walk(args.root, args.out)
        logger.info("wrote %s (%s files)", args.out, f"{count:,}")

    if args.summary:
        summarise(args.out)


if __name__ == "__main__":
    main()
