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
├── compare.sh                       the same tests on two or more storage systems, side by side
├── deploy.sh                        only deploy the daemons, for elbencho runs by hand
├── cleanup.sh                       remove deployments / PVCs
├── lib/                             engine (run.sh) + test definitions per family
└── results/                         created on first run (git-ignored)
```

## Examples: every kind of run

Every parameter is `KEY=VALUE`, as an argument or as an environment variable. Arguments win over the environment,
and both win over `profile.env` and the test defaults. Every example works the same way on every protocol;
only the connection settings differ:

| protocol | connection settings |
|---|---|
| `raw-block` | `STORAGE_CLASS=<a StorageClass with volumeMode: Block>` |
| `xfs` | `STORAGE_CLASS=<a StorageClass that formats XFS>` (CSI: `parameters.csi.storage.k8s.io/fstype: xfs`) |
| `nfs` | `NFS_SERVER=10.0.0.10 NFS_PATH=/export/bench`, or `NFS_STORAGE_CLASS=<an RWX StorageClass>` |
| `s3` | `S3_ENDPOINT=http://s3-1:9000,http://s3-2:9000 S3_SECRET_NAME=s3-creds` (Secret: see below) |

```bash
B="STORAGE_CLASS=array-a"                                  # raw block / xfs
N="NFS_SERVER=10.0.0.10 NFS_PATH=/export/bench"            # nfs
S="S3_ENDPOINT=http://s3-1:9000,http://s3-2:9000 S3_SECRET_NAME=s3-creds"

# S3 credentials, once
kubectl create namespace elbencho-bench
kubectl -n elbencho-bench create secret generic s3-creds \
  --from-literal=AWS_ACCESS_KEY_ID=... --from-literal=AWS_SECRET_ACCESS_KEY=...
```

### 1. One test at a fixed load
```bash
./benchmarks/raw-block/01-write-iops.sh       $B PODS=4 THREADS=16 IODEPTH=32    # 4k random write
./benchmarks/raw-block/02-read-iops.sh        $B PODS=4 THREADS=16 IODEPTH=32    # 4k random read
./benchmarks/raw-block/03-write-throughput.sh $B PODS=4 BS=1m                    # sequential write
./benchmarks/raw-block/04-read-throughput.sh  $B PODS=4 BS=4m                    # sequential read
./benchmarks/xfs/05-mix70-32k-128k.sh         $B PODS=4 READ_PCT=80              # 80/20 random mix
./benchmarks/nfs/02-read-iops.sh              $N PODS=8 NCONNECT=16 RSIZE=65536
./benchmarks/s3/02-read-iops.sh               $S PODS=8 THREADS=64 OBJ_SIZE=64k
./benchmarks/xfs/08-single-target-read-iops.sh $B PODS=4      # all pods on ONE volume (same node for RWO)
./benchmarks/raw-block/10-latency-qd1.sh      $B PODS=1 DURATION=120              # pure latency, QD1
./benchmarks/nfs/11-metadata.sh               $N PODS=4                           # create / stat / delete
```

### 2. The maximum within the latency target (test 17)
A load generator on every node (`PODS=auto`, `CPU=auto`), growing load, stops at the latency target of the
protocol (see "Latency targets"). One run per direction and kind:
```bash
./benchmarks/raw-block/17-find-max.sh $B SWEEP_TEST=01     # max write IOPS   (IODEPTH 1 -> 128)
./benchmarks/raw-block/17-find-max.sh $B SWEEP_TEST=02     # max read IOPS
./benchmarks/raw-block/17-find-max.sh $B SWEEP_TEST=03     # max write MiB/s  (IODEPTH 1 -> 32, 1m blocks)
./benchmarks/raw-block/17-find-max.sh $B SWEEP_TEST=04     # max read MiB/s
./benchmarks/xfs/17-find-max.sh       $B SWEEP_TEST=01
./benchmarks/nfs/17-find-max.sh       $N SWEEP_TEST=02 NCONNECT=16
./benchmarks/s3/17-find-max.sh        $S SWEEP_TEST=02     # THREADS 8 -> 256

# own targets, longer steps, two daemons per node, only worker nodes
./benchmarks/raw-block/17-find-max.sh $B SWEEP_TEST=01 LAT_WRITE_AVG_MAX=1 LAT_WRITE_P99_MAX=5 \
  DURATION=180 PODS_PER_NODE=2 NODE_SELECTOR=node-role.kubernetes.io/worker= TOLERATE_ALL=0
# own ladder: more threads per pod and deeper queues
./benchmarks/raw-block/17-find-max.sh $B SWEEP_TEST=02 THREADS=32 SWEEP_IODEPTH="8 16 32 64 128 256"
```

