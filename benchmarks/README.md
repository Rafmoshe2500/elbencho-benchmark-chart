# elbencho Load-Test Suite (NFS · XFS · Raw Block · S3)

Ready-made storage load tests on Kubernetes, built on the Helm chart in [`../charts/elbencho`](../charts/elbencho)
and the image `rafmoshe2500/elbencho:3.3-3` (built from ../Dockerfile, see the main README).

Each test deploys N elbencho daemons (a StatefulSet) plus a small controller pod, prepares a dataset when needed,
runs the measured phase from the controller with `elbencho --hosts ...`, and saves the results on your machine.

A visual guide (in Hebrew) with the flow diagram and recommended commands per protocol:
[`docs/benchmarks-guide.html`](../docs/benchmarks-guide.html).

**Requirements:** `bash`, `kubectl` (pointing at the cluster), `helm`. Nothing else, not even python.
On Windows, use WSL or Git Bash.

```
benchmarks/
├── nfs/  xfs/  raw-block/  s3/      one folder per protocol
│   ├── profile.env                  protocol defaults (nconnect, StorageClass, endpoint, ...)
│   └── 01-write-iops.sh ... 17-find-max.sh       (tests that don't apply to a protocol are not there)
├── run-suite.sh                     run several tests in a row
├── cleanup.sh                       remove deployments / PVCs
├── lib/                             engine (run.sh) + test definitions per family
└── results/                         created on first run (git-ignored)
```

## Quick start

```bash
# XFS: a StorageClass that formats volumes as XFS (CSI: parameters.csi.storage.k8s.io/fstype: xfs)
./benchmarks/xfs/02-read-iops.sh STORAGE_CLASS=my-xfs-sc PODS=4

# Raw block device: a StorageClass that supports volumeMode: Block
./benchmarks/raw-block/01-write-iops.sh STORAGE_CLASS=my-block-sc PODS=4 IODEPTH=32

# NFS: the chart mounts the export itself with your mount options
./benchmarks/nfs/04-read-throughput.sh NFS_SERVER=10.0.0.10 NFS_PATH=/export/bench NCONNECT=16 PODS=8

# S3
kubectl create namespace elbencho-bench
kubectl -n elbencho-bench create secret generic s3-creds \
  --from-literal=AWS_ACCESS_KEY_ID=... --from-literal=AWS_SECRET_ACCESS_KEY=...
./benchmarks/s3/02-read-iops.sh S3_ENDPOINT=http://minio.minio.svc:9000 S3_SECRET_NAME=s3-creds PODS=4

# The whole suite of one protocol (deployment and datasets are reused between the tests)
./benchmarks/run-suite.sh xfs STORAGE_CLASS=my-xfs-sc PODS=4 DURATION=120
./benchmarks/run-suite.sh s3 TESTS="01 02 05" S3_ENDPOINT=... S3_SECRET_NAME=s3-creds

# Queue-depth curve, AI training with async checkpoints, inference
./benchmarks/xfs/13-iodepth-sweep.sh STORAGE_CLASS=my-xfs-sc PODS=4
./benchmarks/nfs/14-ai-training.sh NFS_SERVER=10.0.0.10 NFS_PATH=/export TRAIN_PRESET=unet3d CKPT_MODE=async PODS=8
./benchmarks/s3/15-ai-inference.sh S3_ENDPOINT=... S3_SECRET_NAME=s3-creds MODEL_SIZE=140g PODS=16

# Find the maximum within a latency target, with a load generator on every node (see "Finding the maximum")
./benchmarks/s3/17-find-max.sh S3_ENDPOINT=... S3_SECRET_NAME=s3-creds SWEEP_TEST=02

# Remove everything of a protocol (StatefulSet PVCs and NFS PVs included)
./benchmarks/cleanup.sh xfs
```

Every parameter is `KEY=VALUE`, either as an argument (as above) or as an environment variable.
Arguments win over the environment, and both win over `profile.env` and the test defaults.

## The tests

