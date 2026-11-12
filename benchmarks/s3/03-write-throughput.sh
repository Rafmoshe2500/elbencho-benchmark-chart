#!/usr/bin/env bash
# S3 test 03: Max write throughput: multipart PUTs of TPUT_OBJ_SIZE objects (16m parts).
#
# usage: ./03-write-throughput.sh [KEY=VALUE ...]      e.g.  ./03-write-throughput.sh S3_ENDPOINT=http://minio.minio.svc:9000 S3_SECRET_NAME=s3-creds PODS=4
# test tunables:     PODS THREADS IODEPTH BS DURATION
# protocol settings: S3_ENDPOINT S3_SECRET_NAME | S3_ACCESS_KEY S3_SECRET_KEY, S3_REGION BUCKET_PREFIX BUCKETS OBJ_SIZE OBJECTS TPUT_OBJ_SIZE TPUT_OBJECTS MIX_OBJECTS   (defaults: profile.env)
# general:           NAMESPACE CPU MEMORY SPREAD NODE_SELECTOR PREPARE KEEP LAT EXTRA_ARGS  (see ../README.md)
exec "$(dirname "$0")/../lib/run.sh" s3 03 "$@"