### 3. Compare two storage systems (same tests, same pods, same dataset)
```bash
# two distributed block arrays: max write/read IOPS and MiB/s on each, then a table side by side
./benchmarks/compare.sh raw-block TARGETS="arrayA=sc-array-a arrayB=sc-array-b"
# the same on XFS, with fixed-load tests too
./benchmarks/compare.sh xfs TARGETS="arrayA=sc-array-a arrayB=sc-array-b" ITEMS="max:01 max:02 03 04 05"
# two NFS servers with different export paths
./benchmarks/compare.sh nfs TARGETS="old=10.0.0.10 new=10.0.0.20" ARGS_old="NFS_PATH=/vol1" ARGS_new="NFS_PATH=/exports/bench"
# two S3 systems
./benchmarks/compare.sh s3 TARGETS="minio=http://minio:9000 ceph=http://rgw:8080" S3_SECRET_NAME=s3-creds
```
See "Comparing storage systems" below.

### 4. Sweeps: how a value changes the result (tests 12, 13)
```bash
./benchmarks/raw-block/12-scaling-sweep.sh $B SWEEP_TEST=02 SWEEP_PODS="8 4 2 1"          # load generators
./benchmarks/raw-block/13-iodepth-sweep.sh $B SWEEP_TEST=01 PODS=4                         # queue depth 1..128
./benchmarks/xfs/12-scaling-sweep.sh       $B SWEEP_TEST=02 PODS=4 SWEEP_THREADS="4 8 16 32"
./benchmarks/nfs/12-scaling-sweep.sh       $N SWEEP_TEST=02 SWEEP_PODS=4 SWEEP_NCONNECT="1 4 8 16"
./benchmarks/s3/12-scaling-sweep.sh        $S SWEEP_TEST=01 SWEEP_PODS="2 4 8" SWEEP_THREADS="32 64"
# where the storage cache ends: the same test on a growing dataset
./benchmarks/xfs/12-scaling-sweep.sh       $B SWEEP_TEST=02 SWEEP_PODS=4 SWEEP_FILE_SIZE="16g 64g 256g"
./benchmarks/raw-block/12-scaling-sweep.sh $B SWEEP_TEST=02 SWEEP_PODS=4 SWEEP_DEV_SIZE="100g 400g 1600g"
```

### 5. A whole suite on one deployment
```bash
./benchmarks/run-suite.sh raw-block $B PODS=auto DURATION=120              # 01..10 (11 needs a filesystem)
./benchmarks/run-suite.sh xfs $B TESTS="01 02 03 04" PODS=8 CONTINUE=1     # continue after a failed test
./benchmarks/run-suite.sh s3 $S TESTS="01 02 05" PODS=8
```

### 6. Datasets, data content and cache
```bash
./benchmarks/raw-block/02-read-iops.sh $B DATASET_SIZE=10t                 # an explicit total dataset
./benchmarks/xfs/01-write-iops.sh      $B EXPECTED_IOPS=2000000            # dataset for 20 min at 2M IOPS
./benchmarks/nfs/02-read-iops.sh       $N STORAGE_CACHE=1t CACHE_CHECK=fail   # stop if the dataset < 2 x cache
./benchmarks/xfs/03-write-throughput.sh $B BLOCKVARPCT=50                  # 2:1 compressible data
./benchmarks/raw-block/01-write-iops.sh $B DURATION=1800                   # steady state of the flash
./benchmarks/raw-block/02-read-iops.sh $B PREPARE=always                   # write the dataset again
```

