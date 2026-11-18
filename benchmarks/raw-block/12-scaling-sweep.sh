#!/usr/bin/env bash
# RAW-BLOCK test 12: Sweep: runs another test for several values of PODS, THREADS, IODEPTH, NCONNECT (nfs) or DATASET_SIZE
#   and prints a table with a latency verdict per step.
#
# usage: ./12-scaling-sweep.sh [KEY=VALUE ...]      e.g.  ./12-scaling-sweep.sh STORAGE_CLASS=my-block-sc PODS=4
# test tunables:     SWEEP_TEST SWEEP_PODS SWEEP_THREADS SWEEP_IODEPTH SWEEP_NCONNECT SWEEP_DATASET_SIZE (see README, "Sweeps")
# protocol settings: STORAGE_CLASS DATASET_SIZE PVC_SIZE   (defaults: profile.env)
# general:           NAMESPACE CPU MEMORY SPREAD NODE_SELECTOR PREPARE KEEP LAT EXTRA_ARGS  (see ../README.md)
exec "$(dirname "$0")/../lib/run.sh" raw-block 12 "$@"
