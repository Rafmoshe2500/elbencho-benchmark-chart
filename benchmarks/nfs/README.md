# NFS: how to run every test

All daemons mount the same export at `/data` (the chart creates the PV with your mount options). In the multi tests every daemon works in its own sub directory (named after the pod); in the single tests (08, 09) and the AI tests they share one directory. Alternative: `NFS_STORAGE_CLASS=<an RWX StorageClass>` (mount options then come from the StorageClass).

All variables, what they change, and the background are in [../README.md](../README.md). Every value is `KEY=VALUE`,
as an argument or an environment variable; arguments win.

## Connection (needed by every command)

```bash
N="NFS_SERVER=10.0.0.10 NFS_PATH=/export/bench"
```

| Key | Default | Meaning |
|---|---|---|
| `NFS_SERVER` / `NFS_PATH` | – / `/` | the export |
| `NFS_VERS` | 4.1 | `3`, `4.0`, `4.1`, `4.2` |
| `NCONNECT` | 8 | TCP connections per mount (0 = off); changing it restarts the daemons |
| `RSIZE` / `WSIZE` | 1048576 | try 65536 for small random IO |
| `NFS_EXTRA_OPTS` | hard | more mount options, e.g. `hard,noatime` |
| `NFS_STORAGE_CLASS` | – | instead of `NFS_SERVER`: an existing RWX StorageClass |

## Defaults of every test

| | Default | Change with |
|---|---|---|
| load generators | 2 pods (test 17: one per node) | `PODS=4`, `PODS=auto` (one per node), `PODS_PER_NODE=2` |
| CPU per pod | none (with `PODS=auto`: 80% of the free CPU of the weakest node) | `CPU=16`, `CPU=auto`, `CPU_SHARE=90` |
| duration of every measured phase | 300 s (5 min) | `DURATION=60` (quick), `DURATION=1800` (steady state) |
| dataset | 4t (4 TiB) in total; `FILE_SIZE=64g` files; files per pod = `DATASET_SIZE / PODS / 64g` | `DATASET_SIZE=10t`, `FILE_SIZE=16g` |
| latency target, avg/p99 ms | read `2/5`, write `5/15` (03, 04, 07: × 10) | `LAT_READ=1/4 LAT_WRITE=-/8` |

The dataset is written once per deployment, in 1 MiB blocks (`-b 1m --direct`), by the first test that needs it; the
other tests reuse it. Tests 08/09 use a second deployment with its own target and dataset.

Every run prints a summary with IOPS, MiB/s, read and write latency (avg, p99 ...), the CPU use of the busiest pod and a
`TARGET ... within / OVER the target` line, and appends one row per phase to `benchmarks/results/summary.csv`.

## The tests

### 01 – Max write IOPS

4k random writes (`--direct`) to the dataset files.  
Defaults: `BS=4k` `THREADS=16` `IODEPTH=16` (256 IOs in flight per pod).

```bash
./benchmarks/nfs/01-write-iops.sh $N PODS=4
./benchmarks/nfs/01-write-iops.sh $N PODS=auto THREADS=16 IODEPTH=32
./benchmarks/nfs/01-write-iops.sh $N PODS=4 BS=8k DURATION=1800   # steady state of the flash
```

### 02 – Max read IOPS

4k random reads of the prepared dataset.  
Defaults: `BS=4k` `THREADS=16` `IODEPTH=16`.

```bash
./benchmarks/nfs/02-read-iops.sh $N PODS=4
./benchmarks/nfs/02-read-iops.sh $N PODS=auto IODEPTH=64
./benchmarks/nfs/02-read-iops.sh $N PODS=4 DATASET_SIZE=8t   # a dataset far beyond the cache
```

### 03 – Max write throughput

Sequential writes of large blocks.  
Defaults: `BS=1m` `THREADS=8` `IODEPTH=4`.