| # | Test | NFS / XFS (files) | Raw block | S3 |
|---|---|---|---|---|
| 01 | Max write IOPS | 4k random write, `--direct`, threads × iodepth | same, on `/dev/elbencho` | PUT of 4k objects |
| 02 | Max read IOPS | 4k random read | same | GET of 4k objects (`--s3fastget`) |
| 03 | Max write throughput | 1m sequential write | same | multipart PUT, 256m objects, 16m parts |
| 04 | Max read throughput | 1m sequential read | same | GET with 16m ranges |
| 05 | 70/30 mix, 32k–128k | `--rwmixpct 70 --rand -b 32k:1,64k:1,128k:1` | same | 70% reader / 30% writer threads, objects of 32k/64k/128k |
| 06 | 70/30 mix, ≤4k | `-b 4k` (change with `BS_MIX`) | same | objects of 1k/2k/4k |
| 07 | 70/30 mix, 256k–1m | `-b 256k:1,512k:1,1m:1` | same | objects of 256k/512k/1m |
| 08 | Max read IOPS on ONE target | all pods on one PVC / one export dir | all pods on one device (same node) | all pods on one bucket |
| 09 | Max write IOPS on ONE target | same as 08, write | same | same |
| 10 | Latency at QD1 *(extra)* | 1 thread, iodepth 1, 4k random read + write, p99/p99.9/p99.99 | same | 1 thread PUT + GET |
| 11 | Metadata *(extra)* | create / stat / delete of many empty files | n/a | PUT / LIST / HEAD / DELETE |
| 12 | Scaling sweep *(extra)* | runs another test for `SWEEP_PODS="1 2 4 8"` (+ `SWEEP_NCONNECT` for NFS) and prints a table | same | same |
| 13 | IODEPTH sweep | runs another test (default 02) for `SWEEP_IODEPTH="1 2 4 8 16 32 64 128"`: IOPS, MiB/s, avg + p99 latency per depth | same | n/a |
| 14 | AI training | NFS: MLPerf-style epochs over a sample dataset + checkpoint + restore (see below) | n/a | same on S3 |
| 15 | AI inference | NFS: model load at cold start + lookups + KV-cache offload (see below) | n/a | same on S3 |
| 16 | Range reads | n/a | n/a | random byte-range GETs (`RANGE_BS`, default `64k:1,1m:2,8m:1`) at random offsets of large objects (`RANGE_OBJ_SIZE`, 256m). This is the Parquet/ORC pattern of Trino/Spark |
| 17 | Find max | load ladder on `SWEEP_TEST` (IODEPTH `1 … 128`) that stops at the latency target, at saturation, or when the daemons run out of CPU | same | same, with a THREADS ladder (`8 … 256`) and the default target avg 30 ms / p99 90 ms |

Tests 12 and 13 can be combined freely: `SWEEP_PODS`, `SWEEP_NCONNECT`, `SWEEP_THREADS`, `SWEEP_IODEPTH` and the dataset size
(`SWEEP_FILE_SIZE` for nfs/xfs, `SWEEP_DEV_SIZE` for raw-block, `SWEEP_OBJECTS` for s3) all work in both
(12 defaults to a pod sweep, 13 to an iodepth sweep at the current `PODS`). The table shows where IOPS stop growing
while p99 latency keeps rising.

**Two layouts:**
- **Tests 01–07 (multi):** every daemon has its **own** target, and the result is the total for the whole system.
  - XFS / raw block: one PVC per pod.
  - NFS: a private directory per pod on the export (`subPathExpr`).
  - S3: load spread over `BUCKETS` buckets.
  - File and block tests use `--nosvcshare`, so every daemon works on its full own dataset.
- **Tests 08–09 (single):** **one** target shared by all daemons. The dataset is split between them, which shows
  whether a single volume or bucket becomes the bottleneck.
  - A RWO volume (XFS / raw block) can only be shared by pods on the **same node**, so the runner adds the
    pod affinity for that. For multi-node sharing you need RWX: `ACCESS_MODE=ReadWriteMany`.

## Parameters

