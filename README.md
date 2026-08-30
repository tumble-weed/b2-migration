# b2-migration

Move a ~600 GB / 4M-object saliency-results corpus from Google Drive to
Backblaze B2, then prove the restore works.

Three roles, three machines, one repo. Nothing in this repo is secret —
credentials live in a separate **private** repo (`b2-secrets`) that
`bin/bootstrap.sh` clones.

| role | machine | script |
|---|---|---|
| leg 1 — gdrive → B2 | DigitalOcean droplet, Bangalore, $6 tier | `bin/jump-gdrive-to-b2.sh` |
| leg 2 — local → B2 | the vast box that holds the corpus | `bin/source-local-to-b2.sh` |
| leg 3 — verify | a small, **fresh** vast box | `bin/verify-b2-restore.py` |

Why a jump host: rclone cannot server-side copy between Google Drive and B2, so
the bytes flow through whichever machine runs it. The vast box charges for
bandwidth in both directions; the droplet's inbound is free and its outbound is
about $0.01/GiB after a small included allowance.

## Setup, on any box

```bash
git clone https://github.com/tumble-weed/b2-migration
cd b2-migration
./bin/bootstrap.sh          # installs rclone + gh, gh auth login (device code),
                            # clones the private secrets repo
source ~/b2-secrets/b2env
```

On a box that only restores from B2 — a verify instance — skip the Drive check
entirely; it has no business touching Drive:

```bash
./bin/bootstrap.sh --no-gdrive
```

Works as root without `sudo` installed, which is the usual vast container.

`bootstrap.sh` uses GitHub's **device-code** login: you type a short code on your
own machine. Never copy a long-lived PAT onto a throwaway box.

### The secrets repo

`b2-secrets` is private and holds one file, `b2env`:

```bash
export RCLONE_CONFIG_B2_TYPE=b2
export RCLONE_CONFIG_B2_ACCOUNT=<keyID>
export RCLONE_CONFIG_B2_KEY=<applicationKey>

export RCLONE_CONFIG_GD_TYPE=drive
export RCLONE_CONFIG_GD_SCOPE=drive.readonly
export RCLONE_CONFIG_GD_TOKEN='{"access_token":"...","refresh_token":"..."}'
export RCLONE_CONFIG_GD_ROOT_FOLDER_ID=<root_folder_id>

export B2_BUCKET=<bucket>
export GD_SUBPATH=          # optional, usually empty
```

rclone reads remotes straight from `RCLONE_CONFIG_*` env vars, so **no
`rclone.conf` is ever written**. Use a *separate B2 key per machine* so one can
be revoked without touching the others, and give the droplet's key
`listBuckets,listFiles,readFiles,writeFiles` — **not** `deleteFiles`, so a
runaway sync cannot destroy the archive.

Get the Drive token on your own machine, minted **read-only**:

```bash
rclone authorize "drive" --drive-scope=drive.readonly
```

`RCLONE_CONFIG_GD_ROOT_FOLDER_ID` is the env equivalent of `root_folder_id` in
`rclone.conf` — the corpus box already has it, which is why no path variable was
ever needed by hand:

```bash
grep root_folder_id ~/.config/rclone/rclone.conf
```

It is a folder id, not a secret. `GD_SUBPATH` stays empty unless the corpus sits
in a subfolder of that anchored root.

It is deliberately **not** a git submodule: rotating a key should be one commit
in `b2-secrets`, with no pointer to bump here.

## The source is required, and the Drive root is refused

`gd:` is anchored at the **Drive root**, which holds ~200 unrelated folders —
resumes, course downloads, Takeout. There is deliberately no default source, and
`""`, `/`, `.` are refused outright, so no invocation can sweep the whole Drive.

Measured Drive layout (2026-08-27):

| Drive path | subdirs | status |
|---|---|---|
| `vast-112/results-torchray` | 601 | live — what `upload_bigfiles_other_` writes |
| `results-torchray` | 393 | older partial copy; its uploader is commented out |
| `vast-112/metrics-torchray` | 20 | live |
| `metrics-torchray` | 0 | empty |
| `results-with-detailed-info` | — | **not on Drive at all**, leg 2 only |

Presets carry those paths and drop the `vast-112/` prefix, so B2 mirrors the
*local* layout — the same paths leg 2 writes to.

| preset | Drive | B2 |
|---|---|---|
| `all` | `vast-112` (everything) | bucket root |
| `derisk` | `.../cifar-10-grad_cam-vgg16` | `_derisk/results-torchray/cifar-10-grad_cam-vgg16` |
| `derisk-live` | `.../cifar-10-gradient-vgg16` | `results-torchray/cifar-10-gradient-vgg16` |
| `results` | `vast-112/results-torchray` | `results-torchray` |
| `metrics` | `vast-112/metrics-torchray` | `metrics-torchray` |