```bash
./benchmarks/nfs/03-write-throughput.sh $N PODS=4
./benchmarks/nfs/03-write-throughput.sh $N PODS=auto BS=4m
./benchmarks/nfs/03-write-throughput.sh $N PODS=4 BLOCKVARPCT=50   # 2:1 compressible data
```

### 04 – Max read throughput

Sequential reads of large blocks from the dataset.  
Defaults: `BS=1m` `THREADS=8` `IODEPTH=4`.

```bash
./benchmarks/nfs/04-read-throughput.sh $N PODS=4
./benchmarks/nfs/04-read-throughput.sh $N PODS=auto BS=4m IODEPTH=8
```

### 05 – 70/30 mix, 32k-128k

70% reads / 30% writes, random, every IO 32k, 64k or 128k (`--rwmixpct`).  
Defaults: `BS_MIX=32k:1,64k:1,128k:1` `READ_PCT=70` `THREADS=16` `IODEPTH=8`.

```bash
./benchmarks/nfs/05-mix70-32k-128k.sh $N PODS=4
./benchmarks/nfs/05-mix70-32k-128k.sh $N PODS=4 READ_PCT=80 BS_MIX="16k:2,64k:1"
```

### 06 – 70/30 mix, 4k

The same with 4k IOs.  
Defaults: `BS_MIX=4k` `READ_PCT=70` `THREADS=16` `IODEPTH=16`.

```bash
./benchmarks/nfs/06-mix70-4k.sh $N PODS=4
./benchmarks/nfs/06-mix70-4k.sh $N PODS=4 READ_PCT=50
```

### 07 – 70/30 mix, 256k-1m

The same with large IOs.  
Defaults: `BS_MIX=256k:1,512k:1,1m:1` `THREADS=8` `IODEPTH=4`.

```bash
./benchmarks/nfs/07-mix70-256k-1m.sh $N PODS=4
```

### 08 – Read IOPS on one target

Like 02, but all pods on the same files in ONE directory of the export. Shows whether one volume is a bottleneck. The whole `DATASET_SIZE` is on the one target.  
Defaults: as 02.

```bash
./benchmarks/nfs/08-single-target-read-iops.sh $N PODS=4
```

### 09 – Write IOPS on one target

Like 01, on the one shared target.  
Defaults: as 01.

```bash
./benchmarks/nfs/09-single-target-write-iops.sh $N PODS=4
```

### 10 – Latency at queue depth 1

4k random read, then 4k random write, one thread, one IO at a time: the pure latency with p99, p99.9, p99.99.  
Defaults: `BS=4k`, 1 thread, QD1, 5 min each phase.

```bash
./benchmarks/nfs/10-latency-qd1.sh $N PODS=1
./benchmarks/nfs/10-latency-qd1.sh $N PODS=1 BS=16k
```

### 11 – Metadata

Create, stat and delete many empty files and directories (operations/s and latency).  
Defaults: `META_FILES=10000` files per thread, `THREADS=16`; `META_DIRS` = one directory per 1000 files.

```bash
./benchmarks/nfs/11-metadata.sh $N PODS=4
./benchmarks/nfs/11-metadata.sh $N PODS=4 META_FILES=10000 META_DIRS=1   # large directories
./benchmarks/nfs/11-metadata.sh $N PODS=4 META_FILES=10000 META_DIRS=1000   # many small directories
```

### 14 – AI training (MLPerf Storage style)

