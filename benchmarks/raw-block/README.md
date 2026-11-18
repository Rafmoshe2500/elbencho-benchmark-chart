# Raw block devices (volumeMode: Block): how to run every test

Every daemon gets its own PVC from `STORAGE_CLASS` as a raw device at `/dev/elbencho` (no filesystem). **The tests overwrite the device.**

All variables, what they change, and the background are in [../README.md](../README.md). Every value is `KEY=VALUE`,
as an argument or an environment variable; arguments win.

## Connection (needed by every command)

```bash
B="STORAGE_CLASS=my-block-sc"
```

| Key | Default | Meaning |
|---|---|---|
| `STORAGE_CLASS` | – (required) | supports `volumeMode: Block` |
| `ACCESS_MODE` | ReadWriteOnce | `ReadWriteMany` lets tests 08/09 spread over nodes |
| `PVC_SIZE` | sized for the dataset | volume per daemon; larger existing volumes are reused |

## Defaults of every test

| | Default | Change with |
|---|---|---|
| load generators | 2 pods (test 17: one per node) | `PODS=4`, `PODS=auto` (one per node), `PODS_PER_NODE=2` |
| CPU per pod | none (with `PODS=auto`: 80% of the free CPU of the weakest node) | `CPU=16`, `CPU=auto`, `CPU_SHARE=90` |
| duration of every measured phase | 300 s (5 min) | `DURATION=60` (quick), `DURATION=1800` (steady state) |
| dataset | 4t (4 TiB) in total; the tested range of every device = `DATASET_SIZE / PODS` | `DATASET_SIZE=10t` |
| latency target, avg/p99 ms | read `2/5`, write `2/10` (03, 04, 07: × 10) | `LAT_READ=1/4 LAT_WRITE=-/8` |

The dataset is written once per deployment, in 1 MiB blocks (`-b 1m --direct`), by the first test that needs it; the
other tests reuse it. Tests 08/09 use a second deployment with its own target and dataset.

Every run prints a summary with IOPS, MiB/s, read and write latency (avg, p99 ...), the CPU use of the busiest pod and a
`TARGET ... within / OVER the target` line, and appends one row per phase to `benchmarks/results/summary.csv`.

## The tests

### 01 – Max write IOPS

4k random writes (`--direct`) to /dev/elbencho.  
Defaults: `BS=4k` `THREADS=16` `IODEPTH=16` (256 IOs in flight per pod).

```bash
./benchmarks/raw-block/01-write-iops.sh $B PODS=4
./benchmarks/raw-block/01-write-iops.sh $B PODS=auto THREADS=16 IODEPTH=32
./benchmarks/raw-block/01-write-iops.sh $B PODS=4 BS=8k DURATION=1800   # steady state of the flash
```

### 02 – Max read IOPS

4k random reads of the prepared dataset.  
Defaults: `BS=4k` `THREADS=16` `IODEPTH=16`.

```bash
./benchmarks/raw-block/02-read-iops.sh $B PODS=4
./benchmarks/raw-block/02-read-iops.sh $B PODS=auto IODEPTH=64
./benchmarks/raw-block/02-read-iops.sh $B PODS=4 DATASET_SIZE=8t   # a dataset far beyond the cache
```

### 03 – Max write throughput

Sequential writes of large blocks.  
Defaults: `BS=1m` `THREADS=8` `IODEPTH=4`.

```bash
./benchmarks/raw-block/03-write-throughput.sh $B PODS=4
./benchmarks/raw-block/03-write-throughput.sh $B PODS=auto BS=4m
./benchmarks/raw-block/03-write-throughput.sh $B PODS=4 BLOCKVARPCT=50   # 2:1 compressible data
```

### 04 – Max read throughput

Sequential reads of large blocks from the dataset.  
Defaults: `BS=1m` `THREADS=8` `IODEPTH=4`.

```bash
./benchmarks/raw-block/04-read-throughput.sh $B PODS=4
./benchmarks/raw-block/04-read-throughput.sh $B PODS=auto BS=4m IODEPTH=8
```

### 05 – 70/30 mix, 32k-128k

70% reads / 30% writes, random, every IO 32k, 64k or 128k (`--rwmixpct`).  
Defaults: `BS_MIX=32k:1,64k:1,128k:1` `READ_PCT=70` `THREADS=16` `IODEPTH=8`.

```bash
./benchmarks/raw-block/05-mix70-32k-128k.sh $B PODS=4
./benchmarks/raw-block/05-mix70-32k-128k.sh $B PODS=4 READ_PCT=80 BS_MIX="16k:2,64k:1"
```

