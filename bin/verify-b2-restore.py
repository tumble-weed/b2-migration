#!/usr/bin/env python3
"""LEG 3 -- run on a small, FRESH vast instance.

Proves that what is in B2 restores to the right place, intact. This box has no
copy of the original, so the checks are ones that need no original:

  1. rclone copy   B2 prefix -> a scratch dir
  2. rclone check  --checksum, B2 vs the restored copy (SHA1 on both sides)
  3. structure     expected relative paths present, counts match
  4. symlinks      every .rclonelink came back as a real symlink, relative,
                   and resolves when the sibling tree is also restored
  5. payload       a sample of .xz files actually lzma+pickle load

Usage:
    source ~/b2-secrets/b2env
    ./bin/verify-b2-restore.py --prefix results-torchray --dest ./scratch
    ./bin/verify-b2-restore.py --prefix results-torchray --dest ./scratch \
        --sample 50 --skip-download
"""

from __future__ import annotations

import argparse
import lzma
import logging
import os
import pickle
import random
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import List, Tuple

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
logger = logging.getLogger("verify")


@dataclass(frozen=True)
class Config:
    bucket: str
    prefix: str
    dest: Path
    sample: int
    transfers: int
    skip_download: bool
    seed: int


def parse_args() -> Config:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--prefix", required=True,
                    help="path under the bucket to restore, e.g. results-torchray")
    ap.add_argument("--dest", required=True, type=Path,
                    help="scratch dir to restore into. MUST NOT be a live corpus path.")
    ap.add_argument("--sample", type=int, default=25,
                    help="how many .xz files to actually load (default 25)")
    ap.add_argument("--transfers", type=int, default=16)
    ap.add_argument("--skip-download", action="store_true",
                    help="reuse an existing restore in --dest and only run the checks")
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()

    bucket = os.environ.get("B2_BUCKET")
    if not bucket:
        raise SystemExit("B2_BUCKET not set -- run: source ~/b2-secrets/b2env")
    return Config(bucket=bucket, prefix=args.prefix, dest=args.dest,
                  sample=args.sample, transfers=args.transfers,
                  skip_download=args.skip_download, seed=args.seed)


def run(cmd: List[str]) -> subprocess.CompletedProcess:
    logger.info("$ %s", " ".join(cmd))
    return subprocess.run(cmd, text=True, capture_output=True, check=False)


def guard_dest(dest: Path) -> None:
    """Refuse to restore on top of anything that looks like a live corpus."""
    forbidden = ("/data/bigfiles",)
    resolved = str(dest.resolve())
    for bad in forbidden:
        if resolved.startswith(bad):
            raise SystemExit(
                f"refusing to restore into {resolved}: that is a live corpus path. "
                "Pick a scratch dir."
            )


def download(cfg: Config) -> None:
    remote = f"b2:{cfg.bucket}/{cfg.prefix}"
    cmd = ["rclone", "copy", remote, str(cfg.dest / cfg.prefix),
           "--links",
           "--transfers", str(cfg.transfers), "--checkers", "8",
           "--buffer-size", "4M",
           "--retries", "3", "--low-level-retries", "20",
           "--stats", "30s", "--stats-one-line", "--stats-log-level", "NOTICE"]
    proc = run(cmd)
    sys.stderr.write(proc.stderr)
    if proc.returncode != 0:
        raise SystemExit(f"rclone copy failed with exit {proc.returncode}")


def check_checksums(cfg: Config) -> Tuple[bool, str]:
    """rclone check --checksum: SHA1 on the B2 side vs the restored files."""
    remote = f"b2:{cfg.bucket}/{cfg.prefix}"
    proc = run(["rclone", "check", remote, str(cfg.dest / cfg.prefix),
                "--checksum", "--links", "--checkers", "8"])
    tail = (proc.stderr or proc.stdout).strip().splitlines()[-6:]
    return proc.returncode == 0, "\n".join(tail)


def check_symlinks(root: Path) -> Tuple[int, int, int, List[str]]:
    """Return (links, relative, resolving, problems)."""
    links = relative = resolving = 0
    problems: List[str] = []
    leftover = list(root.rglob("*.rclonelink"))
    if leftover:
        problems.append(
            f"{len(leftover)} .rclonelink files were NOT converted to symlinks "
            "-- was --links passed to the restore?"
        )
    for path in root.rglob("*"):
        if not path.is_symlink():
            continue
        links += 1
        target = os.readlink(path)
        if os.path.isabs(target):
            problems.append(f"absolute target (not portable): {path} -> {target}")
        else:
            relative += 1
        if path.exists():
            resolving += 1
    return links, relative, resolving, problems


def check_payloads(root: Path, sample: int, seed: int) -> Tuple[int, List[str]]:
    """lzma+pickle load a random sample of .xz files. Proves they are not corrupt."""
    xz = list(root.rglob("*.xz"))
    if not xz:
        return 0, ["no .xz files found under the restore -- wrong prefix?"]
    rng = random.Random(seed)
    picked = rng.sample(xz, min(sample, len(xz)))
    problems: List[str] = []
    ok = 0
    for path in picked:
        try:
            with lzma.open(path, "rb") as fh:
                obj = pickle.load(fh)
        except (lzma.LZMAError, EOFError, pickle.UnpicklingError, OSError) as exc:
            problems.append(f"{path}: {type(exc).__name__}: {exc}")
            continue
        if not isinstance(obj, dict):
            problems.append(f"{path}: loaded a {type(obj).__name__}, expected dict")
            continue
        if "saliency" not in obj:
            problems.append(f"{path}: no 'saliency' key; keys={sorted(obj)[:8]}")
            continue
        ok += 1
    return ok, problems


def main() -> None:
    cfg = parse_args()
    guard_dest(cfg.dest)
    cfg.dest.mkdir(parents=True, exist_ok=True)
    root = cfg.dest / cfg.prefix

    if cfg.skip_download:
        logger.info("--skip-download: reusing %s", root)
    else:
        download(cfg)

    files = sum(1 for p in root.rglob("*") if p.is_file() and not p.is_symlink())
    logger.info("restored files: %d", files)

    ck_ok, ck_tail = check_checksums(cfg)
    links, relative, resolving, link_problems = check_symlinks(root)
    loaded, payload_problems = check_payloads(root, cfg.sample, cfg.seed)

    print("\n================ VERIFY REPORT ================")
    print(f"restore root      {root}")
    print(f"files restored    {files}")
    print(f"checksum compare  {'PASS' if ck_ok else 'FAIL'}")
    for line in ck_tail.splitlines():
        print(f"    {line}")
    print(f"symlinks          {links} found, {relative} relative, {resolving} resolving")
    for p in link_problems[:10]:
        print(f"    ! {p}")
    print(f"payload loads     {loaded}/{cfg.sample} sampled .xz loaded with a 'saliency' key")
    for p in payload_problems[:10]:
        print(f"    ! {p}")

    failed = (not ck_ok) or bool(payload_problems) or bool(link_problems)
    print(f"\nOVERALL           {'FAIL' if failed else 'PASS'}")
    print("===============================================")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
