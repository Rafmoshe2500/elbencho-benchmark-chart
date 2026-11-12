#!/usr/bin/env bash
# S3 test 06: 70/30 read/write mix, small objects 1k/2k/4k.
#
# usage: ./06-mix70-4k.sh [KEY=VALUE ...]      e.g.  ./06-mix70-4k.sh S3_ENDPOINT=http://minio.minio.svc:9000 S3_SECRET_NAME=s3-creds PODS=4
# test tunables:     PODS THREADS IODEPTH BS_MIX READ_PCT DURATION
# protocol settings: S3_ENDPOINT S3_SECRET_NAME | S3_ACCESS_KEY S3_SECRET_KEY, S3_REGION BUCKET_PREFIX BUCKETS OBJ_SIZE OBJECTS TPUT_OBJ_SIZE TPUT_OBJECTS MIX_OBJECTS   (defaults: profile.env)
# general:           NAMESPACE CPU MEMORY SPREAD NODE_SELECTOR PREPARE KEEP LAT EXTRA_ARGS  (see ../README.md)
exec "$(dirname "$0")/../lib/run.sh" s3 06 "$@"