### 7. Pods, CPU and the cluster
```bash
./benchmarks/raw-block/02-read-iops.sh $B PODS=auto                         # a pod on every node, CPU=auto
./benchmarks/raw-block/02-read-iops.sh $B PODS=auto CPU=16 CPU_LIMIT=1      # 16 dedicated cores per pod
./benchmarks/raw-block/02-read-iops.sh $B PODS=6 SPREAD=required NODE_SELECTOR=role=bench MEMORY=8Gi
./benchmarks/xfs/01-write-iops.sh $B HELM_ARGS="--set securityContext.seccompProfile.type=Unconfined"
./benchmarks/raw-block/01-write-iops.sh $B IMAGE_REPO=registry.local/elbencho IMAGE_TAG=3.3-3
```

### 8. AI workloads (nfs, s3)
```bash
./benchmarks/nfs/14-ai-training.sh  $N TRAIN_PRESET=unet3d CKPT_MODE=async PODS=8 TRAIN_REQUIRED_MIBS=1500
./benchmarks/s3/15-ai-inference.sh  $S MODEL_SIZE=140g MODEL_SHARDS=30 PODS=16
./benchmarks/s3/16-range-read.sh    $S RANGE_OBJ_SIZE=512m PODS=8
```

### 9. elbencho by hand, without the test scripts
```bash
./benchmarks/deploy.sh raw-block $B PODS=auto       # only deploy: daemons on every node + controller pod
kubectl -n elbencho-bench exec -it deploy/eb-blk-elbencho-ctl -- bash
elbencho --hosts "$ELBENCHO_HOSTS" -w --direct --rand -t 16 --iodepth 32 -b 4k -s 100g --nosvcshare \
  --timelimit 120 --lat --latpercent /dev/elbencho
```
- `deploy.sh` uses the same settings as the tests (`PODS`, `CPU`, volumes, ...) and prints the exact commands for
  the protocol. After any test (`KEEP=1`, the default) the deployment stays, so you can also exec in right away.
- The controller pod has `ELBENCHO_HOSTS` (all daemons, port 1611) and `ELBENCHO_HOSTS_2` (port 1612, nfs/s3,
  for a second run at the same time). On S3, `$ELBENCHO_S3` holds `--s3endpoints/--s3key/--s3secret`: elbencho
  3.3-3 does **not** read the endpoint from `AWS_ENDPOINT_URL` (verified), so pass it on every run.
