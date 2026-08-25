"""Rewrite absolute symlinks under results-torchray to relative form.

Dry-run by default. Pass --apply to mutate. Only touches links whose target
is an absolute path; relative links are left alone.
"""
import argparse
import logging
import os
import sys
from pathlib import Path

logging.basicConfig(level=logging.INFO, format="%(message)s")
logger = logging.getLogger(__name__)

ROOT = Path("/data/bigfiles/other/results-torchray")


def find_absolute_links(root: Path) -> list[tuple[Path, str, str]]:
    """Return (link_path, old_target, new_relative_target) for absolute links."""
    out: list[tuple[Path, str, str]] = []
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        for name in list(dirnames) + list(filenames):
            p = Path(dirpath) / name
            if not p.is_symlink():
                continue
            old = os.readlink(p)
            if not os.path.isabs(old):
                logger.info("SKIP (already relative): %s -> %s", p, old)
                continue
            new = os.path.relpath(old, start=str(p.parent))
            out.append((p, old, new))
        # do not descend into symlinked dirs
        dirnames[:] = [d for d in dirnames if not (Path(dirpath) / d).is_symlink()]
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    args = ap.parse_args()

    found = find_absolute_links(ROOT)
    logger.info("absolute symlinks found: %d", len(found))
    for p, old, new in found[:3]:
        logger.info("  %s\n    old: %s\n    new: %s", p, old, new)
    if len(found) > 3:
        logger.info("  ... (%d more, same shape)", len(found) - 3)

    # pre-check: every proposed relative target must resolve
    bad = [(p, new) for p, _old, new in found
           if not (p.parent / new).exists()]
    if bad:
        logger.error("PRE-CHECK FAILED, %d proposed targets do not resolve", len(bad))
        for p, new in bad[:5]:
            logger.error("  %s -> %s", p, new)
        sys.exit(1)
    logger.info("pre-check: all %d proposed relative targets resolve", len(found))

    if not args.apply:
        logger.info("DRY RUN — nothing written. re-run with --apply")
        return

    changed = 0
    for p, _old, new in found:
        tmp = p.with_name(p.name + ".relink.tmp")
        os.symlink(new, tmp)
        os.replace(tmp, p)  # atomic swap
        changed += 1
    logger.info("rewrote %d links", changed)

    still_bad = [p for p, _o, _n in found if not p.exists()]
    logger.info("post-check: %d of %d resolve", len(found) - len(still_bad), len(found))
    if still_bad:
        logger.error("POST-CHECK FAILED on %d links", len(still_bad))
        sys.exit(1)


if __name__ == "__main__":
    main()