### General (all tests)
| Key | Default | Meaning |
|---|---|---|
| `PODS` | 2 (test 17: `auto`) | number of elbencho daemons (load-generating pods). `auto` = `PODS_PER_NODE` daemons on every Ready, schedulable node (`NODE_SELECTOR` narrows the set) |
| `PODS_PER_NODE` | 1 | `PODS=auto`: daemons per node. 1 uses a required anti-affinity, more use an even topology spread |
| `TOLERATE_ALL` | 1 with `PODS=auto`, else 0 | 1 = the pods tolerate every taint, so control-plane and other tainted nodes are used too. 0 = tainted nodes are skipped |
| `THREADS` | per test (16 / 8) | I/O threads per daemon |
| `IODEPTH` | per test (16 / 4 / 8) | async I/O queue depth per thread (libaio). Concurrency per pod = THREADS × IODEPTH. **No effect on the S3 IOPS tests** (see "Finding the maximum") |
| `BS` | 4k (IOPS), 1m (throughput) | block size. For S3 IOPS tests it is the object size (`OBJ_SIZE`), for S3 throughput the part size (16m) |
| `BS_MIX` | per test 05/06/07 | weighted block-size mix, e.g. `16k:2,64k:1` (2/3 16k, 1/3 64k) |
| `READ_PCT` | 70 | read share in tests 05–07 |
| `DURATION` | 60 (test 10: 30) | seconds per measured phase (`--timelimit` + `--infloop`) |
| `LAT_THREADS` / `LAT_IODEPTH` | 1 / 1 | test 10 only |
| `CPU` | – (`auto` with `PODS=auto`) | CPU request per daemon pod, e.g. `CPU=8`. `auto` = `CPU_SHARE` % of the free CPU (allocatable minus the requests of other pods) of the weakest node, divided between its daemons, in whole cores. `none` = no request |
| `CPU_SHARE` / `CPU_LIMIT` | 80 / 0 | share used by `CPU=auto`. `CPU_LIMIT=1` adds a limit equal to the request (Guaranteed QoS, exclusive cores with the static CPU manager). The default is no limit, because CFS throttling shows up as storage latency |
| `MEMORY` | – | request = limit per daemon, e.g. `MEMORY=16Gi` |
| `LAT_AVG_MAX` / `LAT_P99_MAX` | – (S3: 30 / 90) | latency target in ms (average / p99). Every run prints whether it met the target; test 17 stops there. `LAT_AVG_MAX=` switches one off |
| `CLIENT_CPU` / `CLIENT_CPU_MAX` | 1 / 80 | measure the CPU the daemons used in every measured phase; above this % of its CPU the busiest daemon makes the result `CLIENT-LIMITED` |
| `SPREAD` | preferred | spread daemons over nodes: `preferred`, `required` (one per node), `even` (same number on every node), `none` |
| `NODE_SELECTOR` | – | e.g. `NODE_SELECTOR=role=bench` |
| `PREPARE` | auto | dataset creation: `auto` (once per deployment/size), `always`, `never` |
| `KEEP` | 1 | keep the deployment after the test (faster next test). `KEEP=0` removes it |
| `LAT` | 1 | latency average + percentiles |
| `EXTRA_ARGS` | – | extra elbencho args for the measured phase, e.g. `"--cpu --svcelapsed"` |
| `NAMESPACE` | elbencho-bench | |
| `IMAGE_REPO` / `IMAGE_TAG` | chart default | e.g. a mirror in an air-gapped cluster |
| `HELM_ARGS` | – | extra helm args, e.g. `"--set tolerations[0].operator=Exists"` |
| `STORAGE_CACHE` | – | cache of the **storage system**: controller DRAM/NVRAM + SSD cache, e.g. `512g`. Not the pod's or node's RAM (`--direct` bypasses that). See "Dataset vs. storage cache" |
| `CACHE_FACTOR` / `CACHE_CHECK` | 2 / warn | required dataset ≥ factor × cache; `warn`, `fail` (stop before deploying) or `off` |
| `BLOCKVARPCT` | – (elbencho default 100) | content of written data, see "Data reduction" |
| `AIO` | auto | async IO (libaio, used when `IODEPTH` > 1) on nfs/xfs/raw-block. `auto`: checked once per run in a pod, and if the cluster blocks it, `THREADS × IODEPTH` threads with `IODEPTH=1` are used instead. `emulate`: always do that. `native`: no check, no fallback. `AIO_MAX_THREADS` (1024) caps the thread count. See "Async IO blocked" |
| `DETACH` | 1 | benchmarks run detached in the controller pod and survive a lost connection (VPN/SSH/laptop sleep). Output is polled every `POLL` (5) s, and the runner gives up after `RECONNECT_TIMEOUT` (3600) s offline. Ctrl+C stops the benchmark in the cluster too |

