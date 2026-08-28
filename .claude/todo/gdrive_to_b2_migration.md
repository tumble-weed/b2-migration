# gdrive → Backblaze B2 migration (one-time backup)

**Design canvas:** `coding-practice/b2-migration/b2_migration.drawio`
**De-risk test:** `.claude/todo/b2_derisk_test.html` — the small paid experiment
that has to pass before this migration runs. Read it first.
**Status:** SUPERSEDED 2026-08-28. The architecture below was written before the
corpus was measured and is kept for the reasoning trail only. Current plan and
all measurements: `b2_derisk_test.html`.

## Scope (important)
This is **effort #2 only**: move results from Google Drive → B2 for backup.
It is **separate** from **effort #1** (consolidate files accidentally copied
to 2 gdrive locations). Do not mix them. If #1 (the A→B consolidation) is
unfinished when #2 reads gdrive, B2 will mirror whatever is there (dupes
included) — finish #1 first for a clean B2.

## Provider decision — Backblaze B2
**Prices verified against backblaze.com/cloud-storage/pricing on 2026-08-25.**
- $6.95/TB/mo pay-as-you-go ($0.00695/GB). First 10 GB free. India adds 18%
  GST → ~$8.20/TB effective. (Was $6/TB when this plan was first written.)
- Durability 11 nines; 99.9% uptime SLA; S3-compatible → no lock-in.
- Alternatives weighed: Cloudflare R2 ($15/TB, zero egress), Wasabi
  ($7.99/TB, 90-day min + 1:1 egress cap), S3 Glacier (archive-only, slow
  retrieval). B2 = cheapest *hot* storage for this use.

### Payment risk (India)
- B2 accepts Visa/MC/Amex debit+prepaid at the network level.
- Real risk = RBI intl-recurring rule: Indian banks auto-decline standing
  instructions to non-e-mandate foreign merchants → monthly charge can fail.
- De-risk: forex/USD card (Niyo/Fi/Wise) most reliable; else test with a
  tiny month and confirm the first AUTO-charge clears before moving TBs.
- No prepay escape: B2 is usage-billed; gift codes are for Computer Backup,
  not B2.

## Migration architecture — SUPERSEDED 2026-08-28

> **This section is obsolete. See `b2_derisk_test.html` §9d and §11.**
>
> It was written before the corpus was measured. Three facts overturned it:
>
> 1. The corpus is **3,939,217 directories**, one per sample, and Google Drive
>    has no recursive listing. The gdrive leg is bound by directory queries, not
>    bytes — measured at 3.3 objects/sec, i.e. **~14 days**.
> 2. Direct from the corpus box to B2 measured **25.6 objects/sec = ~44 hours**,
>    for about $16 of vast bandwidth. 7.7× faster.
> 3. The hand-built `delta.txt` below is unnecessary. Running the corpus box
>    against a B2 that already holds most files lets rclone compute the delta
>    itself; and where the two legs must not overlap, they walk one committed
>    directory list from opposite ends (`--reverse`).
>
> Also wrong below: Hetzner/VM1 was never used — the jump host is an existing
> DigitalOcean droplet in Bangalore — and the "Class A = $4.50/million ops"
> pricing was corrected earlier in this file.
>
> Kept for the reasoning trail, not as instructions.

### Original text

## Migration architecture — two parallel streams into B2
gdrive→B2 is NOT server-side (cross-provider); bytes route through a box.
The two streams hit **different bottlenecks** and cover **disjoint files**,
so they run in parallel with no contention and no dedupe step:

- **VM1** (cheap-bandwidth box, e.g. Hetzner): `gdrive → B2`
  — gdrive-API-bound (throttled by per-user quota).
- **vast instance**: only local files **not on gdrive** → B2
  — bandwidth-bound (vast charges ~$30/TB, so send only the delta).

## File listing — one pass serves delta + cost estimate
Capture path **and** size in a single listing:
```bash
rclone lsf -R --files-only --format "ps" --separator $'\t' gdrive: > gdrive.tsv
rclone lsf -R --files-only --format "ps" --separator $'\t' /local  > local.tsv
```
- **delta (not-on-gdrive):**
  ```bash
  comm -23 <(cut -f1 local.tsv | sort) <(cut -f1 gdrive.tsv | sort) > delta.txt
  rclone copy /local B2:bucket --files-from delta.txt
  ```
- **cost estimate:** from the size column → file count + Σ ceil(size/chunk).
- Optional `--format "psh"` adds hashes for later content checks.

## Cost model (B2 operations) — CORRECTED 2026-08-25
**API transactions are FREE.** The earlier "$4.50 / million Class A ops" in
this plan was wrong (that is S3 PUT pricing, not B2). Backblaze charges $0 for
Class A (upload/delete), Class B (download/HEAD) and Class C (list/copy) on
pay-as-you-go. Only Class D — webhook event notifications, which we never use —
is billed ($0.004/10k, first 2,500/day free).
- Consequence: the 4.05M-tiny-file corpus costs **$0 in ops**, uploaded or
  listed or downloaded. Multipart chunk counts are also free.
- The many-small-files problem is therefore **purely a latency problem**
  (4.05M round trips, rclone crawl), not a cost problem. Do not tar for cost.
- Storage ($6.95/TB/mo) is the only ongoing charge.

### Concrete bill (census figures, 2026-08-25)
`find -printf '%s'` census over results-torchray: 4,054,466 files, 586.9 GB.
The older 618 GB figure was `du --apparent-size`; trust the census.
```
results-torchray ............ 586.9 GB
results-with-detailed-info ... 16.0 GB   (the 211 symlinks point here)
                             ---------
                              602.9 GB

billable = 602.9 - 10 free = 592.9 GB
592.9 GB x $0.00695 = $4.12 / mo  =  $49.46 / yr
+18% GST            = $4.86 / mo  =  $58.36 / yr

upload 602.9 GB (B2 side) ... $0
4.05M upload ops ............ $0
free egress budget .......... 1,809 GB/mo   (3x stored)
full restore (B2 side) ...... $0
full restore (vast side) .... $16.28        (602.9 GB x $27/TB)
```
**One transfer through this machine costs 4x the entire annual B2 storage
bill.** Optimise the jump host, not any B2 line item.

## Throttle insight (applies to gdrive AND b2)
Throttle is **per-request**, not per-byte → many small files is the killer.
Optional optimization: `tar` per experiment dir → far fewer objects, faster
everywhere. Note: with B2 ops free, the *only* payoff is speed, not cost. Trade-off: B2 has no server-side untar, so a tar is
opaque (fetch+untar whole dir to read). Granularity choice:
per-file (browsable, many ops) · per-experiment tar (few ops) · one big tar.

## Restore cost (moving vast instances later)
- B2 egress: free up to 3× stored size/month, then $0.01/GB — usually ~$0.
- The expensive leg is the **new vast box's ingress bandwidth** ($30/TB),
  not B2. Restore selectively to a cheap-bandwidth box.

## Concurrency note
The existing gdrive removal job (tmux `t-rm-gdrive`) shares the same per-user
gdrive API quota as VM1's gdrive→B2 read. User will not run other gdrive jobs
during the backup, so VM1 gets the full quota.

## Open / next
- [ ] Confirm effort #1 (A→B consolidation) state before starting.
- [ ] Create B2 account + bucket; verify India payment (test month).
- [ ] Pick cheap-bandwidth box for VM1.
- [ ] Run the listing; compute delta + cost estimate.
- [ ] Execute both streams in parallel.
