#!/usr/bin/env bash
# XFS test 11: Metadata rates: create / stat / delete of many empty files (S3: PUT / LIST / HEAD / DELETE).
#
# usage: ./11-metadata.sh [KEY=VALUE ...]      e.g.  ./11-metadata.sh STORAGE_CLASS=my-xfs-sc PODS=4
# test tunables:     PODS THREADS META_DIRS META_FILES
# protocol settings: STORAGE_CLASS PVC_SIZE FILES FILE_SIZE   (defaults: profile.env)
# general:           NAMESPACE CPU MEMORY SPREAD NODE_SELECTOR PREPARE KEEP LAT EXTRA_ARGS  (see ../README.md)
exec "$(dirname "$0")/../lib/run.sh" xfs 11 "$@"
