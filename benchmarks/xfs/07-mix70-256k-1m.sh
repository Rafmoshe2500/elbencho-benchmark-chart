#!/usr/bin/env bash
# XFS test 07: 70/30 read/write random mix, block sizes 256k/512k/1m (equal weights).
#
# usage: ./07-mix70-256k-1m.sh [KEY=VALUE ...]      e.g.  ./07-mix70-256k-1m.sh STORAGE_CLASS=my-xfs-sc PODS=4
# test tunables:     PODS THREADS IODEPTH BS_MIX READ_PCT DURATION
# protocol settings: STORAGE_CLASS PVC_SIZE FILES FILE_SIZE   (defaults: profile.env)
# general:           NAMESPACE CPU MEMORY SPREAD NODE_SELECTOR PREPARE KEEP LAT EXTRA_ARGS  (see ../README.md)
exec "$(dirname "$0")/../lib/run.sh" xfs 07 "$@"
