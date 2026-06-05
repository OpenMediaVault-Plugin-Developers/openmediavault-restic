# Restoring Data with Restic

You browse the snapshots stored in a repository, pick one, and restore it
into a shared folder. There is no need to drop to the command line.

## Restore Walkthrough (UI)

### 1. Open the repository's snapshots

- Navigate to **Services → Restic → Repositories**.
- Select the repository that holds the backup you want to restore.
- Click the **View snapshots** action (the list icon). This reads the live
  snapshot list directly from the repository (`restic snapshots`).

### 2. Pick the snapshot

The snapshot table shows, for each snapshot:

- **ID** — the snapshot identifier
- **Date / Time** — when it was taken (sorted newest first)
- **Hostname** — which host created it
- **Paths** — the source folders it contains
- **Tags**

Use the search field to narrow the list if needed, then select the snapshot you
want and click the **Restore** action (the circular-arrow / `mdi:restore` icon).

### 3. Fill in the restore form

| Field | What to enter |
|-------|---------------|
| **Snapshot ID** | Pre-filled and read-only — confirms what you're restoring. |
| **Restore target folder** | The shared folder the files will be written into. ⚠️ Existing files in the target may be overwritten. |
| **Path filter (optional)** | Restore only part of the snapshot, e.g. `/home/user/documents`. Leave blank to restore everything. |

### 4. Run it

Click **Save**. The restore runs as a background task
(`restic restore <id> --target <folder>`), and a progress dialog shows the live
output. Larger snapshots take a while; the repository lock is auto-retried for
up to 5 minutes (`--retry-lock 5m`) if the repo is busy.

When it finishes, the files appear in the target shared folder.

## Notes and Recommendations

- **Restore to a new/empty shared folder when you can.** Because existing files
  may be overwritten, restoring into a folder with live data is risky. Restore
  somewhere clean, verify the result, then move files into place.
- **Restic restores into the snapshot's original path structure** under the
  target. If the backup was `/srv/.../Documents`, that path tree is recreated
  inside the target folder rather than the bare files at the top level. Use the
  optional path filter, or run a small test restore first so you know what to
  expect.
- **The repository must be reachable** (correct passphrase / environment
  variables). These are loaded automatically from the per-repo and shared
  environment-variable files, so if backups work, restore will too.
