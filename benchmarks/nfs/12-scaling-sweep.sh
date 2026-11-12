#!/usr/bin/env bash
# NFS test 12: Runs another test for several pod counts (and NCONNECT values for NFS) and prints a comparison table.
#
# usage: ./12-scaling-sweep.sh [KEY=VALUE ...]      e.g.  ./12-scaling-sweep.sh NFS_SERVER=10.0.0.10 NFS_PATH=/export/bench NCONNECT=16 PODS=4
# test tunables:     SWEEP_TEST SWEEP_PODS SWEEP_NCONNECT
# protocol settings: NFS_SERVER NFS_PATH | NFS_STORAGE_CLASS, NFS_VERS NCONNECT RSIZE WSIZE NFS_EXTRA_OPTS FILES FILE_SIZE   (defaults: profile.env)
# general:           NAMESPACE CPU MEMORY SPREAD NODE_SELECTOR PREPARE KEEP LAT EXTRA_ARGS  (see ../README.md)
exec "$(dirname "$0")/../lib/run.sh" nfs 12 "$@"
