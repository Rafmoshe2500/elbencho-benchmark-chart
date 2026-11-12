#!/usr/bin/env bash
# NFS test 11: Metadata rates: create / stat / delete of many empty files (S3: PUT / LIST / HEAD / DELETE).
#
# usage: ./11-metadata.sh [KEY=VALUE ...]      e.g.  ./11-metadata.sh NFS_SERVER=10.0.0.10 NFS_PATH=/export/bench NCONNECT=16 PODS=4
# test tunables:     PODS THREADS META_DIRS META_FILES
# protocol settings: NFS_SERVER NFS_PATH | NFS_STORAGE_CLASS, NFS_VERS NCONNECT RSIZE WSIZE NFS_EXTRA_OPTS FILES FILE_SIZE   (defaults: profile.env)
# general:           NAMESPACE CPU MEMORY SPREAD NODE_SELECTOR PREPARE KEEP LAT EXTRA_ARGS  (see ../README.md)
exec "$(dirname "$0")/../lib/run.sh" nfs 11 "$@"
