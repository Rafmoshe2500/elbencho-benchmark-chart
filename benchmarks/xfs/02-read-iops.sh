#!/usr/bin/env bash
# XFS test 02: Max read IOPS: small random reads (default 4k) of a prepared dataset, O_DIRECT.
#
# usage: ./02-read-iops.sh [KEY=VALUE ...]      e.g.  ./02-read-iops.sh STORAGE_CLASS=my-xfs-sc PODS=4
# test tunables:     PODS THREADS IODEPTH BS DURATION
# protocol settings: STORAGE_CLASS PVC_SIZE FILES FILE_SIZE   (defaults: profile.env)
# general:           NAMESPACE CPU MEMORY SPREAD NODE_SELECTOR PREPARE KEEP LAT EXTRA_ARGS  (see ../README.md)
exec "$(dirname "$0")/../lib/run.sh" xfs 02 "$@"
