# S3 object storage: how to run every test

No volumes: the daemons get the endpoint and the keys from a Secret. The multi tests spread the load over `BUCKETS` (4) buckets `elbencho-1..4`, the single tests use `elbencho-single`, the mixes `elbencho-mix`, the AI tests `elbencho-ai`. "IOPS" on S3 = object requests per second.

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