- Targets: `/dev/elbencho` (raw block), `/data` (nfs, xfs; the suite's dataset is `/data/f1..fN`), bucket names (s3).
- On per-pod volumes (raw block, xfs, nfs multi) add `--nosvcshare`, so every daemon works on its whole volume.
  Never on shared targets (one bucket, one export dir): see "Which data does each host work on?" in the main README.
- Without the suite at all, the chart itself has `mode=standalone` (a shell pod), `mode=job` and a coordinator Job:
  see the main [README](../README.md).

### 10. Long runs and cleanup
```bash
DETACH=1 ./benchmarks/raw-block/17-find-max.sh $B SWEEP_TEST=01   # default: survives a lost VPN/SSH connection
./benchmarks/cleanup.sh raw-block                          # remove deployments + volumes of a protocol
./benchmarks/cleanup.sh raw-block RELEASE_PREFIX=cmp-arraya  # remove one system of a comparison
./benchmarks/cleanup.sh all DELETE_NAMESPACE=1
```

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
| 12 | Scaling sweep *(extra)* | runs another test for `SWEEP_PODS="1 2 4 8"` (+ `SWEEP_NCONNECT`, `SWEEP_THREADS`, `SWEEP_IODEPTH`, dataset size) and prints a table | same | same |
| 13 | IODEPTH sweep | runs another test (default 02) for `SWEEP_IODEPTH="1 2 4 8 16 32 64 128"` | same | n/a |
| 14 | AI training | NFS: MLPerf-style epochs over a sample dataset + checkpoint + restore (see below) | n/a | same on S3 |
| 15 | AI inference | NFS: model load at cold start + lookups + KV-cache offload (see below) | n/a | same on S3 |
| 16 | Range reads | n/a | n/a | random byte-range GETs (`RANGE_BS`, default `64k:1,1m:2,8m:1`) at random offsets of large objects (`RANGE_OBJ_SIZE`, 256m). This is the Parquet/ORC pattern of Trino/Spark |
| 17 | Find max | load ladder on `SWEEP_TEST` (IODEPTH `1 … 128`, throughput `1 … 32`) that stops at the latency target, at saturation, or when the daemons run out of CPU | same | same, with a THREADS ladder (`8 … 256`) |

`compare.sh` runs any of these on two or more storage systems and prints them side by side.

Tests 12 and 13 can be combined freely: `SWEEP_PODS`, `SWEEP_NCONNECT`, `SWEEP_THREADS`, `SWEEP_IODEPTH` and the dataset size
(`SWEEP_FILE_SIZE` for nfs/xfs, `SWEEP_DEV_SIZE` for raw-block, `SWEEP_OBJECTS` for s3) all work in both
(12 defaults to a pod sweep, 13 to an iodepth sweep at the current `PODS`). The table shows where IOPS stop growing
while latency keeps rising, and a verdict per step against the latency target.

**Two layouts:**
- **Tests 01–07 (multi):** every daemon has its **own** target, and the result is the total for the whole system.
  - XFS / raw block: one PVC per pod.
  - NFS: a private directory per pod on the export (`subPathExpr`).
  - S3: load spread over `BUCKETS` buckets.
  - File and block tests use `--nosvcshare`, so every daemon works on its full own part of the dataset.
- **Tests 08–09 (single):** **one** target shared by all daemons. The dataset is split between them, which shows
  whether a single volume or bucket becomes the bottleneck.
  - A RWO volume (XFS / raw block) can only be shared by pods on the **same node**, so the runner adds the
    pod affinity for that. For multi-node sharing you need RWX: `ACCESS_MODE=ReadWriteMany`.

## Parameters

"What changing it does" is the effect on the measurement. Concurrency = requests in flight = `PODS × THREADS ×
IODEPTH` (S3 IOPS tests: `PODS × THREADS`).

### Load and test shape (all protocols)
| Key | Default | What it is | What changing it does |
|---|---|---|---|
| `PODS` | 2 (test 17, compare: `auto`) | elbencho daemons (load generators). `auto` = `PODS_PER_NODE` on every Ready node | More pods = more concurrency **and** more client CPU and network. Raise it when a result is `CLIENT-LIMITED` or one node's network is full. Changes the dataset split (one dataset in total) |
| `PODS_PER_NODE` | 1 | `PODS=auto`: daemons per node | 2+ uses more of each node's CPU; helps when one pod per node is CPU-bound. NFS: pods on one node share the mount's connections, so it helps less |
| `TOLERATE_ALL` | 1 with `PODS=auto`, else 0 | tolerate every taint | 1 = control-plane / tainted nodes generate load too. 0 = only untainted nodes |
| `NODE_SELECTOR` | – | `key=value` node label | Limits the load generators (and `PODS=auto`) to these nodes, e.g. keep them off the storage nodes |
| `SPREAD` | preferred | `preferred`, `required`, `even`, `none` | `required` = at most one pod per node (fails if there are more pods than nodes); `even` = the same number on every node; `none` = may pile up on one node and hit its CPU/network |
| `THREADS` | 16 (IOPS), 8 (throughput); S3 32 / 16 | I/O threads per daemon | More threads = more concurrency and more CPU. On S3 IOPS tests it is the only per-pod concurrency knob |
| `IODEPTH` | 16 (IOPS), 4 (throughput) | async queue depth per thread (libaio) | Raises concurrency at low CPU cost: IOPS grow until the storage saturates, then only latency grows. No effect on S3 whole-object requests |
| `BS` | 4k (IOPS), 1m (throughput) | block size per IO (S3: object size / part size) | Bigger blocks = fewer IOPS, more MiB/s, higher latency per IO. 4k shows the IO path, 1m+ the bandwidth |
| `BS_MIX` | per test 05/06/07 | weighted sizes, e.g. `16k:2,64k:1` | Makes the mix look like a real application |
| `READ_PCT` | 70 | read share in tests 05–07 | Higher = more reads; writes are usually the costlier side on flash with protection (RAID/EC/replication) |
| `DURATION` | 60 (test 10: 30) | seconds per measured phase | Longer = steadier numbers; 1800 for flash steady state (garbage collection, write cache full) |
| `LAT_THREADS` / `LAT_IODEPTH` | 1 / 1 | test 10 load | Above 1 test 10 is no longer pure single-request latency |
| `EXTRA_ARGS` | – | extra elbencho args for the measured phase | Anything elbencho supports, e.g. `--lathisto` |

### Latency targets
| Key | Default | What it is | What changing it does |
|---|---|---|---|
| `LAT_READ_AVG_MAX` / `LAT_READ_P99_MAX` | block, xfs, nfs: 2 / 5 ms; S3: 30 / 90 | target for reads | Every run prints `TARGET ... within / OVER`; test 17 stops at the first step over it. Higher = test 17 goes to a higher load (more IOPS, worse latency) |
| `LAT_WRITE_AVG_MAX` / `LAT_WRITE_P99_MAX` | block, xfs: 2 / 10; nfs: 5 / 15; S3: 30 / 90 | target for writes | Same, for writes. An empty value (`LAT_WRITE_P99_MAX=`) switches that target off |
| `LAT_AVG_MAX` / `LAT_P99_MAX` | – | sets reads **and** writes at once | Overrides the protocol defaults of both directions |
| `TPUT_LAT_FACTOR` | 10 (S3: 1) | multiplier of the targets for 03, 04, 07 | A 1 MiB IO takes longer than a 4k IO. Lower = throughput ladders stop earlier |
| `MIN_GAIN` | 3 | % a step must gain over the best so far | Higher = test 17 calls "saturated" sooner |
| `FIND_STOP` | 1 (test 17), 0 (12/13) | stop a ladder at over-target / client-limited / 2 flat steps | 0 = run every step anyway (the whole curve) |
| `SWEEP_TEST` | 02 | the test a sweep / test 17 runs | 01 write IOPS, 02 read IOPS, 03 / 04 write / read throughput, any of 01–11, 16 |
| `SWEEP_IODEPTH` / `SWEEP_THREADS` / `SWEEP_PODS` / `SWEEP_NCONNECT` | per test | the steps of a sweep | Defines the ladder; finer steps = a more precise maximum, more runs |

### Datasets (nfs, xfs, raw block)
One dataset per deployment, used by every test, so switching tests does not write it again.
| Key | Default | What it is | What changing it does |
|---|---|---|---|
| `TPUT_DATASET` | 4t | minimum total dataset (all pods) | Bigger = the throughput tests read/write more than any cache holds; longer first prepare (4 TiB at 5 GiB/s ≈ 14 min) |
| `EXPECTED_IOPS` | 500000 | 4k IOPS the system is expected to reach | The dataset grows to `EXPECTED_IOPS × 4k × 60 × IOPS_COVER_MIN` if that is more than `TPUT_DATASET` (500k → 2.3 TiB) |
| `IOPS_COVER_MIN` | 20 | minutes until the random IO has gone once through the dataset | Higher = bigger dataset, fewer re-hits of the same block (cache, overwrite). After every IOPS test the runner prints the real figure and warns below it |
| `DATASET_SIZE` | – | explicit total size | Overrides the two above |
| `FILES` | 8 | files per daemon (nfs, xfs) | More files = more parallel files; the dataset size stays the same |
| `FILE_SIZE` / `DEV_SIZE` | from the dataset | size per file (nfs, xfs) / tested range per device (raw block) | Explicit values win, per daemon |
| `PVC_SIZE` | sized for the dataset | volume per daemon (xfs, raw block) | Existing volumes that are large enough are reused; smaller ones (or another StorageClass) are deleted and created again, and the dataset is prepared again |
| `PREPARE` | auto | `auto`, `always`, `never` | `auto` writes the dataset once (again only when its size changes or more pods need it) |
| `STORAGE_CACHE` | – | cache of the storage system, e.g. `512g` | Warns (or stops, `CACHE_CHECK=fail`) when the dataset < `CACHE_FACTOR` × cache |
| `CACHE_FACTOR` / `CACHE_CHECK` | 2 / warn | | |
| `BLOCKVARPCT` | – (100) | random share of every written block | 100 = incompressible (worst case), 50 ≈ 2:1 compressible, 0 = dedupable. Lower values make arrays with data reduction look faster |

### Client resources and measurement
| Key | Default | What it is | What changing it does |
|---|---|---|---|
| `CPU` | – (`auto` with `PODS=auto`) | CPU request per daemon pod; `auto` = `CPU_SHARE` % of the free CPU of the weakest node, split between its daemons; `none` | More CPU = more requests per pod before it becomes `CLIENT-LIMITED` |
| `CPU_SHARE` | 80 | share used by `CPU=auto` | Higher = more CPU for the pods, less for the rest of the node |
| `CPU_LIMIT` | 0 | 1 = limit = request (Guaranteed, exclusive cores with the static CPU manager) | 1 avoids noisy neighbours; but CFS throttling then shows up as storage latency (the runner warns) |
| `MEMORY` | – | memory request = limit per daemon | Needed for S3 throughput: `THREADS × IODEPTH × BS` per pod |
| `CLIENT_CPU` / `CLIENT_CPU_MAX` | 1 / 80 | measure the daemons' CPU per phase; threshold for `CLIENT-LIMITED` | Lower threshold = stricter: fewer results accepted as storage results |
| `LAT` | 1 | latency average + percentiles | 0 = no latency (and no target check) |
| `LIVE` | 1 | a progress line every 5 s | 0 = quieter logs |
| `AIO` / `AIO_MAX_THREADS` | auto / 1024 | async IO check and fallback (nfs, xfs, raw block) | See "Async IO blocked" |

### Deployment and operation
| Key | Default | What it is | What changing it does |
|---|---|---|---|
| `NAMESPACE` | elbencho-bench | namespace of everything | Separate namespaces = independent deployments |
| `RELEASE_PREFIX` | eb | helm release prefix (`eb-blk`, `eb-xfs-single`, ...) | Another prefix = another deployment with its own volumes/dataset (compare.sh uses `cmp-<label>`) |
| `KEEP` | 1 | keep the deployment after the test | 0 = remove it (and its volumes!) after the test: the next test prepares again |
| `IMAGE_REPO` / `IMAGE_TAG` | chart default | | e.g. a mirror in an air-gapped cluster |
| `HELM_ARGS` | – | extra helm args | e.g. `"--set tolerations[0].operator=Exists"` |
| `DETACH` / `POLL` / `RECONNECT_TIMEOUT` | 1 / 5 / 3600 | run detached in the controller pod; poll interval; give up offline after | 0 = the run stops when kubectl loses the connection |
| `WAIT_TIMEOUT` | 10m | how long to wait for the pods | |
| `RESULTS_DIR` | benchmarks/results | where results are written | |
| `CONTINUE` | 0 | run-suite.sh: continue after a failed test | |

### NFS ([nfs/profile.env](nfs/profile.env))
| Key | Default | What it is | What changing it does |
|---|---|---|---|
| `NFS_SERVER`, `NFS_PATH` | – , `/` | the chart creates the NFS PV and mounts it | |
| `NFS_STORAGE_CLASS` | – | alternative: an existing RWX StorageClass | Mount options then come from the StorageClass, not from the keys below |
| `NFS_VERS` | 4.1 | `3`, `4.0`, `4.1`, `4.2` | v4.1+ limits requests in flight per node by session slots (Linux client default 64); v3 has no sessions |
| `NCONNECT` | 8 | TCP connections per mount (0 = off) | More connections = more parallel requests per node; vendors report ~3× for 4k reads from 1 to 8–16. Restarts the daemons |
| `RSIZE` / `WSIZE` | 1048576 | max bytes per NFS READ/WRITE | 65536 can help small random IO; 1M is best for throughput. Measure both |
| `NFS_EXTRA_OPTS` | hard | extra mount options | e.g. `hard,noatime,actimeo=0` |
| `PVC_SIZE` | 500Gi | nominal (NFS does not enforce it) | – |

### XFS ([xfs/profile.env](xfs/profile.env)) and raw block ([raw-block/profile.env](raw-block/profile.env))
| Key | Default | What it is | What changing it does |
|---|---|---|---|
| `STORAGE_CLASS` | – (required) | XFS: formats volumes as XFS (checked); block: `volumeMode: Block` | The system under test. A different class = new volumes |
| `ACCESS_MODE` | ReadWriteOnce | | `ReadWriteMany` lets tests 08/09 spread over nodes (if the storage supports it) |

### S3 ([s3/profile.env](s3/profile.env))
| Key | Default | What it is | What changing it does |
|---|---|---|---|
| `S3_ENDPOINT` | – (required) | comma separated endpoints | Several endpoints spread the threads over them (avoid one gateway as the limit) |
| `S3_SECRET_NAME` | – | Secret with `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` (recommended) | |
| `S3_ACCESS_KEY` / `S3_SECRET_KEY` | – | alternative: the runner creates the Secret | Keys are never written to the results |
| `S3_REGION` | – | | |
| `BUCKET_PREFIX`, `BUCKETS` | elbencho, 4 | multi tests use `elbencho-1..4`, single `elbencho-single`, mixes `elbencho-mix` | More buckets spread the load if the system shards by bucket |
| `OBJ_SIZE`, `OBJECTS` | 4k, 1000 | IOPS tests: object size, objects per thread | Bigger `OBJECTS` = dataset beyond the cache; bigger objects = fewer ops/s, more MiB/s |
| `TPUT_OBJ_SIZE`, `TPUT_OBJECTS` | 256m, 4 | throughput tests: object size, objects per thread | Dataset = `PODS × THREADS × TPUT_OBJECTS × TPUT_OBJ_SIZE`; raise it for multi-TB runs |
| `MIX_OBJECTS` | 20000 | objects of the mixed-size dataset (05–07) | |

## Latency targets

Every run compares its latency with the target of its protocol and prints `TARGET ... within the target` or
`OVER the target`; test 17 stops there and reports the best step within it. Reads and writes have separate targets.

| protocol | read avg / p99 | write avg / p99 | large-block tests (03, 04, 07) |
|---|---|---|---|
| raw block, XFS (NVMe/TCP class) | 2 / 5 ms | 2 / 10 ms | × 10 (`TPUT_LAT_FACTOR`) |
| NFS | 2 / 5 ms | 5 / 15 ms | × 10 |
| S3 | 30 / 90 ms | 30 / 90 ms | × 1 |

Where the numbers come from (published figures; vendor numbers are best cases at their own load):
- NVMe/TCP adds about 0.1 ms per 4k write over the network (Western Digital, TCP vs RoCE); 0.3–0.5 ms is typical
  end to end, < 0.2 ms on tuned paths (simplyblock). Local NVMe with XFS: p99 ≈ 0.6 ms for 4k random writes.
- Audited SPC-1 results of all-flash arrays: 0.26–0.96 ms average response time at 100% load. Vendor guidance for
  databases on all-flash: ≤ 1 ms average.
- All-flash NFS systems in SPECstorage 2020: 1.0–1.4 ms average response time at their peak load (mixed workloads
  with metadata).

The write targets are the "lenient" level: well above what a healthy array shows, so test 17 stops where the
system is clearly overloaded rather than at the first sign of queueing. Tighten them for latency-critical
applications, e.g. `LAT_WRITE_AVG_MAX=1 LAT_WRITE_P99_MAX=5`.

## Datasets

For nfs, xfs and raw block, one dataset per deployment is used by all tests:
`total = max(TPUT_DATASET, EXPECTED_IOPS × 4k × 60 × IOPS_COVER_MIN)` = 4 TiB with the defaults, split between the
daemons (layout multi) or one shared set (layout single). Volumes (`PVC_SIZE`) are sized to hold it.

- **Throughput tests** read/write several TB, far beyond any controller cache.
- **IOPS tests**: random 4k IO at `EXPECTED_IOPS` needs `IOPS_COVER_MIN` (20) minutes to go once through the
  dataset, so blocks are not hit again within that time. After each IOPS test the runner prints the real time at
  the measured rate, and warns with the needed `DATASET_SIZE` / `EXPECTED_IOPS` when it is shorter.
- The first test of a deployment writes the dataset (`prepare`); later tests reuse it. It is written again only
  when its size changes or a run needs more daemons than have data. In sweeps it is sized for the largest pod
  count, so the steps share it.
- S3 is not affected; its datasets are set with `OBJECTS`, `TPUT_OBJECTS`, `MIX_OBJECTS`.

## Comparing storage systems

`compare.sh` runs the same list of tests on two or more systems, one after the other, with the same load
generators (default `PODS=auto`, `CPU=auto`), the same dataset size and the same latency targets:

```bash
./benchmarks/compare.sh raw-block TARGETS="arrayA=sc-array-a arrayB=sc-array-b"
```
The output looks like this (layout only, the numbers are made up):
```
COMPARISON (raw-block, STORAGE_CLASS): best result within the latency target per test (latencies in ms)
test     system             ops/s     MiB/s   rd_avg   rd_p99   wr_avg   wr_p99 pods/thr/qd    verdict        vs arrayA
max:01   arrayA            412000      1609        -        -     1.21     6.80 8/16/16        ok             -
max:01   arrayB            498000      1945        -        -     1.65     8.90 8/16/32        ok             +21%
...
```

| Key | Default | What it does |
|---|---|---|
| `TARGETS` | – (required) | `<label>=<value>` per system; the value goes into `COMPARE_VAR` |
| `COMPARE_VAR` | `STORAGE_CLASS` (raw-block, xfs), `NFS_SERVER` (nfs), `S3_ENDPOINT` (s3) | the setting that differs between the systems |
| `ARGS_<label>` | – | extra settings for one system only, e.g. `ARGS_b="NFS_PATH=/vol2"` |
| `ITEMS` | `max:01 max:02 max:03 max:04` | `max:NN` = test 17 on test NN (best within the target); `NN` = one fixed run of test NN |

- Every system gets its own deployment (`cmp-<label>-...`) and its own dataset on its own volumes. Before a
  system runs, the pods of the others are scaled to 0, so they do not take CPU or network from it.
- Each system writes its full dataset once (4 TiB by default), so plan time for two prepares.
- Volumes are kept, so a second comparison reuses the datasets. Remove a system with
  `./benchmarks/cleanup.sh raw-block RELEASE_PREFIX=cmp-<label>` (lower case).
- The table and the raw rows are saved as `results/compare-<time>.txt` / `.tsv`; every system's steps are in
  `results/sweep-<time>-<label>-<test>.txt`.

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
./benchmarks/nfs/17-find-max.sh NFS_SERVER=... NFS_PATH=/export SWEEP_TEST=02
./benchmarks/raw-block/17-find-max.sh STORAGE_CLASS=array-a SWEEP_TEST=01
```

- It deploys a daemon on every node (`PODS=auto`, `CPU=auto`) and runs `SWEEP_TEST` with a growing load:
  `SWEEP_THREADS` for S3 (default `8 16 32 64 128 256`, throughput `2 … 64`), `SWEEP_IODEPTH` for the others.
- It stops at the first step that misses the latency target of the protocol (`over target`, see "Latency targets"), that is `CLIENT-LIMITED`, or after two
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
- `summary.txt`: the table printed at the end (IOPS, read IOPS, MiB/s, avg latency, percentiles, the `TARGET`
  verdict and, for IOPS tests, how long the IO needs to go through the dataset)
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

- **Bypass the client cache.** All file and block tests use `--direct`. Server-side caches still count, so the
  dataset is several TB by default (see "Datasets"); check it against the storage cache with `STORAGE_CACHE`.
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