`all` is the one that matches what the `vast-utils` aliases actually upload.
`results` and `metrics` are only 2 of the 9 directories under `vast-112`:

```
condaenvs/          <- gpnnenv2, a whole conda env
dataset/
evaluate-saliency-4/
metrics-torchray/
myhelp/
results-torchray/
todo/
todo2/
vast-utils/
instance_info.sh    <- loose file at that level
```

The `vast-112/` prefix is stripped on the B2 side either way, so the archive
mirrors the local layout and matches what leg 2 writes.

`derisk` writes under `_derisk/` so test data can be dropped wholesale.

`derisk-live` is the same 10,000-tiny-object shape but a **different** directory
— so Drive's listing for it is still cold and the timing is comparable — and it
writes to the **final** destination, so the bytes count as real migration
progress rather than being thrown away. Safe, because it is a genuine corpus
directory rather than synthetic data.

## Tuning: the two caps that made the first run take 1h51m

Measured on the droplet: 10,000 objects in **1h51m24s = 1.5 objects/sec**, which
extrapolates to ~31 days for the 4.05M-object corpus. Neither bandwidth nor B2
was the constraint. Two independent per-second caps were:

| cap | value | whose |
|---|---|---|
| `--drive-pacer-min-sleep` | 100ms → 10 Drive req/sec, ignores `--tpslimit` | rclone's own default |
| `--tpslimit` | 12 calls/sec total | set here, to avoid 403 storms |

Each object needs roughly three calls: list its sample dir, GET from Drive, PUT
to B2. Per-object round trip to B2 `us-east-005` measured at ~400ms, so latency
also needs concurrency to hide — which those caps prevented.

All four knobs are flags now, defaults unchanged, and the chosen tuning is
echoed at startup so a logged run records what produced its timing:

```bash
./bin/jump-gdrive-to-b2.sh --preset derisk-live \
    --pacer 10ms --tpslimit 100 --transfers 32 --checkers 32
```

Raising them risks Drive 403 rate-limit responses; rclone retries those, so the
failure mode is slowdown rather than data loss.

## Google Drive is read-only

Two independent guards:

1. The **token** is minted read-only (`--drive-scope=drive.readonly` at
   authorize time). Setting `scope=` in config does *not* reduce an
   already-granted token's permissions — only the grant does.
2. Every script uses `rclone copy`, never `sync`.

Drive stays a reference copy.

## Running it

```bash
# leg 1, on the droplet — run under tmux, it takes hours
tmux new -s jump
source ~/b2-secrets/b2env
./bin/jump-gdrive-to-b2.sh --preset derisk --dry-run   # small, real subtree
./bin/jump-gdrive-to-b2.sh --preset derisk             # 10,000 tiny objects
./bin/jump-gdrive-to-b2.sh --preset results            # the 601-dir corpus
./bin/jump-gdrive-to-b2.sh --preset metrics

# leg 2, on the corpus box, once leg 1 has finished
source ~/b2-secrets/b2env
./bin/source-local-to-b2.sh --src /data/bigfiles/other/results-torchray
./bin/source-local-to-b2.sh --src /data/bigfiles/other/results-with-detailed-info

# leg 3, on a fresh box -- presets, nothing to remember
source ~/b2-secrets/b2env
./bin/verify-b2-restore.py --preset derisk
./bin/verify-b2-restore.py --preset results
./bin/verify-b2-restore.py --preset metrics
```

`verify-b2-restore.py` takes the same preset names as the jump script, and
defaults `--dest` to `./scratch`. It needs **no torch**: full lzma
decompression is the mandatory integrity check (xz carries a CRC over the
whole stream), and unpickling is best-effort — skipped, not failed, when
`torch` is absent, which it will be on a bare verify box.

If the checksum step reports "N files missing" locally, an upload is still in
flight — B2 has more objects than were downloaded. Re-run once leg 1 prints
`[jump] done`.

Leg 1 is per-directory. Resume markers are **opt-in** (`--use-markers`), not the
default: both `a-on-drive` and the local corpus keep growing as experiments run,
so marking a directory "done" would permanently skip files added to it later.
Without the flag every run re-checks every directory and rclone skips whatever
B2 already has. Leg 2 has no markers at all — re-listing a local filesystem is
cheap, so there is nothing to trade.

## Running both legs at once

Leg 1 is bound by Drive **directory** queries, not bytes: the corpus is one
directory per sample, 3,939,217 of them, and descending into all of them runs at
roughly 4/sec — days. So leg 2 should not sit idle waiting for it. But leg 2
must not re-send files leg 1 will fetch from Drive for free either.

The cheap way to know what Drive has:

```bash
# on the droplet -- ~8 hours, resumable, negligible bytes
./bin/list-gdrive-samples.sh
#   -> manifests/gdrive_samples/..._samples.txt

# on the corpus box -- seconds
./bin/plan-local-gap.py \
    --src /data/bigfiles/other/results-torchray \
    --manifest manifests/gdrive_samples/vast-112_results-torchray_samples.txt \
    --out manifests/local_gap.txt --summary

# upload only the gap, while leg 1 is still running
./bin/source-local-to-b2.sh \
    --src /data/bigfiles/other/results-torchray \
    --files-from manifests/local_gap.txt
```

