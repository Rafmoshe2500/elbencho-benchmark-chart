#!/usr/bin/env bash
# NFS test 10: Latency at queue depth 1 (1 thread, iodepth 1): random read + random write, p99/p99.9/p99.99.
#
# usage: ./10-latency-qd1.sh [KEY=VALUE ...]      e.g.  ./10-latency-qd1.sh NFS_SERVER=10.0.0.10 NFS_PATH=/export/bench NCONNECT=16 PODS=4
# test tunables:     PODS BS DURATION LAT_THREADS LAT_IODEPTH (both default 1 = QD1)
# protocol settings: NFS_SERVER NFS_PATH | NFS_STORAGE_CLASS, NFS_VERS NCONNECT RSIZE WSIZE NFS_EXTRA_OPTS FILES FILE_SIZE   (defaults: profile.env)
# general:           NAMESPACE CPU MEMORY SPREAD NODE_SELECTOR PREPARE KEEP LAT EXTRA_ARGS  (see ../README.md)
exec "$(dirname "$0")/../lib/run.sh" nfs 10 "$@"
