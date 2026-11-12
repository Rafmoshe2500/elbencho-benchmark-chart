#!/usr/bin/env bash
# XFS test 06: 70/30 read/write random mix, small blocks up to 4k.
#
# usage: ./06-mix70-4k.sh [KEY=VALUE ...]      e.g.  ./06-mix70-4k.sh STORAGE_CLASS=my-xfs-sc PODS=4
# test tunables:     PODS THREADS IODEPTH BS_MIX READ_PCT DURATION
# protocol settings: STORAGE_CLASS PVC_SIZE FILES FILE_SIZE   (defaults: profile.env)
# general:           NAMESPACE CPU MEMORY SPREAD NODE_SELECTOR PREPARE KEEP LAT EXTRA_ARGS  (see ../README.md)
exec "$(dirname "$0")/../lib/run.sh" xfs 06 "$@"
