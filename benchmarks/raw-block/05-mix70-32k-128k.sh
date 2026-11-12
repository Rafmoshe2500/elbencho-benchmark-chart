#!/usr/bin/env bash
# RAW-BLOCK test 05: 70/30 read/write random mix, block sizes 32k/64k/128k (equal weights).
#
# usage: ./05-mix70-32k-128k.sh [KEY=VALUE ...]      e.g.  ./05-mix70-32k-128k.sh STORAGE_CLASS=my-block-sc PODS=4
# test tunables:     PODS THREADS IODEPTH BS_MIX READ_PCT DURATION
# protocol settings: STORAGE_CLASS PVC_SIZE DEV_SIZE   (defaults: profile.env)
# general:           NAMESPACE CPU MEMORY SPREAD NODE_SELECTOR PREPARE KEEP LAT EXTRA_ARGS  (see ../README.md)
exec "$(dirname "$0")/../lib/run.sh" raw-block 05 "$@"