### NFS ([nfs/profile.env](nfs/profile.env))
| Key | Default | Meaning |
|---|---|---|
| `NFS_SERVER`, `NFS_PATH` | – , `/` | the chart creates the NFS PV and mounts it with the options below |
| `NFS_STORAGE_CLASS` | – | alternative: an existing NFS StorageClass (RWX). Mount options then come from the StorageClass |
| `NFS_VERS` | 4.1 | `3`, `4.0`, `4.1`, `4.2` |
| `NCONNECT` | 8 | TCP connections per mount (0 = off). Changing it restarts the daemons |
| `RSIZE` / `WSIZE` | 1048576 | try 65536 for small random IO |
| `NFS_EXTRA_OPTS` | hard | e.g. `hard,noatime,actimeo=0` |
| `FILES`, `FILE_SIZE` | 8, 4g | dataset per daemon |

### XFS ([xfs/profile.env](xfs/profile.env)) and raw block ([raw-block/profile.env](raw-block/profile.env))
| Key | Default | Meaning |
|---|---|---|
| `STORAGE_CLASS` | – (required) | XFS: formats volumes as XFS (the runner checks `/data` really is XFS). Block: supports `volumeMode: Block` |
| `PVC_SIZE` | 50Gi | per daemon (tests 01–07) / shared (08–09) |
| `FILES`, `FILE_SIZE` | 8, 4g | XFS dataset. Must fit into `PVC_SIZE` |
| `DEV_SIZE` | whole device | raw block: limit the tested range |
| `ACCESS_MODE` | ReadWriteOnce | |

### S3 ([s3/profile.env](s3/profile.env))
| Key | Default | Meaning |
|---|---|---|
| `S3_ENDPOINT` | – (required) | e.g. `http://minio.minio.svc:9000` |
| `S3_SECRET_NAME` | – | Secret with `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` (recommended) |
| `S3_ACCESS_KEY` / `S3_SECRET_KEY` | – | alternative: the runner creates the Secret. Keys are never written to the results |
| `S3_REGION` | – | |
| `BUCKET_PREFIX`, `BUCKETS` | elbencho, 4 | multi tests: `elbencho-1..4`; single tests: `elbencho-single`; mixes: `elbencho-mix` |
| `OBJ_SIZE`, `OBJECTS` | 4k, 1000 | IOPS tests: object size, objects per thread |
| `TPUT_OBJ_SIZE`, `TPUT_OBJECTS` | 256m, 4 | throughput tests |
| `MIX_OBJECTS` | 20000 | size of the mixed-size dataset (tests 05–07) |
| `LAT_AVG_MAX` / `LAT_P99_MAX` | 30 / 90 | latency target of S3 runs in ms |

## Finding the maximum

elbencho is a closed loop: every thread sends a request and waits for the answer. So the number of requests in
flight and the latency set the ceiling, whatever the storage could do:

```
concurrency = PODS × THREADS × IODEPTH          (S3 IOPS tests 01/02/08/09: PODS × THREADS)
IOPS        = concurrency × 1000 / latency_ms
MiB/s       = IOPS × block_size_MiB
concurrency needed = target_IOPS × latency_ms / 1000
```

Measured with elbencho 3.3-3 against a server that answers immediately, on one virtual core (orders of magnitude;
https and other hardware differ):

