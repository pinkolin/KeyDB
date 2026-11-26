#!/bin/bash
# Reproduce Snapchat/KeyDB#743 against a KeyDB image:
#   1. the expire counter drifts when keys with a TTL are overwritten while a
#      snapshot (KEYS / SCAN COUNT>=100) is alive, and the next BGSAVE dies on
#      rdb.cpp:1372 'ckeysExpired == db->expireSize()';
#   2. SET ... KEEPTTL drops the TTL in the same window.
# Prints a verdict line per check and exits 0 only if both are clean.
#   usage: repro_743.sh <image> [seconds]
set -u
IMG="$1"; SECS="${2:-25}"; N=200000
NAME="repro743-$$"
cli() { docker exec "$NAME" keydb-cli "$@"; }

docker rm -f "$NAME" >/dev/null 2>&1
docker run -d --name "$NAME" "$IMG" keydb-server --save "" --appendonly no \
  --active-replica yes --multi-master yes --protected-mode no >/dev/null
for _ in $(seq 1 50); do cli ping 2>/dev/null | grep -q PONG && break; sleep 0.2; done
echo "image: $IMG ($(cli info server | grep -o 'redis_version:[0-9.]*' | tr -d '\r'))"

# N keys with a TTL, plus 2000 KEEPTTL probes with a TTL, all created before any snapshot.
docker exec "$NAME" keydb-benchmark -q -n $((N*3)) -r $N SET k:__rand_int__ v EX 36000 >/dev/null
docker exec "$NAME" sh -c 'i=0; while [ $i -lt 2000 ]; do echo "SET kt:$i v EX 36000"; i=$((i+1)); done | keydb-cli >/dev/null'

# Keep snapshots alive (KEYS walks all keys asynchronously) while overwriting keys with a TTL.
docker exec -d "$NAME" sh -c "end=\$((\$(date +%s)+$SECS)); while [ \$(date +%s) -lt \$end ]; do keydb-cli KEYS 'zz*' >/dev/null; done"
docker exec -d "$NAME" sh -c "end=\$((\$(date +%s)+$SECS)); while [ \$(date +%s) -lt \$end ]; do keydb-cli SCAN 0 COUNT 1000 >/dev/null; done"
docker exec "$NAME" keydb-benchmark -q -c 8 -n 2000000 -r $N SET k:__rand_int__ v2 EX 36000 >/dev/null &
BENCH=$!
sleep 2
docker exec "$NAME" sh -c 'r=0; while [ $r -lt 20 ]; do i=0; while [ $i -lt 2000 ]; do echo "SET kt:$i v$r KEEPTTL"; i=$((i+1)); done | keydb-cli >/dev/null; r=$((r+1)); done'
sleep "$SECS"; kill $BENCH 2>/dev/null; wait 2>/dev/null

lost=$(docker exec "$NAME" sh -c 'i=0; while [ $i -lt 2000 ]; do echo "TTL kt:$i"; i=$((i+1)); done | keydb-cli' | grep -c '^-1$')
expires=$(cli info keyspace | grep -o 'expires=[0-9]*' | cut -d= -f2)
keys=$(cli dbsize)
echo "keys=$keys expires_counter=$expires keepttl_lost=$lost/2000"

cli bgsave >/dev/null
for _ in $(seq 1 100); do cli info persistence | grep -q 'rdb_bgsave_in_progress:0' && break; sleep 0.3; done
status=$(cli info persistence | grep -o 'rdb_last_bgsave_status:[a-z]*' | cut -d: -f2)
asserted=$(docker logs "$NAME" 2>&1 | grep -c "ckeysExpired == db->expireSize")
warned=$(docker logs "$NAME" 2>&1 | grep -c "expire counter mismatch")
docker rm -f "$NAME" >/dev/null

ok=0
if [ "$status" = ok ] && [ "$asserted" = 0 ]; then echo "BGSAVE: ok (mismatch warnings: $warned)"; else echo "BGSAVE: FAILED (status=$status, assertion lines=$asserted)"; ok=1; fi
if [ "$expires" = "$keys" ]; then echo "COUNTER: ok"; else echo "COUNTER: DRIFT (expires=$expires, keys with TTL=$keys)"; ok=1; fi
if [ "$lost" = 0 ]; then echo "KEEPTTL: ok"; else echo "KEEPTTL: LOST TTL on $lost keys"; ok=1; fi
exit $ok
