#!/usr/bin/env bash
# S3 test 18: PUT / GET / DELETE matrix: MATRIX_PODS (1 4 16 64 256 1024) x MATRIX_THREADS (1 2 4 8 16 32) x
#   MATRIX_SIZES (large = objects of 1-4 MiB, small = 3-4 KiB, random per object) x PUT, GET, DELETE = 216 tests
#   in a row, one CSV with latency (per object, per request = clat, storage side), p50/p90/p99 and client CPU.
#   Every test runs DURATION s (default 600 = 10 min; MATRIX_MODE=time), or every object once (MATRIX_MODE=count).
#
# usage: ./18-put-get-delete-matrix.sh [KEY=VALUE ...]   e.g.  ./18-put-get-delete-matrix.sh S3_ENDPOINT=http://minio.minio.svc:9000 S3_SECRET_NAME=s3-creds
# test tunables:     MATRIX_MODE DURATION MATRIX_PODS MATRIX_THREADS MATRIX_SIZES MATRIX_LARGE MATRIX_SMALL MATRIX_{LARGE,SMALL}_{OBJS,MIN,MAX}
#                    MATRIX_PLAN MATRIX_RESUME CONTINUE, storage side: STORAGE_LAT_CMD | PROM_URL PROM_Q_* (see README)
# protocol settings: S3_ENDPOINT S3_SECRET_NAME | S3_ACCESS_KEY S3_SECRET_KEY, S3_REGION BUCKET_PREFIX   (defaults: profile.env)
# general:           NAMESPACE CPU MEMORY SPREAD NODE_SELECTOR KEEP WAIT_TIMEOUT EXTRA_ARGS  (see ../README.md)
exec "$(dirname "$0")/../lib/run.sh" s3 18 "$@"
