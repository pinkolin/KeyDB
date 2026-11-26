# Ketska build of KeyDB 6.3.4

Branch `ketska-6.3.4` = upstream tag `v6.3.4` + fixes for Snapchat/KeyDB#743 (BGSAVE dying on
`rdb.cpp:1372 'ckeysExpired == db->expireSize()'`), which hit Ketska's EU node on 2026-11-26
(641 crashed saves in 70 min, then a deadlock). Upstream is unmaintained (last commit 2024-03).

| Commit | What | From |
|---|---|---|
| tombstone keys in snapshot overwrite | decrement the expire counter when `prepOverwriteForSnapshot` hides a snapshot key with a TTL — the root cause of the drift | connexcs/KeyDB 493cf60c |
| active-replica: ignore persistent expire sentinel | `KEYDB.MVCCRESTORE` stored `INVALID_EXPIRE` as a real TTL | SEObserver/KeyDB 653b8d69 |
| log instead of assert on the expire-count mismatch | the counter only feeds the RESIZEDB hint; a mismatch must not kill the save | Ketska |
| `SET … KEEPTTL` keeps the TTL while a snapshot is alive | skip `prepOverwriteForSnapshot` with KEEPTTL, so the old value (with its TTL) is overwritten, not shadowed | Ketska |

Image: `ghcr.io/pinkolin/keydb:6.3.4-ketska.2`, built by `.github/workflows/ketska-image.yml`
(`pkg/docker/Dockerfile.ketska`, no FLASH — Ketska does not use it). The workflow first runs
`tests/ketska/repro_743.sh` against upstream `eqalpha/keydb:x86_64_v6.3.4` (expected to fail) and the new
build (must pass), and pushes only then. Rollout plan: PLAN_KEYDB_FIX.md in the Ketska repo.

**ketska.1 was withdrawn** (2026-11-26): it also carried metabrainz 1c84b994 (free a non-null cached_master in
replicationCreateMasterClient). Its callers replicationCacheMasterUsingMaster/UsingMyself already freeClient()
the cached master without clearing the pointer, so on an active-replica node restarting with master info in its
RDB the client was freed twice; SG crashed 3x in 30 s and was rolled back. Reverted. CI now also runs
`tests/ketska/mesh_restart.sh` (three-node mesh, graceful and SIGKILL restarts under writes).
