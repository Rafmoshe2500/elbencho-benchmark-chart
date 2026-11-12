#!/usr/bin/env bash
# NFS test 08: Max read IOPS with ALL daemons on ONE target (single PVC / export dir / bucket).
#
# usage: ./08-single-target-read-iops.sh [KEY=VALUE ...]      e.g.  ./08-single-target-read-iops.sh NFS_SERVER=10.0.0.10 NFS_PATH=/export/bench NCONNECT=16 PODS=4
# test tunables:     PODS THREADS IODEPTH BS DURATION
# protocol settings: NFS_SERVER NFS_PATH | NFS_STORAGE_CLASS, NFS_VERS NCONNECT RSIZE WSIZE NFS_EXTRA_OPTS FILES FILE_SIZE   (defaults: profile.env)
# general:           NAMESPACE CPU MEMORY SPREAD NODE_SELECTOR PREPARE KEEP LAT EXTRA_ARGS  (see ../README.md)
exec "$(dirname "$0")/../lib/run.sh" nfs 08 "$@"