### 06 – 70/30 mix, 4k

The same with 4k IOs.  
Defaults: `BS_MIX=4k` `READ_PCT=70` `THREADS=16` `IODEPTH=16`.

```bash
./benchmarks/raw-block/06-mix70-4k.sh $B PODS=4
./benchmarks/raw-block/06-mix70-4k.sh $B PODS=4 READ_PCT=50
```

### 07 – 70/30 mix, 256k-1m

The same with large IOs.  
Defaults: `BS_MIX=256k:1,512k:1,1m:1` `THREADS=8` `IODEPTH=4`.

```bash
./benchmarks/raw-block/07-mix70-256k-1m.sh $B PODS=4
```

### 08 – Read IOPS on one target

Like 02, but all pods on ONE PVC (ReadWriteOnce: on the same node; `ACCESS_MODE=ReadWriteMany` lets them spread). Shows whether one volume is a bottleneck. The whole `DATASET_SIZE` is on the one target.  
Defaults: as 02.

```bash
./benchmarks/raw-block/08-single-target-read-iops.sh $B PODS=4
```

### 09 – Write IOPS on one target

Like 01, on the one shared target.  
Defaults: as 01.

```bash
./benchmarks/raw-block/09-single-target-write-iops.sh $B PODS=4
```

### 10 – Latency at queue depth 1

4k random read, then 4k random write, one thread, one IO at a time: the pure latency with p99, p99.9, p99.99.  
Defaults: `BS=4k`, 1 thread, QD1, 5 min each phase.

```bash
./benchmarks/raw-block/10-latency-qd1.sh $B PODS=1
./benchmarks/raw-block/10-latency-qd1.sh $B PODS=1 BS=16k
```

### 17 – Find the maximum within the latency target

A pod on every node (`PODS=auto`, `CPU=auto`), `SWEEP_TEST` with a growing load: IODEPTH `1 2 4 … 128` (03/04/07: `1 … 32`) at `THREADS` 16 (8), 5 min per step. It stops when
the latency target is missed, when two steps gain less than 3%, or when the pods run out of CPU, and prints
`BEST within target` with the settings of the best step.

```bash
./benchmarks/raw-block/17-find-max.sh $B SWEEP_TEST=01     # max write IOPS
./benchmarks/raw-block/17-find-max.sh $B SWEEP_TEST=02     # max read IOPS
./benchmarks/raw-block/17-find-max.sh $B SWEEP_TEST=03     # max write throughput
./benchmarks/raw-block/17-find-max.sh $B SWEEP_TEST=04     # max read throughput
./benchmarks/raw-block/17-find-max.sh $B SWEEP_TEST=02 LAT_READ=1/3 DURATION=120     # own target, 2-min steps
./benchmarks/raw-block/17-find-max.sh $B SWEEP_TEST=01 THREADS=32 SWEEP_IODEPTH="8 16 32 64 128 256"     # own ladder
```

### 12 – Sweeps: one value at several steps, one table

`SWEEP_PODS` defaults to `1 2 4 8`, so give it for a fixed pod count too.

```bash
./benchmarks/raw-block/12-scaling-sweep.sh $B SWEEP_TEST=02 SWEEP_PODS="8 4 2 1"                        # load generators
./benchmarks/raw-block/12-scaling-sweep.sh $B SWEEP_TEST=02 SWEEP_PODS=4 SWEEP_THREADS="8 16 32 64"     # threads
./benchmarks/raw-block/12-scaling-sweep.sh $B SWEEP_TEST=01 SWEEP_PODS=4 SWEEP_IODEPTH="1 2 4 8 16 32 64 128"   # queue depth
./benchmarks/raw-block/12-scaling-sweep.sh $B SWEEP_TEST=02 SWEEP_PODS=4 SWEEP_DATASET_SIZE="100g 400g 1600g"  # where the cache ends
```

## Several tests, comparisons, by hand

```bash
# all basic tests (01..10) on one deployment, one after the other
./benchmarks/run-suite.sh raw-block $B PODS=auto
./benchmarks/run-suite.sh raw-block $B TESTS="01 02 03 04" PODS=auto CONTINUE=1

# the same tests on two systems, side by side (default: find-max on 01 02 03 04)
./benchmarks/compare.sh raw-block TARGETS="arrayA=sc-array-a arrayB=sc-array-b"

# only deploy the pods and run elbencho yourself (prints the commands)
./benchmarks/deploy.sh raw-block $B PODS=auto

# remove the deployments and volumes of this protocol
./benchmarks/cleanup.sh raw-block
```
