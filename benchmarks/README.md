# elbencho Load-Test Suite (NFS · XFS · Raw Block · S3)

Ready-made storage load tests on Kubernetes, built on the Helm chart in [`../charts/elbencho`](../charts/elbencho)
and the official image `breuner/elbencho:v3.3-3`.

Each test deploys N elbencho daemons (a StatefulSet) plus a small controller pod, prepares a dataset when needed,
runs the measured phase from the controller with `elbencho --hosts ...`, and saves the results on your machine.

**Requirements:** `bash`, `kubectl` (pointing at the cluster), `helm`. Nothing else, not even python.
On Windows, use WSL or Git Bash.

```
benchmarks/
├── nfs/  xfs/  raw-block/  s3/      one folder per protocol
│   ├── profile.env                  protocol defaults (nconnect, StorageClass, endpoint, ...)
│   └── 01-write-iops.sh ... 15-ai-inference.sh   (tests that don't apply to a protocol are not there)
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

Tests 12 and 13 can be combined freely: `SWEEP_PODS`, `SWEEP_NCONNECT` and `SWEEP_IODEPTH` all work in both
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
| `PODS` | 2 | number of elbencho daemons (load-generating pods) |
| `THREADS` | per test (16 / 8) | I/O threads per daemon |
| `IODEPTH` | per test (16 / 4 / 8) | async I/O queue depth per thread (libaio). Concurrency per pod = THREADS × IODEPTH |
| `BS` | 4k (IOPS), 1m (throughput) | block size. For S3 IOPS tests it is the object size (`OBJ_SIZE`), for S3 throughput the part size (16m) |
| `BS_MIX` | per test 05/06/07 | weighted block-size mix, e.g. `16k:2,64k:1` (2/3 16k, 1/3 64k) |
| `READ_PCT` | 70 | read share in tests 05–07 |
| `DURATION` | 60 (test 10: 30) | seconds per measured phase (`--timelimit` + `--infloop`) |
| `LAT_THREADS` / `LAT_IODEPTH` | 1 / 1 | test 10 only |
| `CPU` / `MEMORY` | – | requests = limits per daemon, e.g. `CPU=8 MEMORY=16Gi` |
| `SPREAD` | preferred | spread daemons over nodes: `preferred`, `required`, `none` |
| `NODE_SELECTOR` | – | e.g. `NODE_SELECTOR=role=bench` |
| `PREPARE` | auto | dataset creation: `auto` (once per deployment/size), `always`, `never` |
| `KEEP` | 1 | keep the deployment after the test (faster next test). `KEEP=0` removes it |
| `LAT` | 1 | latency average + percentiles |
| `EXTRA_ARGS` | – | extra elbencho args for the measured phase, e.g. `"--cpu --svcelapsed"` |
| `NAMESPACE` | elbencho-bench | |
| `IMAGE_REPO` / `IMAGE_TAG` | chart default | e.g. a mirror in an air-gapped cluster |
| `HELM_ARGS` | – | extra helm args, e.g. `"--set tolerations[0].operator=Exists"` |

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
It includes the p99 latency, `nconnect`, iodepth, and the elapsed time of the slowest pod.

Numbers are elbencho's **"first done"** values: the rate while all workers were still running (no tail effect).
This is the right value for aggregate IOPS and throughput.

## Methodology notes

These come from elbencho's own examples, VAST Data's elbencho guides and the NFS tuning guides of Azure NetApp
Files and Google Cloud:

- **Bypass the client cache.** All file and block tests use `--direct`. Server-side caches still count, so make the
  dataset (`PODS × FILES × FILE_SIZE`) clearly larger than the storage's cache if you want media performance.
- **IOPS need concurrency:** threads × iodepth per pod × pods. Raise `IODEPTH` (16 → 32 → 64) and `PODS` until
  IOPS stop growing while latency keeps rising. That is the saturation point. Test 12 automates the search.
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

## Caveats
- **Raw block tests overwrite the whole device** of every PVC they create.
- **RWO sharing:** tests 08/09 on XFS or raw block put all pods on the same node (a RWO limit). Use `ACCESS_MODE=ReadWriteMany` with a
  storage that supports multi-node block/filesystem sharing.
- **S3 data is never deleted** by `cleanup.sh`. Use your S3 tools, or
  `elbencho --s3endpoints ... -D -F -n 1 -N <n> -t <t> bucket` from the controller pod.
- **Live progress** prints a line every 5 s (`LIVE=0` turns it off).