| | requests in flight | per daemon core |
|---|---|---|
| S3, 4k objects | PODS × THREADS. `--iodepth` changes nothing for whole-object PUT/GET: 4 threads at iodepth 8 put exactly 4 requests on the wire | ~5,000 PUT/s, ~4,500 GET/s |
| S3, multipart / ranged | PODS × THREADS × IODEPTH | ~600 MiB/s PUT, ~2,000 MiB/s GET |
| files / block, 4k `--direct` | PODS × THREADS × IODEPTH | ~175,000–260,000 IOPS (libaio) |
| NFS | as files, but at most the NFSv4.1 session slots per node (Linux client default 64, `nfs.max_session_slots`). Pods on one node usually share the connections and the session, so more nodes help, more pods per node hardly do | |

**A saturated load generator looks exactly like slow storage:** the result stops growing and the measured latency
rises. In the measurement above the server answered in 0.2 ms, and 16 threads on one core reported 3–4 ms. So every
measured phase reads the CPU time of the daemon containers from their cgroup counters. The summary has a `CPU%`
column (busiest daemon, in % of its CPU request, or of the node's cores without a request), and a run above
`CLIENT_CPU_MAX` is marked `CLIENT-LIMITED`: add `PODS` or `CPU`, not threads.

`17-find-max.sh` automates the search:

```bash
./benchmarks/s3/17-find-max.sh S3_ENDPOINT=... S3_SECRET_NAME=s3-creds SWEEP_TEST=01   # write IOPS
./benchmarks/s3/17-find-max.sh S3_ENDPOINT=... S3_SECRET_NAME=s3-creds SWEEP_TEST=02   # read IOPS
./benchmarks/s3/17-find-max.sh S3_ENDPOINT=... S3_SECRET_NAME=s3-creds SWEEP_TEST=03   # write throughput
./benchmarks/s3/17-find-max.sh S3_ENDPOINT=... S3_SECRET_NAME=s3-creds SWEEP_TEST=04   # read throughput
./benchmarks/nfs/17-find-max.sh NFS_SERVER=... NFS_PATH=/export SWEEP_TEST=02 LAT_P99_MAX=5
```

- It deploys a daemon on every node (`PODS=auto`, `CPU=auto`) and runs `SWEEP_TEST` with a growing load:
  `SWEEP_THREADS` for S3 (default `8 16 32 64 128 256`, throughput `2 … 64`), `SWEEP_IODEPTH` for the others.
- It stops at the first step that misses the latency target (`over target`), that is `CLIENT-LIMITED`, or after two
  steps that gain less than `MIN_GAIN` % (3) over the best so far (saturated). `FIND_STOP=0` runs the whole ladder.
- It prints every step and `BEST within target`: the best step that met the target, with its `PODS` and `THREADS`.
  The table is saved as `results/sweep-<time>.txt`. The same verdict column is printed by tests 12 and 13.

S3 datasets are per thread, and a run with fewer pods or threads reads a subset of a larger dataset. So a new
prepare happens only when a run needs more threads × pods than were prepared; the read IOPS ladder writes its
dataset once, for its highest step.

Give `S3_ENDPOINT` all VIPs / nodes of the storage, comma separated: elbencho spreads the threads over them.

`CPU` is the request of the whole pod. S3 and NFS pods run two elbencho containers; the second one gets a share
only in the tests that use it (S3 mixes, async checkpoints).

## Dataset vs. storage cache

If the dataset fits into the storage system's cache, you measure the cache, not the disks. Every run prints the
dataset size of its measured phase. With `STORAGE_CACHE` set, it compares the dataset with the cache: it warns, or
with `CACHE_CHECK=fail` stops before deploying, when the dataset is smaller than `CACHE_FACTOR` × cache.

To find the cache size:
- **Vendor arrays:** controller memory of all controllers, plus the SSD cache tier.
- **Linux NFS server:** its RAM (`free -g`).
- **Ceph:** `osd_memory_target` × number of OSDs.
- **MinIO:** the RAM of its nodes.
- **Cloud disks:** no relevant cache.

Or measure it, by sweeping the dataset size. The point where IOPS drop is where the cache ends:

```bash
./benchmarks/nfs/12-scaling-sweep.sh NFS_SERVER=... SWEEP_TEST=02 SWEEP_PODS=4 SWEEP_FILE_SIZE="4g 16g 64g 256g"
```

## Data reduction (`BLOCKVARPCT`)

`BLOCKVARPCT` is applied to every write phase, prepare included. Measured on the written files:

| `BLOCKVARPCT` | compression | dedup | looks like |
|---|---|---|---|
| unset (= 100) | 1:1 | none | encrypted / already compressed data: no help from data reduction (worst case) |
| 50 | ~2:1 | none | typical databases, logs, documents |
| 0 | 1:1 | very high (one block per thread, repeated) | clones, VM images, backups |

Arrays with inline compression/dedup report very different numbers for the three settings, and the gap shows how
much the array's data reduction contributes.

## AI workloads (tests 14, 15)

Both tests use **one shared dataset** for all pods, like a real training cluster or inference fleet: the NFS
export (no per-pod sub dirs), or the bucket `<BUCKET_PREFIX>-ai`.

### 14 – Training (MLPerf Storage / DLIO style)
1. **Dataset:** `TRAIN_SAMPLES` files, one sample per file, written once.
2. **Every epoch:** all pods read the **whole dataset in a new random order** (`--treerand`). The samples are
   split between the pods (data parallel), with `TRAIN_THREADS` data-loader workers per pod.
3. **Checkpoint** every `CKPT_EVERY` epochs: every pod writes its shard (`CKPT_SIZE` per pod, `CKPT_THREADS`
   files) at the same time.
   - `CKPT_MODE=sync`: training waits for the checkpoint.
   - `CKPT_MODE=async`: the next epoch's reads run during the checkpoint write. This shows how much a background
     checkpoint slows the data loading.
4. **Restore:** all pods read the last checkpoint back (resume after a failure).
5. **Optional accelerator emulation:** `TRAIN_REQUIRED_MIBS` = MiB/s that one pod's GPUs consume. The readers are
   rate-limited to that, and the result shows the **keep-up %**. Below ~100% means the storage is the bottleneck.
   This is the same idea as MLPerf's accelerator-utilization threshold.

| Key | Default | Meaning |
|---|---|---|
| `TRAIN_PRESET` | resnet50 | `resnet50` (115k samples), `cosmoflow` (2.8m), `unet3d` (147m): average MLPerf sample sizes. `custom` |
| `TRAIN_SAMPLES` | per preset (100000 / 4000 / 80) | number of samples. **Make the dataset larger than the RAM/cache of the storage** |
| `TRAIN_SAMPLE_SIZE` / `TRAIN_SIZE_MIX` | preset | fixed size, or a weighted mix like `64k:1,128k:2,256k:1` |
| `EPOCHS` | 3 | |
| `TRAIN_THREADS` | 8 | readers (data-loader workers) per pod |
| `TRAIN_BS` | 1m (S3: 16m) | read request size |
| `TRAIN_DIRECT` | 1 | O_DIRECT for NFS (no client cache) |
| `TRAIN_REQUIRED_MIBS` | – | accelerator demand per pod → keep-up % |
| `CKPT_SIZE`, `CKPT_THREADS`, `CKPT_BS` | 8g, 8, 4m (S3: 16m) | checkpoint shard per pod |
| `CKPT_EVERY`, `CKPT_MODE`, `RESTORE` | 1, sync, 1 | |

### 15 – Inference
`INF_PHASES` (default `load lookup kvcache`) selects the phases:
- **load (cold start):** every replica reads the **full model** (`MODEL_SIZE` in `MODEL_SHARDS` shards) at the same
  time with `LOAD_THREADS` parallel readers, like model streamers do. Reports the **load time of the slowest
  replica** and MiB/s per replica. The model is written once by a single pod.
- **lookup:** small random reads at queue depth 1 in a shared index (RAG / embeddings / feature store).
  - Files: block sizes from `LOOKUP_BS_MIX` (default `4k:1,16k:1,64k:1`) in `INDEX_SIZE`.
  - S3: GETs of `LOOKUP_OBJ_SIZE` objects.
  - Reports latency percentiles.
- **kvcache:** KV-cache offload, 50/50 read/write of `KV_BS` (default 2m) chunks.

| Key | Default |
|---|---|
| `MODEL_SIZE`, `MODEL_SHARDS`, `LOAD_THREADS`, `LOAD_BS`, `LOAD_DIRECT` | 16g, 4, 16, 4m (S3: 16m), 1 |
| `INDEX_SIZE`, `LOOKUP_BS_MIX`, `LOOKUP_THREADS` | 8g, `4k:1,16k:1,64k:1`, 8 |
| `LOOKUP_OBJ_SIZE`, `LOOKUP_OBJECTS` (S3) | 64k, 2000 per thread |
| `KV_SIZE`, `KV_BS`, `KV_THREADS`, `KV_IODEPTH` | 16g, 2m, 8, 4 |
| `KV_OBJECTS` (S3) | 200 per thread |

The NFS daemons run two elbencho services per pod (ports 1611/1612), so that async checkpoints and S3 mixes can
run two coordinated benchmarks at once.

## Results

Each run writes `results/<protocol>/<NN-test>/<timestamp>/`:
- `summary.txt`: the table printed at the end (IOPS, read IOPS, MiB/s, avg latency, percentiles)
- `*.csv` / `*.txt`: elbencho result files for each phase (`prepare`, measured phases)
- `console.log`: full output
- `params.env` + `values.yaml`: exactly what was run, so you can repeat it

All runs are also appended to **`results/summary.csv`**, one row per phase, for comparing runs in Excel or Sheets.
It includes the p99 latency, `nconnect`, iodepth, the elapsed time of the slowest pod, and the CPU use of the
busiest daemon (`client_cpu_pct`).

Numbers are elbencho's **"first done"** values: the rate while all workers were still running (no tail effect).
This is the right value for aggregate IOPS and throughput.

## Methodology notes

These come from elbencho's own examples, VAST Data's elbencho guides and the NFS tuning guides of Azure NetApp
Files and Google Cloud:

- **Bypass the client cache.** All file and block tests use `--direct`. Server-side caches still count, so make the
  dataset (`PODS × FILES × FILE_SIZE`) clearly larger than the storage's cache if you want media performance.
- **IOPS need concurrency:** threads × iodepth per pod × pods (S3 IOPS: threads × pods). Raise it until IOPS stop
  growing while latency keeps rising. That is the saturation point. Test 17 automates the search.
- **Throughput:** large sequential blocks (1m–4m) with fewer threads. For S3, use large objects with 16m+ parts.
- **Reads come from a prepared dataset.** Reads from never-written (thin) blocks are unrealistically fast, so raw
  devices are preconditioned with one full sequential write.
- **Steady state:** for SSD/flash write tests, use long runs (`DURATION=1800`) to get past write caches and garbage
  collection.
- **NFS:** `nconnect` has a big effect on IOPS (vendors report ~3× for 4k random reads). Compare with
  `./nfs/12-scaling-sweep.sh SWEEP_TEST=02 SWEEP_NCONNECT="1 4 8 16" SWEEP_PODS="4"`.
  Opinions differ on `rsize`/`wsize` (1M vs 64k), so measure both.
- **Spread the daemons over nodes** (`SPREAD=required`) so that the network and CPU of a single node don't
  become the limit.

## How the 70/30 mixes work
- **Files / block devices:** `--rwmixpct 70` makes every thread do 70% reads and 30% writes, at random offsets.
  `-b 32k:1,64k:1,128k:1` picks the size of every I/O from the weighted list (needs elbencho ≥ 3.2.1).
- **S3:** elbencho does not allow `--rwmixpct` with S3, and `--rwmixthr` cannot be combined with mixed object
  sizes. So the S3 runner runs **two coordinated elbencho runs** that start at the same second:
  - readers (70% of `THREADS`) GET a prepared dataset of mixed-size objects;
  - writers (30%) PUT objects of the same size mix under another prefix.
  
  The chart runs two elbencho services per pod for this (ports 1611 and 1612). The summary prints the
  **combined** result and the real read share that was achieved. elbencho's custom tree mode supports only one
  bucket, so the mixes use the bucket `<BUCKET_PREFIX>-mix`.

## Async IO blocked (`io_getevents failed ... Operation not permitted`)

```
ERROR: Getting async IO events (io_getevents) failed. NumPending: 16; ReturnCode: -1; ... SysErr: Operation not permitted
```

elbencho uses libaio for `--iodepth` > 1. The libaio in the official `breuner/elbencho` image (Ubuntu 24.04+) needs the
`io_pgetevents` syscall, which the CRI-O/OpenShift default seccomp profile denies. The `prepare` phase still works,
because it is plain synchronous IO.

- **Fix:** use the chart's default image `rafmoshe2500/elbencho:3.3-3` (static binary, see the main README and the
  `Dockerfile`), which works under that profile with any iodepth. If you set `IMAGE_REPO=breuner/elbencho`, you get
  this error again.
