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
./bin/jump-gdrive-to-b2.sh --dry-run       # see what it would do
./bin/jump-gdrive-to-b2.sh

# leg 2, on the corpus box, once leg 1 has finished
source ~/b2-secrets/b2env
./bin/source-local-to-b2.sh --src /data/bigfiles/other/results-torchray
./bin/source-local-to-b2.sh --src /data/bigfiles/other/results-with-detailed-info

# leg 3, on a fresh box
source ~/b2-secrets/b2env
./bin/verify-b2-restore.py --prefix results-torchray --dest ./scratch
```

Leg 1 is per-directory and resumable — a `.done` marker per directory in
`logs/jump/`, so a killed run picks up where it stopped.

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
