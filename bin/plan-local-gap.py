#!/usr/bin/env python3
"""Work out which local files Drive does NOT have, as an rclone --files-from list.

Input  a Drive sample-dir manifest from list-gdrive-samples.sh
Output a newline-separated list of paths relative to --src, ready for
       `rclone copy --files-from`

The comparison is at sample-dir granularity, which is what the manifest can
cheaply provide. A local sample dir absent from the manifest means Drive has
none of it, so every file under it must come from this box.

Accepted blind spot: a sample dir present on Drive but missing a file inside is
NOT detected here. 97.4% of sample dirs hold exactly one file, so this covers
almost everything; the final full sweep catches the rest.

Symlinks are skipped. The corpus has 212, all at method-dir level, and they
ride along on a plain `--links` copy rather than through --files-from.

Usage:
    ./bin/plan-local-gap.py \\
        --src /data/bigfiles/other/results-torchray \\
        --manifest manifests/gdrive_samples/vast-112_results-torchray_samples.txt \\
        --out manifests/local_gap.txt
    ./bin/plan-local-gap.py ... --summary
"""

from __future__ import annotations

import argparse
import logging
import os
from collections import defaultdict
from pathlib import Path
from typing import Dict, List, Set, Tuple

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
logger = logging.getLogger("gap")


def load_manifest(path: Path) -> Set[str]:
    """Sample-dir paths as written by list-gdrive-samples.sh: '<method>/<sample>'."""
    if not path.exists():
        raise SystemExit(f"manifest not found: {path}")
    out: Set[str] = set()
    with open(path, errors="replace") as fh:
        for line in fh:
            rel = line.strip().strip("/")
            if rel:
                out.add(rel)
    if not out:
        raise SystemExit(f"manifest is empty: {path} -- did the listing finish?")
    return out


def walk_local(src: Path) -> Tuple[List[Tuple[str, int]], int, int]:
    """Return (files, n_symlinks_skipped, n_sample_dirs).

    files is [(relpath, size)] for every regular file, symlinks excluded.
    """
    files: List[Tuple[str, int]] = []
    symlinks = 0
    sample_dirs = 0
    for dirpath, dirnames, filenames in os.walk(src, followlinks=False):
        keep = []
        for d in dirnames:
            if os.path.islink(os.path.join(dirpath, d)):
                symlinks += 1
            else:
                keep.append(d)
        dirnames[:] = keep
        rel_dir = os.path.relpath(dirpath, src)
        if rel_dir.count(os.sep) == 1:      # <method>/<sample>
            sample_dirs += 1
        for name in filenames:
            full = os.path.join(dirpath, name)
            if os.path.islink(full):
                symlinks += 1
                continue
            files.append((os.path.relpath(full, src), os.path.getsize(full)))
    return files, symlinks, sample_dirs


def sample_key(rel: str) -> str:
    """'<method>/<sample>' for a file path, or '' for anything shallower."""
    parts = rel.split("/")
    if len(parts) < 3:
        return ""
    return f"{parts[0]}/{parts[1]}"


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--src", required=True, type=Path)
    ap.add_argument("--manifest", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--summary", action="store_true",
                    help="also print a per-method-dir breakdown of the gap")
    args = ap.parse_args()

    if not args.src.is_dir():
        raise SystemExit(f"--src is not a directory: {args.src}")

    on_drive = load_manifest(args.manifest)
    logger.info("manifest: %s sample dirs on Drive", f"{len(on_drive):,}")

    files, symlinks, sample_dirs = walk_local(args.src)
    logger.info("local: %s files, %s sample dirs, %s symlinks skipped",
                f"{len(files):,}", f"{sample_dirs:,}", f"{symlinks:,}")

    gap: List[Tuple[str, int]] = []
    shallow = 0
    for rel, size in files:
        key = sample_key(rel)
        if not key:
            # Loose file directly under the corpus root or a method dir. The
            # manifest says nothing about these, so send them and let rclone's
            # own compare decide.
            shallow += 1
            gap.append((rel, size))
            continue
        if key not in on_drive:
            gap.append((rel, size))

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with open(args.out, "w") as fh:
        for rel, _ in gap:
            fh.write(rel + "\n")

    gap_bytes = sum(s for _, s in gap)
    all_bytes = sum(s for _, s in files)
    logger.info("")
    logger.info("GAP: %s files, %.2f GB  (%.1f%% of files, %.1f%% of bytes)",
                f"{len(gap):,}", gap_bytes / 1e9,
                100 * len(gap) / len(files) if files else 0,
                100 * gap_bytes / all_bytes if all_bytes else 0)
    logger.info("  of which %s are loose files above sample level", f"{shallow:,}")
    logger.info("wrote %s", args.out)
    logger.info("")
    logger.info("next:")
    logger.info("  ./bin/source-local-to-b2.sh --src %s --files-from %s",
                args.src, args.out)

    if args.summary:
        per: Dict[str, List[int]] = defaultdict(lambda: [0, 0])
        for rel, size in gap:
            top = rel.split("/")[0]
            per[top][0] += 1
            per[top][1] += size
        print(f"\n{'files':>10} {'GB':>8}  method dir")
        for k in sorted(per, key=lambda k: -per[k][1]):
            n, b = per[k]
            print(f"{n:>10,} {b/1e9:8.2f}  {k}")


if __name__ == "__main__":
    main()
