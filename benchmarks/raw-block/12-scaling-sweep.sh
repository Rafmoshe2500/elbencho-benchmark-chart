#!/usr/bin/env bash
# RAW-BLOCK test 12: Runs another test for several pod counts (and NCONNECT values for NFS) and prints a comparison table.
#
# usage: ./12-scaling-sweep.sh [KEY=VALUE ...]      e.g.  ./12-scaling-sweep.sh STORAGE_CLASS=my-block-sc PODS=4
# test tunables:     SWEEP_TEST SWEEP_PODS SWEEP_NCONNECT
# protocol settings: STORAGE_CLASS PVC_SIZE DEV_SIZE   (defaults: profile.env)
# general:           NAMESPACE CPU MEMORY SPREAD NODE_SELECTOR PREPARE KEEP LAT EXTRA_ARGS  (see ../README.md)
exec "$(dirname "$0")/../lib/run.sh" raw-block 12 "$@"
