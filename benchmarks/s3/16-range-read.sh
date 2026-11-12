#!/usr/bin/env bash
# S3 test 16: Random byte-range GETs inside large objects - the access pattern of analytics engines
#   (Trino, Spark, DuckDB) reading Parquet/ORC: small footer reads plus column-chunk reads at random offsets.
#
# usage: ./16-range-read.sh [KEY=VALUE ...]      e.g.  ./16-range-read.sh S3_ENDPOINT=http://minio.minio.svc:9000 S3_SECRET_NAME=s3-creds PODS=4
# test tunables:     RANGE_OBJ_SIZE(256m) RANGE_OBJECTS(4 per thread) RANGE_BS("64k:1,1m:2,8m:1") THREADS(16) IODEPTH DURATION PODS
# general:           NAMESPACE CPU MEMORY SPREAD STORAGE_CACHE DETACH PREPARE KEEP LAT EXTRA_ARGS  (see ../README.md)
exec "$(dirname "$0")/../lib/run.sh" s3 16 "$@"
