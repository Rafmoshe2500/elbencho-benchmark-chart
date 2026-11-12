# elbencho-benchmark-chart

This repository contains a Dockerfile and a highly customizable Helm Chart for deploying the **Elbencho** storage benchmarking tool on Kubernetes.

Elbencho is a modern distributed storage benchmark tool for file systems, object stores, and block devices, developed by Sven Breuner.

---

## 1. Container Image

The chart uses the **official elbencho image** published by the elbencho author:
[`breuner/elbencho`](https://hub.docker.com/r/breuner/elbencho) (amd64 + arm64, Ubuntu based, includes S3 and libaio).
The default tag is `v<appVersion>` from `Chart.yaml`, currently **`v3.3-3`**. No custom build is needed.

To pin a different version or use a mirror:

```bash
helm install bench ./charts/elbencho --set image.repository=my-registry/elbencho --set image.tag=v3.3-3
```

> [!NOTE]
> Version 3.2.1 or later is required for weighted block-size mixes (`-b 32k:1,64k:1,128k:1`), which
> the load-test suite in [`benchmarks/`](benchmarks) uses.

---

## 2. Helm Chart: Modes and Protocols

The chart lives in `./charts/elbencho`. Two settings define a deployment.

### `mode`: how elbencho runs

| Mode | Kind | What runs | Use case |
| :--- | :--- | :--- | :--- |
| `standalone` *(default)* | `Deployment` | idle shell (stops at once on SIGTERM) | `kubectl exec` in and run elbencho by hand |
| `service` | `StatefulSet` + headless `Service` | `elbencho --service --foreground` | Distributed benchmarks (`--hosts`). Set `serviceMode.benchmark.enabled=true` to have a coordinator Job run the test for you |
| `job` | `Job` | `elbencho <job.args>` | One-shot automated benchmark (CI, acceptance tests) |

### `protocol`: what storage is tested

| Protocol | How it is attached | Benchmark path |
| :--- | :--- | :--- |
| `file` *(default)* | PVC mounted as a filesystem at `/data`. Works with any StorageClass: EBS/PD, Ceph, Longhorn, local disks, **block devices formatted as XFS/ext4**, or NFS through a CSI StorageClass | `/data/...` |
| `nfs` | The chart creates a static NFS `PersistentVolume` (with your `mountOptions`) and a RWX PVC. No CSI driver needed | `/data/...` |
| `block` | PVC with `volumeMode: Block`, attached as a **raw device** at `/dev/elbencho` (no filesystem) | `/dev/elbencho` (use `--direct`, never `-d`) |
| `s3` | No volume. Endpoint and credentials (from a Secret) are passed to elbencho as `--s3endpoints/--s3key/--s3secret` | bucket name |

Ready-made values files are in [`examples/`](examples):

```bash
helm install bench ./charts/elbencho -f examples/file-job.yaml
helm install bench ./charts/elbencho -f examples/block-xfs-job.yaml
helm install bench ./charts/elbencho -f examples/block-raw-job.yaml
helm install bench ./charts/elbencho -f examples/nfs-distributed.yaml
helm install bench ./charts/elbencho -f examples/s3-job.yaml
```

### Storage options (`file` / `block`)

* **Create a PVC** (default): `persistence.create=true`, `persistence.storageClass`, `persistence.size`.
  In `service` mode every daemon gets **its own** PVC (`volumeClaimTemplates`).
* **Use an existing PVC**: `persistence.existingClaim=my-pvc`. All pods share it, so it must be RWX if
  there is more than one pod. For `protocol=block` the PVC must have `volumeMode: Block`.

### Block device with XFS

Testing a block device *through* a filesystem means `protocol=file` on a StorageClass that formats the
device. Kubernetes does the `mkfs`:

* CSI drivers: `parameters: { csi.storage.k8s.io/fstype: xfs }` on the StorageClass.
* Local PVs: `spec.local.fsType: xfs` on a raw, unformatted device. kubelet runs `mkfs.xfs` the first time.

To test the same device with no filesystem, use `protocol=block`.

### S3

```bash
kubectl create secret generic s3-creds \
  --from-literal=AWS_ACCESS_KEY_ID=... --from-literal=AWS_SECRET_ACCESS_KEY=...
helm install s3bench ./charts/elbencho --set mode=job --set protocol=s3 \
  --set s3.endpoints=http://minio.minio.svc:9000 --set s3.existingSecret=s3-creds \
  --set 'job.args={-d,-w,-r,-t,8,-n,1,-N,100,-s,4m,-b,4m,my-bucket}'
```

> [!NOTE]
> elbencho (checked with 3.1-5 and 3.3-3) does **not** read the endpoint from `AWS_ENDPOINT_URL`, even though its help text says
> it does. The chart passes `--s3endpoints` explicitly in Job and coordinator runs. In `standalone` mode, use
> the command printed by `helm install` (NOTES). Keep `-b` equal to `-s`, or `-b` at least `5m`: S3 rejects
> multipart parts smaller than 5 MiB.

---

## 3. Deploy Examples

```bash
# Interactive pod with a new 20Gi PVC
helm install my-elbencho ./charts/elbencho --set persistence.size=20Gi

# Interactive pod on an existing PVC
helm install my-elbencho ./charts/elbencho --set persistence.existingClaim=my-existing-pvc

# One-shot job (numbers in job.args are quoted automatically)
helm install elbencho-job ./charts/elbencho --set mode=job \
  --set 'job.args={-w,-r,-t,8,-s,10g,-b,1m,/data/testfile}'
kubectl logs -f job/elbencho-job-job-r1

# Change the job and run it again (the Job name has a revision suffix, so upgrades work)
helm upgrade elbencho-job ./charts/elbencho --reuse-values --set 'job.args={-r,-t,8,-s,10g,-b,1m,/data/testfile}'
```

---

## 4. Running Benchmarks Manually (Standalone Mode)

```bash
kubectl exec -it deploy/my-elbencho -- bash
elbencho -w -t 4 -s 10G -b 1M /data/testfile     # write
elbencho -r -t 4 -s 10G -b 1M /data/testfile     # read
```

---

## 5. Distributed Benchmarks (Service Mode)

Each StatefulSet pod runs an elbencho daemon on port 1611 (elbencho default). A headless Service gives each pod a stable
DNS name: `<release>-elbencho-N.<release>-elbencho`.

**Automatic**: a coordinator Job waits for all daemons, then runs the benchmark across all of them:

```bash
helm install cluster ./charts/elbencho --set mode=service --set replicaCount=3 \
  --set serviceMode.benchmark.enabled=true \
  --set 'serviceMode.benchmark.args={-d,-w,-r,-t,4,-n,2,-N,100,-s,4m,-b,1m,/data}'
kubectl logs -f job/cluster-elbencho-coordinator-r1
```

**Manual**: exec into any daemon and use `--hosts`:

```bash
kubectl exec -it cluster-elbencho-0 -- elbencho \
  --hosts cluster-elbencho-0.cluster-elbencho,cluster-elbencho-1.cluster-elbencho,cluster-elbencho-2.cluster-elbencho \
  -d -w -t 4 -n 2 -N 100 -s 4m -b 1m /data
```

> [!NOTE]
> With `-d -n/-N` (directory mode) each daemon and thread writes to its own `rN/` directories. With a single
> file path (e.g. `/data/testfile`) elbencho treats the file as **shared**: the hosts split the file's offset
> range between them, and `-s` is the total size, not the size per host. On per-pod PVCs each daemon then holds
> only its part of the file.

### Which data does each host work on?

All daemons get the same path (`/data/...`, `/dev/elbencho` or a bucket name). What each one does with it
depends on the flags. Tested with 3 daemons:

| Scenario | Command | Result |
| :--- | :--- | :--- |
| Separate PVCs, **every daemon does the full test on its own volume** (file / block) | `--nosvcshare -w -r -s 300m /data/testfile` | each PVC: 300 MiB, total 900 MiB |
| Separate PVCs, shared-file mode (default) | `-w -r -s 300m /data/testfile` | the hosts split the file: each writes only 100 MiB (its offset range) |
| Many files/objects (file, NFS, S3) | `-d -w -r -t 2 -n 1 -N 5 /data` or `bucket` | each thread has its own `rN/` dir or prefix: 6 ranks x 5 = 30 files |
| **S3: all hosts on one bucket**, many objects | `-d -w -r -t 2 -n 1 -N 5 -s 4m -b 4m my-bucket` | 30 objects under `r0/` ... `r5/`, no collisions |
| **S3: all hosts write the same big objects together** | `--s3mpusharing -w -r -s 60m -b 5m "my-bucket/obj[1-3]"` | 3 objects x 60 MiB, parts uploaded by all hosts |
| Shared RWX volume (NFS) | `-d -w -r -n .. -N .. /data` | all ranks in the same directory tree, no collisions |

> [!WARNING]
> Do **not** use `--nosvcshare` on shared storage (one S3 bucket, NFS, RWX). Every host then uses the
> same names and they overwrite each other. With 3 hosts, the bucket ended up with 10 objects instead of 30.
> `--nosvcshare` is meant for separate per-pod volumes. See `examples/per-pod-volumes-distributed.yaml`.

---

## 6. Load-Test Suite

[`benchmarks/`](benchmarks) has ready-made load tests for **NFS, XFS, raw block devices and S3**:
max IOPS and throughput, 70/30 mixes with different block sizes, single-target tests, QD1 latency,
metadata and scaling sweeps. Every parameter can be changed per run. See [`benchmarks/README.md`](benchmarks/README.md).

```bash
./benchmarks/xfs/02-read-iops.sh STORAGE_CLASS=my-xfs-sc PODS=4 THREADS=16 IODEPTH=32
```

---

## 7. Testing the Chart

```bash
tests/render-test.sh    # helm lint + render every mode x protocol + examples (+ server dry-run if a cluster is reachable)
```