All pods read the whole sample dataset in a new random order every epoch, then write their checkpoint shard
(`CKPT_MODE=sync`, or `async` during the next epoch's reads), and finally read the last checkpoint back.  
Defaults: `TRAIN_PRESET=resnet50` (100,000 samples of 115k), `EPOCHS=3`, `TRAIN_THREADS=8`, `CKPT_SIZE=8g` per pod.

```bash
./benchmarks/nfs/14-ai-training.sh $N PODS=8
./benchmarks/nfs/14-ai-training.sh $N PODS=8 TRAIN_PRESET=unet3d CKPT_MODE=async TRAIN_REQUIRED_MIBS=1500
./benchmarks/nfs/14-ai-training.sh $N PODS=8 TRAIN_PRESET=custom TRAIN_SAMPLES=500000 TRAIN_SIZE_MIX="64k:1,256k:2,1m:1"
```

### 15 – AI inference

`load`: every pod reads the full model at the same time (cold start); `lookup`: small random reads at queue depth 1
(RAG / index); `kvcache`: 50/50 read/write of 2m chunks.  
Defaults: `MODEL_SIZE=16g` in `MODEL_SHARDS=4`, `LOAD_THREADS=16`, `INF_PHASES="load lookup kvcache"`.

```bash
./benchmarks/nfs/15-ai-inference.sh $N PODS=16
./benchmarks/nfs/15-ai-inference.sh $N PODS=16 MODEL_SIZE=140g MODEL_SHARDS=30
./benchmarks/nfs/15-ai-inference.sh $N PODS=8 INF_PHASES=lookup LOOKUP_THREADS=16
```

### 17 – Find the maximum within the latency target

A pod on every node (`PODS=auto`, `CPU=auto`), `SWEEP_TEST` with a growing load: IODEPTH `1 2 4 … 128` (03/04/07: `1 … 32`) at `THREADS` 16 (8), 5 min per step. It stops when
the latency target is missed, when two steps gain less than 3%, or when the pods run out of CPU, and prints
`BEST within target` with the settings of the best step.

```bash
./benchmarks/nfs/17-find-max.sh $N SWEEP_TEST=01     # max write IOPS
./benchmarks/nfs/17-find-max.sh $N SWEEP_TEST=02     # max read IOPS
./benchmarks/nfs/17-find-max.sh $N SWEEP_TEST=03     # max write throughput
./benchmarks/nfs/17-find-max.sh $N SWEEP_TEST=04     # max read throughput
./benchmarks/nfs/17-find-max.sh $N SWEEP_TEST=02 LAT_READ=1/3 DURATION=120     # own target, 2-min steps
./benchmarks/nfs/17-find-max.sh $N SWEEP_TEST=01 THREADS=32 SWEEP_IODEPTH="8 16 32 64 128 256"     # own ladder
```

### 12 – Sweeps: one value at several steps, one table

`SWEEP_PODS` defaults to `1 2 4 8`, so give it for a fixed pod count too.

```bash
./benchmarks/nfs/12-scaling-sweep.sh $N SWEEP_TEST=02 SWEEP_PODS="8 4 2 1"                        # load generators
./benchmarks/nfs/12-scaling-sweep.sh $N SWEEP_TEST=02 SWEEP_PODS=4 SWEEP_THREADS="8 16 32 64"     # threads
./benchmarks/nfs/12-scaling-sweep.sh $N SWEEP_TEST=01 SWEEP_PODS=4 SWEEP_IODEPTH="1 2 4 8 16 32 64 128"   # queue depth
./benchmarks/nfs/12-scaling-sweep.sh $N SWEEP_TEST=02 SWEEP_PODS=4 SWEEP_NCONNECT="1 4 8 16"         # nconnect
./benchmarks/nfs/12-scaling-sweep.sh $N SWEEP_TEST=02 SWEEP_PODS=4 SWEEP_DATASET_SIZE="100g 400g 1600g"  # where the cache ends
```

## Several tests, comparisons, by hand

```bash
# all basic tests (01..11) on one deployment, one after the other
./benchmarks/run-suite.sh nfs $N PODS=auto
./benchmarks/run-suite.sh nfs $N TESTS="01 02 03 04" PODS=auto CONTINUE=1

# the same tests on two systems, side by side (default: find-max on 01 02 03 04)
./benchmarks/compare.sh nfs TARGETS="old=10.0.0.10 new=10.0.0.20" NFS_PATH=/export/bench

# only deploy the pods and run elbencho yourself (prints the commands)
./benchmarks/deploy.sh nfs $N PODS=auto

# remove the deployments and volumes of this protocol
./benchmarks/cleanup.sh nfs
```
