#!/bin/bash
# Three active-replica multi-master nodes (like Ketska's regions), writes on all
# of them, then restart one node twice (graceful, then SIGKILL) while writes
# continue. The restarted node loads an RDB that carries the other masters' info
# — the path where the first ketska.1 build double-freed its cached masters and
# crashed (SG, 2026-11-26). Passes only if no node crashed and all converge.
#   usage: mesh_restart.sh <image> [seconds]
set -u
IMG="$1"; SECS="${2:-20}"; NET="mesh$$"
n() { echo "mesh$$-$1"; }
cli() { docker exec "$(n "$1")" keydb-cli "${@:2}"; }
docker network create "$NET" >/dev/null
for i in 1 2 3; do
  peers=""; for j in 1 2 3; do [ $j = $i ] || peers="$peers --replicaof $(n $j) 6379"; done
  docker run -d --name "$(n $i)" --network "$NET" "$IMG" keydb-server --protected-mode no \
    --active-replica yes --multi-master yes --save 60 1 --appendonly no $peers >/dev/null
done
sleep 5
echo "image: $IMG"
for i in 1 2 3; do
  docker exec -d "$(n $i)" keydb-benchmark -q -c 4 -n 100000000 -r 50000 SET n$i:__rand_int__ v EX 36000
  docker exec -d "$(n $i)" keydb-benchmark -q -c 2 -n 100000000 -r 50000 HSET h$i:__rand_int__ f v
done
sleep "$SECS"
echo "restart node 3 (graceful)"; docker restart -t 10 "$(n 3)" >/dev/null; sleep "$SECS"
docker exec -d "$(n 3)" keydb-benchmark -q -c 4 -n 100000000 -r 50000 SET n3:__rand_int__ v EX 36000
echo "restart node 3 (SIGKILL)"; docker kill -s KILL "$(n 3)" >/dev/null; docker start "$(n 3)" >/dev/null; sleep "$SECS"
docker exec -d "$(n 3)" keydb-benchmark -q -c 4 -n 100000000 -r 50000 SET n3:__rand_int__ v EX 36000
echo "restart node 1 (graceful)"; docker restart -t 10 "$(n 1)" >/dev/null; sleep "$SECS"
for i in 1 2 3; do docker exec "$(n $i)" pkill keydb-benchmark 2>/dev/null; done
sleep 8
ok=0
for i in 1 2 3; do
  crashes=$(docker logs "$(n $i)" 2>&1 | grep -cE "crashed by signal|ASSERTION FAILED")
  restarts=$(docker inspect -f '{{.RestartCount}}' "$(n $i)")
  keys=$(cli $i dbsize 2>/dev/null || echo DOWN)
  links=$(cli $i info replication 2>/dev/null | tr -d '\r' | grep -c 'link_status:up')
  echo "node$i: keys=$keys links_up=$links crashes=$crashes"
  [ "$crashes" = 0 ] && [ "$keys" != DOWN ] || ok=1
  if [ "$crashes" != 0 ]; then docker logs "$(n $i)" 2>&1 | grep -A3 -E "crashed by signal|ASSERTION FAILED ===" | head -12; fi
done
k1=$(cli 1 dbsize); k2=$(cli 2 dbsize); k3=$(cli 3 dbsize)
d=$(( (k1>k3?k1-k3:k3-k1) )); [ $d -le $(( k1/100 + 10 )) ] && echo "CONVERGED: ok" || { echo "CONVERGED: NO ($k1/$k2/$k3)"; ok=1; }
for i in 1 2 3; do docker rm -f "$(n $i)" >/dev/null; done; docker network rm "$NET" >/dev/null
[ $ok = 0 ] && echo "MESH: ok" || echo "MESH: FAILED"
exit $ok