Check whether a filter is active in a pod: `grep Seccomp /proc/1/status` shows `2` when it is.

- **Nothing to do:** with `AIO=auto` (default) the runner detects this before the measured phase, prints a warning and
  runs with `THREADS × IODEPTH` threads at `IODEPTH=1`. This gives the same concurrency per pod and is the
  normal way to load NFS. The summary then shows the real thread count and `iodepth 1`.
  In `13-iodepth-sweep` the "iodepth" steps become thread counts. Only for a true libaio queue-depth curve you
  need the permanent fix.
- **Permanent fix:** run the pods without a seccomp filter. The chart supports it:
  `HELM_ARGS="--set securityContext.seccompProfile.type=Unconfined"`. On OpenShift the pods' service account needs an
  SCC that allows it (for example `oc adm policy add-scc-to-user privileged -z default -n elbencho-bench`, or a narrower custom
  SCC with `seccompProfiles: ["*"]`), which is a cluster admin decision.
- Check the result: the pod should then show `Seccomp: 0`, and the log line `async IO (libaio) works in the pods`.

## Only some of the pods come up

After a change of pod settings (`HELM_ARGS`, `CPU`, `NCONNECT`, ...) a plain StatefulSet replaces its pods one at a time and stops
at the first one that cannot start, so you see one new pod and the rest unchanged. The runner avoids this: when
the settings change, it restarts all daemons at once. If pods still do not become ready within `WAIT_TIMEOUT`
(default 10m), it prints the pod states and the latest warning events, which name the reason:

