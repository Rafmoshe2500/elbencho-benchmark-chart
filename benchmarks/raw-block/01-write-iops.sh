#!/usr/bin/env bash
# RAW-BLOCK test 01: Max write IOPS: small random writes (default 4k), O_DIRECT, threads x iodepth per daemon.
#
# usage: ./01-write-iops.sh [KEY=VALUE ...]      e.g.  ./01-write-iops.sh STORAGE_CLASS=my-block-sc PODS=4
# test tunables:     PODS THREADS IODEPTH BS DURATION
# protocol settings: STORAGE_CLASS PVC_SIZE DEV_SIZE   (defaults: profile.env)
# general:           NAMESPACE CPU MEMORY SPREAD NODE_SELECTOR PREPARE KEEP LAT EXTRA_ARGS  (see ../README.md)
exec "$(dirname "$0")/../lib/run.sh" raw-block 01 "$@"
