#!/usr/bin/env bash
# RAW-BLOCK test 10: Latency at queue depth 1 (1 thread, iodepth 1): random read + random write, p99/p99.9/p99.99.
#
# usage: ./10-latency-qd1.sh [KEY=VALUE ...]      e.g.  ./10-latency-qd1.sh STORAGE_CLASS=my-block-sc PODS=4
# test tunables:     PODS BS DURATION LAT_THREADS LAT_IODEPTH (both default 1 = QD1)
# protocol settings: STORAGE_CLASS PVC_SIZE DEV_SIZE   (defaults: profile.env)
# general:           NAMESPACE CPU MEMORY SPREAD NODE_SELECTOR PREPARE KEEP LAT EXTRA_ARGS  (see ../README.md)
exec "$(dirname "$0")/../lib/run.sh" raw-block 10 "$@"
