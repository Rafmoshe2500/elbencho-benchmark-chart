#!/usr/bin/env bash
# RAW-BLOCK test 04: Max read throughput: large sequential reads (default 1m) of a prepared dataset.
#
# usage: ./04-read-throughput.sh [KEY=VALUE ...]      e.g.  ./04-read-throughput.sh STORAGE_CLASS=my-block-sc PODS=4
# test tunables:     PODS THREADS IODEPTH BS DURATION
# protocol settings: STORAGE_CLASS PVC_SIZE DEV_SIZE   (defaults: profile.env)
# general:           NAMESPACE CPU MEMORY SPREAD NODE_SELECTOR PREPARE KEEP LAT EXTRA_ARGS  (see ../README.md)
exec "$(dirname "$0")/../lib/run.sh" raw-block 04 "$@"
