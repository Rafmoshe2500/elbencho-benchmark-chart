# S3 object storage: how to run every test

No volumes: the daemons get the endpoint and the keys from a Secret. The multi tests spread the load over `BUCKETS` (4) buckets `elbencho-1..4`, the single tests use `elbencho-single`, the mixes `elbencho-mix`, the AI tests `elbencho-ai`, the matrix (18) `elbencho-matrix`. "IOPS" on S3 = object requests per second.

All variables, what they change, and the background are in [../README.md](../README.md). Every value is `KEY=VALUE`,
as an argument or an environment variable; arguments win.

## Connection (needed by every command)

```bash
# once: a namespace and a Secret with the keys
kubectl create namespace elbencho-bench
kubectl -n elbencho-bench create secret generic s3-creds \
  --from-literal=AWS_ACCESS_KEY_ID=... --from-literal=AWS_SECRET_ACCESS_KEY=...

S="S3_ENDPOINT=http://s3-1:9000,http://s3-2:9000 S3_SECRET_NAME=s3-creds"
```

| Key | Default | Meaning |
|---|---|---|
| `S3_ENDPOINT` | – (required) | one or more endpoints, comma separated (the threads are spread over them) |
| `S3_SECRET_NAME` | – | Secret with `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` |
| `S3_ACCESS_KEY` / `S3_SECRET_KEY` | – | instead of the Secret: the runner creates it (keys are never written to the results) |
| `S3_REGION` | – | |
| `BUCKET_PREFIX` / `BUCKETS` | elbencho / 4 | bucket names and how many the multi tests use |

## Defaults of every test

| | Default | Change with |
|---|---|---|
| load generators | 2 pods (test 17: one per node) | `PODS=4`, `PODS=auto` (one per node), `PODS_PER_NODE=2` |
| CPU per pod | none (with `PODS=auto`: 80% of the free CPU of the weakest node) | `CPU=16`, `CPU=auto`, `CPU_SHARE=90` |
| duration of every measured phase | 300 s (5 min) | `DURATION=60` (quick), `DURATION=1800` (steady state) |
| dataset | 16g for IOPS tests and mixes, 4t for 03, 04, 16; objects per thread = `DATASET_SIZE / (OBJ_SIZE × PODS × THREADS)` | `DATASET_SIZE=10t`, `OBJ_SIZE=64k` |
| latency target, avg/p99 ms | read `30/90`, write `30/90` | `LAT_READ=1/4 LAT_WRITE=-/8` |

Every run prints a summary with IOPS, MiB/s, read and write latency (avg, p99 ...), the CPU use of the busiest pod and a
`TARGET ... within / OVER the target` line, and appends one row per phase to `benchmarks/results/summary.csv`.

## The tests

### 01 – Max write IOPS (PUT)

PUTs of small objects; every thread overwrites its own objects in a loop.  
Defaults: `OBJ_SIZE=4k` `THREADS=32` (32 requests in flight per pod; `IODEPTH` has no effect).

```bash
./benchmarks/s3/01-write-iops.sh $S PODS=4
./benchmarks/s3/01-write-iops.sh $S PODS=auto THREADS=64
./benchmarks/s3/01-write-iops.sh $S PODS=8 OBJ_SIZE=64k DATASET_SIZE=200g
```

### 02 – Max read IOPS (GET)

GETs of the prepared small objects (`--s3fastget`).  
Defaults: `OBJ_SIZE=4k` `THREADS=32` `DATASET_SIZE=16g`.

```bash
./benchmarks/s3/02-read-iops.sh $S PODS=4
./benchmarks/s3/02-read-iops.sh $S PODS=auto THREADS=128
./benchmarks/s3/02-read-iops.sh $S PODS=8 DATASET_SIZE=500g   # beyond the cache: prepare takes long
```

### 03 – Max write throughput

Multipart PUTs of large objects.  
Defaults: `OBJ_SIZE=256m`, parts `BS=16m`, `THREADS=16` `IODEPTH=1` (parts in flight per thread).

```bash
./benchmarks/s3/03-write-throughput.sh $S PODS=4
./benchmarks/s3/03-write-throughput.sh $S PODS=auto OBJ_SIZE=1g BS=32m IODEPTH=4 MEMORY=16Gi
```

