#!/usr/bin/env bash
# XFS test 03: Max write throughput: large sequential writes (default 1m), O_DIRECT.
#
# usage: ./03-write-throughput.sh [KEY=VALUE ...]      e.g.  ./03-write-throughput.sh STORAGE_CLASS=my-xfs-sc PODS=4
# test tunables:     PODS THREADS IODEPTH BS DURATION
# protocol settings: STORAGE_CLASS PVC_SIZE FILES FILE_SIZE   (defaults: profile.env)
# general:           NAMESPACE CPU MEMORY SPREAD NODE_SELECTOR PREPARE KEEP LAT EXTRA_ARGS  (see ../README.md)
exec "$(dirname "$0")/../lib/run.sh" xfs 03 "$@"