| Event | Meaning |
|---|---|
| `FailedCreate` on the StatefulSet: `unable to validate against any security context constraint` | OpenShift SCC. The service account of the pods may not use what they ask for (for example `seccompProfile: Unconfined`). Grant a suitable SCC to the account the pods run as |
| `FailedScheduling` | `SPREAD=required` needs one node per daemon; also `NODE_SELECTOR`, taints, CPU/memory requests |
| `FailedMount` / pending PVC | StorageClass or NFS mount problem |

By hand: `oc -n elbencho-bench get events --sort-by=.lastTimestamp | tail -20` and `oc -n elbencho-bench describe sts eb-nfs-elbencho`.
`oc -n elbencho-bench delete pod -l app.kubernetes.io/name=elbencho` restarts all daemons at once.

## Caveats
- **Stale dataset markers.** Datasets are prepared once and marked on the StatefulSet. If the data was deleted outside
  the suite (bucket emptied, export wiped), reads fail. Run once with `PREPARE=always`.
- **Raw block tests overwrite the whole device** of every PVC they create.
- **RWO sharing:** tests 08/09 on XFS or raw block put all pods on the same node (a RWO limit). Use `ACCESS_MODE=ReadWriteMany` with a
  storage that supports multi-node block/filesystem sharing.
- **S3 data is never deleted** by `cleanup.sh`. Use your S3 tools, or
  `elbencho --s3endpoints ... -D -F -n 1 -N <n> -t <t> bucket` from the controller pod.
- **Live progress** prints a line every 5 s (`LIVE=0` turns it off).