### 04 – Max read throughput

GETs of the large objects in `BS` ranges.  
Defaults: `OBJ_SIZE=256m` `BS=16m` `THREADS=16` `DATASET_SIZE=4t`.

```bash
./benchmarks/s3/04-read-throughput.sh $S PODS=4
./benchmarks/s3/04-read-throughput.sh $S PODS=auto IODEPTH=4 MEMORY=16Gi
```

### 05 – 70/30 mix, 32k-128k

Readers (70% of THREADS) GET and writers PUT objects of mixed sizes at the same time; the summary shows the real read share.  
Defaults: `BS_MIX=32k:1,64k:1,128k:1` `THREADS=20` (14 readers + 6 writers) `DATASET_SIZE=16g`.

```bash
./benchmarks/s3/05-mix70-32k-128k.sh $S PODS=4
./benchmarks/s3/05-mix70-32k-128k.sh $S PODS=4 READ_PCT=80 THREADS=40
```

### 06 – 70/30 mix, small objects

The same with objects of 1k, 2k and 4k.  
Defaults: `BS_MIX=1k:1,2k:1,4k:1` `THREADS=20`.  
16g of small objects are ~7 million objects, so the treefile that elbencho uploads to every daemon is large. The runner
times this upload with a dry run and starts readers and writers together only after it (see "How the 70/30 mixes work" in
[../README.md](../README.md); `START_DELAY=<seconds>` to set the lead time by hand).

```bash
./benchmarks/s3/06-mix70-4k.sh $S PODS=4
```

### 07 – 70/30 mix, large objects

The same with objects of 256k, 512k and 1m.  
Defaults: `BS_MIX=256k:1,512k:1,1m:1` `THREADS=20`.

```bash
./benchmarks/s3/07-mix70-256k-1m.sh $S PODS=4
```

### 08 – Read IOPS on one bucket

Like 02, all pods on one bucket. Shows whether one bucket is a bottleneck.  
Defaults: as 02.

```bash
./benchmarks/s3/08-single-target-read-iops.sh $S PODS=4
```

### 09 – Write IOPS on one bucket

Like 01, on one bucket.  
Defaults: as 01.

```bash
./benchmarks/s3/09-single-target-write-iops.sh $S PODS=4
```

### 10 – Latency, one request at a time

PUT, then GET of 4k objects with one thread per pod: latency with p99, p99.9, p99.99. The 1000 objects per pod are written once beforehand.  
Defaults: `BS=4k`, 1 thread, 5 min each phase.

```bash
./benchmarks/s3/10-latency-qd1.sh $S PODS=1
./benchmarks/s3/10-latency-qd1.sh $S PODS=1 BS=64k
```

### 11 – Metadata

PUT of empty objects, LIST (parallel), HEAD, DELETE: operations/s and latency.  
Defaults: `META_FILES=2000` objects per thread, `THREADS=16`.

```bash
./benchmarks/s3/11-metadata.sh $S PODS=4
./benchmarks/s3/11-metadata.sh $S PODS=4 META_FILES=10000
```

### 14 – AI training (MLPerf Storage style)

