# gdrive → Backblaze B2 migration (one-time backup)

**Design canvas:** `coding-practice/b2-migration/b2_migration.drawio`
**Status:** design converged; not yet executed.

## Scope (important)
This is **effort #2 only**: move results from Google Drive → B2 for backup.
It is **separate** from **effort #1** (consolidate files accidentally copied
to 2 gdrive locations). Do not mix them. If #1 (the A→B consolidation) is
unfinished when #2 reads gdrive, B2 will mirror whatever is there (dupes
included) — finish #1 first for a clean B2.

## Provider decision — Backblaze B2
- $6/TB/mo pay-as-you-go ($0.005/GB). India adds 18% GST → ~$7/TB effective.
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

## Cost model (B2 operations)
- Class A (writes) = $4.50 / million ops, billed on the **month's** op count
  (not lifetime, not recurring). One-time upload of N files = one-time charge.
- Multipart: large files upload in chunks; each chunk = 1 Class A op
  (10 GB @ 100 MB chunks ≈ 100 ops). File-count is a floor.
- Storage ($6/TB/mo) is the separate ongoing charge.

## Throttle insight (applies to gdrive AND b2)
Throttle is **per-request**, not per-byte → many small files is the killer.
Optional optimization: `tar` per experiment dir → far fewer objects, cheaper
ops, faster everywhere. Trade-off: B2 has no server-side untar, so a tar is
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
