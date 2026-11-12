#!/usr/bin/env bash
# NFS test 05: 70/30 read/write random mix, block sizes 32k/64k/128k (equal weights).
#
# usage: ./05-mix70-32k-128k.sh [KEY=VALUE ...]      e.g.  ./05-mix70-32k-128k.sh NFS_SERVER=10.0.0.10 NFS_PATH=/export/bench NCONNECT=16 PODS=4
# test tunables:     PODS THREADS IODEPTH BS_MIX READ_PCT DURATION
# protocol settings: NFS_SERVER NFS_PATH | NFS_STORAGE_CLASS, NFS_VERS NCONNECT RSIZE WSIZE NFS_EXTRA_OPTS FILES FILE_SIZE   (defaults: profile.env)
# general:           NAMESPACE CPU MEMORY SPREAD NODE_SELECTOR PREPARE KEEP LAT EXTRA_ARGS  (see ../README.md)
exec "$(dirname "$0")/../lib/run.sh" nfs 05 "$@"
