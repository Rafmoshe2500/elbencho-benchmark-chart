#!/usr/bin/env bash
# RAW-BLOCK test 13: IODEPTH sweep: runs SWEEP_TEST (default 02 = random read IOPS) for every queue depth in SWEEP_IODEPTH
#   (default "1 2 4 8 16 32 64 128") at PODS daemons and prints IOPS, MiB/s, avg and p99 latency per depth.
#
# usage: ./13-iodepth-sweep.sh [KEY=VALUE ...]      e.g.  ./13-iodepth-sweep.sh STORAGE_CLASS=my-block-sc PODS=4
# test tunables:     SWEEP_TEST SWEEP_IODEPTH PODS THREADS BS (+ all tunables of the swept test)
# general:           NAMESPACE CPU MEMORY SPREAD NODE_SELECTOR PREPARE KEEP LAT EXTRA_ARGS  (see ../README.md)
exec "$(dirname "$0")/../lib/run.sh" raw-block 13 "$@"