Why depth 2 rather than a full listing: listing one level inside each method dir
is **paged** (1,000 entries per call), measured at ~130 dirs/sec versus ~4/sec
for descending. ~8 hours instead of ~11 days.

**Accepted blind spot.** The manifest proves a sample *directory* exists on
Drive, not that every file inside it does. 97.4% of sample dirs hold exactly one
file, so dir-presence is file-presence for almost all of the corpus. The residue
(103,062 dirs with 2+ files) is caught by a final full sweep once leg 1
finishes — cheap by then, because B2 already holds nearly everything:

```bash
./bin/source-local-to-b2.sh --src /data/bigfiles/other/results-torchray
```

Symlinks are excluded from the gap list. All 212 sit at method-dir level and
ride along on the plain `--links` sweep.

## Both legs at once: meet in the middle

The corpus box is ~7.7x faster than the droplet (25.6 vs 3.3 objects/sec), so it
must take the bulk. Giving it only the dirs Drive lacks would finish in under an
hour and then idle for two weeks — exactly backwards.

Instead both legs walk the **same** 613-dir list from opposite ends:

```bash
# droplet, A -> Z
./bin/jump-gdrive-to-b2.sh --preset results \
    --dirs-from manifests/all_dirs.txt \
    --pacer 10ms --tpslimit 100 --transfers 32 --checkers 32

# corpus box, Z -> A
./bin/source-local-to-b2.sh \
    --src /data/bigfiles/other/results-torchray \
    --dirs-from manifests/all_dirs.txt --reverse --transfers 64
```

They meet wherever their speeds put them — the fast leg naturally covers ~90%,
with no coordination and no partition to compute. Overlap is one directory at
the meeting point.

**Better: drop `--dirs-from` and let each leg list its own source.** The
committed `manifests/all_dirs.txt` was generated from *local disk*, so handing
it to the droplet would make the droplet skip anything that exists only on
Drive. With `--reverse` alone, the droplet lists Drive and the corpus box lists
disk — each covers its own inventory in full, and the opposing order still keeps
them off the same directory:

```bash
# droplet, Drive's own listing, A -> Z
./bin/jump-gdrive-to-b2.sh --preset results \
    --pacer 10ms --tpslimit 100 --transfers 32 --checkers 32

# corpus box, its own listing, Z -> A
./bin/source-local-to-b2.sh \
    --src /data/bigfiles/other/results-torchray \
    --reverse --transfers 64
```

Safe because there is **no locking anywhere**, and none is needed: B2 object PUTs
are atomic and both legs write identical bytes. A duplicated object just leaves a
superseded version, purged by the 1-day lifecycle rule. The cost of a collision
is wasted bandwidth, never a bad file.

`manifests/local_only_dirs.txt` (13 dirs Drive does not have at all) is still
committed, as the one slice the droplet provably cannot supply.

## Design notes

- **No `--fast-list`.** rclone holds roughly 1 KB per object, so a whole-corpus
  listing wants GBs of RAM — impossible on a 1 GiB droplet. B2 charges nothing
  for list calls, so batching them saves nothing. Sync per directory instead.
- **`--links`, not `--copy-links`.** Symlinks are recorded as tiny
  `.rclonelink` files and recreated on download. The corpus links are relative
  and point at a sibling tree, so **both trees must be restored under the same
  parent** or they dangle.
- **Compare on size + mtime** (rclone's default), matching the existing
  box → Drive flow. `--checksum` was considered and not adopted.
- **No tarring.** Bundling small files would mean one changed file forces a
  whole-tar re-upload and re-download. Results are actively re-written, so
  incremental sync is the thing that must not be traded away.
- **B2 versioning cannot be disabled.** Overwrites always create a version and
  superseded versions bill storage. Set the bucket lifecycle once:
  ```bash
  rclone backend lifecycle b2:$B2_BUCKET -o daysFromHidingToDeleting=1
  rclone backend cleanup-hidden b2:$B2_BUCKET     # manual sweep, any time
  ```
  That needs `writeBuckets`, so do it once with the master key, then use the
  scoped key for everything else.
- **B2's region is fixed at account creation** and cannot be changed. One
  account, one region.
- **Restores go to a scratch dir.** `verify-b2-restore.py` refuses to write
  under `/data/bigfiles` for exactly this reason.

## Plans

- `.claude/todo/b2_derisk_test.html` — the de-risk experiment: payloads, timed
  legs, pass/fail checks, verified pricing.
- `.claude/todo/gdrive_to_b2_migration.md` — the migration architecture.
- `b2_migration.drawio` — design canvas.