All pods read the whole sample dataset in a new random order every epoch, then write their checkpoint shard
(`CKPT_MODE=sync`, or `async` during the next epoch's reads), and finally read the last checkpoint back.  
Defaults: `TRAIN_PRESET=resnet50` (100,000 samples of 115k), `EPOCHS=3`, `TRAIN_THREADS=8`, `CKPT_SIZE=8g` per pod.

```bash
./benchmarks/s3/14-ai-training.sh $S PODS=8
./benchmarks/s3/14-ai-training.sh $S PODS=8 TRAIN_PRESET=unet3d CKPT_MODE=async TRAIN_REQUIRED_MIBS=1500
./benchmarks/s3/14-ai-training.sh $S PODS=8 TRAIN_PRESET=custom TRAIN_SAMPLES=500000 TRAIN_SIZE_MIX="64k:1,256k:2,1m:1"
```

### 15 – AI inference

`load`: every pod reads the full model at the same time (cold start); `lookup`: small random reads at queue depth 1
(RAG / index); `kvcache`: 50/50 read/write of 2m chunks.  
Defaults: `MODEL_SIZE=16g` in `MODEL_SHARDS=4`, `LOAD_THREADS=16`, `INF_PHASES="load lookup kvcache"`.

```bash
./benchmarks/s3/15-ai-inference.sh $S PODS=16
./benchmarks/s3/15-ai-inference.sh $S PODS=16 MODEL_SIZE=140g MODEL_SHARDS=30
./benchmarks/s3/15-ai-inference.sh $S PODS=8 INF_PHASES=lookup LOOKUP_THREADS=16
```

### 16 – Range reads

Random byte-range GETs at random offsets of large objects: the Parquet/ORC pattern of Trino or Spark.  
Defaults: `OBJ_SIZE=256m`, `RANGE_BS=64k:1,1m:2,8m:1` (size of every ranged GET), `THREADS=16`, `DATASET_SIZE=4t`.

```bash
./benchmarks/s3/16-range-read.sh $S PODS=4
./benchmarks/s3/16-range-read.sh $S PODS=8 OBJ_SIZE=512m RANGE_BS="8k:1,1m:4" THREADS=32
```

### 17 – Find the maximum within the latency target

A pod on every node (`PODS=auto`, `CPU=auto`), `SWEEP_TEST` with a growing load: THREADS per pod `8 16 32 64 128 256` (03/04: `2 … 64`), 5 min per step. It stops when
the latency target is missed, when two steps gain less than 3%, or when the pods run out of CPU, and prints
`BEST within target` with the settings of the best step.

```bash
./benchmarks/s3/17-find-max.sh $S SWEEP_TEST=01     # max write IOPS
./benchmarks/s3/17-find-max.sh $S SWEEP_TEST=02     # max read IOPS
./benchmarks/s3/17-find-max.sh $S SWEEP_TEST=03     # max write throughput
./benchmarks/s3/17-find-max.sh $S SWEEP_TEST=04     # max read throughput
./benchmarks/s3/17-find-max.sh $S SWEEP_TEST=02 LAT_READ=1/3 DURATION=120     # own target, 2-min steps
./benchmarks/s3/17-find-max.sh $S SWEEP_TEST=02 PODS_PER_NODE=2 SWEEP_THREADS="64 128 256 512"   # pods were CPU-bound
```

### 18 – PUT / GET / DELETE matrix (216 tests, one CSV)

Runs every combination of

| | Default | Change with |
|---|---|---|
| pods (load generators) | `1 4 16 64 256 1024` | `MATRIX_PODS="1 4 16"` |
| threads per pod | `1 2 4 8 16 32` | `MATRIX_THREADS="1 8 32"` |
| object class | `large small` | `MATRIX_SIZES=small` |
| operation | PUT, GET, DELETE | – |

= 6 × 6 × 2 cells × 3 operations = **216 tests in a row**, and writes one row per test to
`benchmarks/results/matrix-<date>.csv` (plus a table in `matrix-<date>.txt`).

**Objects.** `large` = objects of a random size between 1 MiB and 4 MiB (`MATRIX_LARGE=1m-4m`), `small` = between
3 KiB and 4 KiB (`MATRIX_SMALL=3k-4k`), uniformly random per object. Every object is one S3 request, so the "block"
is the object itself (multipart parts must be at least 5 MiB, so a 1–4 MiB block can only be a whole object).
Every cell writes its own set of objects (PUT, each object once), reads all of them (GET, each once) and deletes
all of them (DELETE, each once) under its own key prefix in the bucket `<BUCKET_PREFIX>-matrix`. The phases run
until every object is done (no time limit), so the number of objects sets the length of a phase:

| | Objects per thread | At least (per cell) | At most (per cell) |
|---|---|---|---|
| large | `MATRIX_LARGE_OBJS=10` | `MATRIX_LARGE_MIN=500` | `MATRIX_LARGE_MAX=100000` |
| small | `MATRIX_SMALL_OBJS=50` | `MATRIX_SMALL_MIN=5000` | `MATRIX_SMALL_MAX=300000` |

and never less than one object per thread. With the defaults the whole matrix writes ~2.9 million objects,
~1.4 TiB (each cell deletes its objects again; the largest cell holds ~244 GiB). `MATRIX_PLAN=1` prints the
objects and data of every cell without running anything. The sizes come from an object list (elbencho custom tree
mode) that elbencho uploads to every pod before a phase; at 1024 pods and 300,000 objects that is ~7 MiB per pod.

```bash
./benchmarks/s3/18-put-get-delete-matrix.sh $S MATRIX_PLAN=1                   # the plan only
./benchmarks/s3/18-put-get-delete-matrix.sh $S                                 # all 216 tests
./benchmarks/s3/18-put-get-delete-matrix.sh $S MATRIX_PODS="1 4 16" MATRIX_THREADS="1 4 16"   # a smaller grid
./benchmarks/s3/18-put-get-delete-matrix.sh $S MATRIX_SMALL_OBJS=200 MATRIX_LARGE_MAX=20000   # longer small / shorter large phases
./benchmarks/s3/18-put-get-delete-matrix.sh $S MATRIX_RESUME=matrix-20261123-101500           # go on after an interruption
```

The order is pods (1 → 1024), then class, then threads, so that the StatefulSet only grows 6 times. A failed cell
gets `failed` rows and the matrix goes on (`CONTINUE=0` stops it); its objects are deleted. `MATRIX_RESUME=<id>`
reruns the same grid (from `matrix-<id>.grid`) and only the cells without three good rows. 1024 pods need a cluster
that can schedule them (pod count per node, IPs); the rollout wait is 30 minutes for this test (`WAIT_TIMEOUT`). The
pods stay deployed at the end (`./benchmarks/cleanup.sh s3`, or `KEEP=0`).

**The CSV.** One row per test, latencies in ms:

| Column | Meaning |
|---|---|
| `test_no`, `operation`, `size_class`, `object_size_range`, `pods`, `threads_per_pod`, `total_threads` | which test |
| `objects`, `total_mib`, `avg_object_kib`, `elapsed_s`, `ops_per_s`, `mib_per_s` | work done and rate (all objects / time until the last thread finished) |
| `lat_avg/min/max_ms`, `lat_p50/p90/p99/p99_9_ms` | **total latency per object** as the application sees it (elbencho "Objects latency": the whole PUT / GET / DELETE of one object, client overhead included) |
| `clat_avg/min/max_ms`, `clat_p50/p90/p99/p99_9_ms` | **completion latency per S3 request**: from sending the request until the response is complete (elbencho "IO latency"). With one request per object it is almost equal to `lat`; the difference is client-side work. DELETE is measured once per object: `clat = lat` |
| `storage_lat_avg/p50/p90/p99_ms` | **latency measured by the storage system itself**, from its metrics (see below); empty if not configured |
| `client_cpu_util_pct` | CPU use of the load generator **nodes** during the phase, average over the pods (elbencho `--cpu`, from `/proc/stat`: the whole node) |
| `pod_cpu_avg_cores`, `pod_cpu_busiest_cores`, `pod_cpu_busiest_pct`, `pod_cpu_throttled_pct` | CPU the elbencho containers used themselves (cgroup counters; with more than 64 pods, 64 of them are sampled: `CPU_SAMPLE_PODS`) |
| `verdict` | `ok`, `CLIENT-LIMITED` (the busiest pod used >= `CLIENT_CPU_MAX` % of its CPU: that row measures the load generators, not the storage), `failed` |
| `start_utc`, `end_utc`, `run_dir` | when the phase ran, and its folder (elbencho result files with the full latency histograms) |

p50, p99 and p99.9 (`lat_*` and `clat_*`) are elbencho's own percentiles, as it prints them. elbencho prints no
p90: that column comes from elbencho's latency histogram (`--lathisto`), computed the way elbencho computes its
percentiles (upper bound of the histogram bucket; checked: the same method gives exactly elbencho's p50 / p99).

**Latency on the storage side.** A client can only measure the time a request took including the network. The
storage system's own view comes from its metrics, so it is optional:

- `PROM_URL` (+ `PROM_TOKEN` for a bearer token, `PROM_INSECURE=1` for a self-signed certificate): a Prometheus
  (or Thanos) that scrapes the storage system, reachable from your machine (e.g. `kubectl port-forward`; needs
  `curl`). `PROM_Q_AVG`, `PROM_Q_P50`, `PROM_Q_P90`, `PROM_Q_P99` are PromQL queries with placeholders, evaluated
  for the window of each phase: `%API%` = `PutObject` / `GetObject` / `DeleteObject`, `%api%` = the same in lower
  case, `%op%` = `put` / `get` / `del`, `%range%` = the length of the window (e.g. `95s`). The result is in seconds
  (`PROM_UNIT=ms` / `us` otherwise). Leave out what your system has no metric for.
- `STORAGE_LAT_CMD`: any command instead (a vendor CLI, a REST call); it gets `OP`, `S3_API`, `START_EPOCH`,
  `END_EPOCH`, `PODS`, `THREADS`, `OBJ_CLASS` in the environment and prints `avg p50 p90 p99` in ms (`-` = none).
- `STORAGE_LAT_WAIT=30`: seconds to wait after a cell before asking (the metrics are scraped with a delay); the
  window of a phase is its start until its end + this wait. Phases shorter than two scrape intervals give no value.

The metric names differ between products and versions: check them on your system's `/metrics` first. Examples:

```bash
# Ceph RGW (ceph-exporter): only averages exist (per-op latency sum / count)
PROM_Q_AVG='sum(increase(ceph_rgw_op_%op%_obj_lat_sum[%range%])) / sum(increase(ceph_rgw_op_%op%_obj_lat_count[%range%]))'
# MinIO / AIStor metrics v3: time to first byte as a histogram, per API
PROM_Q_P50='histogram_quantile(0.5, sum by (le) (increase(minio_api_requests_ttfb_seconds_distribution{name="%API%"}[%range%])))'
PROM_Q_P90='histogram_quantile(0.9, sum by (le) (increase(minio_api_requests_ttfb_seconds_distribution{name="%API%"}[%range%])))'
PROM_Q_P99='histogram_quantile(0.99, sum by (le) (increase(minio_api_requests_ttfb_seconds_distribution{name="%API%"}[%range%])))'

kubectl -n monitoring port-forward svc/prometheus-operated 9090 &
./benchmarks/s3/18-put-get-delete-matrix.sh $S PROM_URL=http://localhost:9090 PROM_Q_AVG="$PROM_Q_AVG" PROM_Q_P99="$PROM_Q_P99"
```

### 12 – Sweeps: one value at several steps, one table

`SWEEP_PODS` defaults to `1 2 4 8`, so give it for a fixed pod count too.

```bash
./benchmarks/s3/12-scaling-sweep.sh $S SWEEP_TEST=02 SWEEP_PODS="8 4 2 1"                        # load generators
./benchmarks/s3/12-scaling-sweep.sh $S SWEEP_TEST=02 SWEEP_PODS=4 SWEEP_THREADS="8 16 32 64"     # threads
./benchmarks/s3/12-scaling-sweep.sh $S SWEEP_TEST=04 SWEEP_PODS=4 SWEEP_IODEPTH="1 2 4 8"             # parts in flight
./benchmarks/s3/12-scaling-sweep.sh $S SWEEP_TEST=02 SWEEP_PODS=4 SWEEP_DATASET_SIZE="100g 400g 1600g"  # where the cache ends
```

## Several tests, comparisons, by hand

```bash
# all basic tests (01..11, 16) on one deployment, one after the other
./benchmarks/run-suite.sh s3 $S PODS=auto
./benchmarks/run-suite.sh s3 $S TESTS="01 02 03 04" PODS=auto CONTINUE=1

# the same tests on two systems, side by side (default: find-max on 01 02 03 04)
./benchmarks/compare.sh s3 TARGETS="minio=http://minio:9000 ceph=http://rgw:8080" S3_SECRET_NAME=s3-creds

# only deploy the pods and run elbencho yourself (prints the commands)
./benchmarks/deploy.sh s3 $S PODS=auto

# remove the deployments of this protocol
./benchmarks/cleanup.sh s3
```

S3 data is not deleted by `cleanup.sh`; remove the buckets with your S3 tools.
