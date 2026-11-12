# elbencho-benchmark-chart

This repository contains a Dockerfile and a highly customizable Helm Chart for deploying the **Elbencho** storage benchmarking tool on Kubernetes.

Elbencho is a modern distributed storage benchmark tool for file systems, object stores, and block devices, developed by Sven Breuner.

---

## 1. Docker Image Build & Push (Local)

To build the Docker image locally and push it to your Docker Hub account:

1. **Verify your working directory**:
   Ensure you are in the root of the project:
   ```powershell
   cd C:\elbencho-benchmark-chart
   ```

2. **Log in to Docker Hub**:
   Make sure you are authenticated with your account:
   ```bash
   docker login
   ```

3. **Build the image**:
   Use Docker to compile `elbencho` (v3.1-5) and package the final minimal image:
   ```bash
   docker build -t rafmoshe2500/elbencho:3.1-5 .
   ```

4. **Push the image to Docker Hub**:
   ```bash
   docker push rafmoshe2500/elbencho:3.1-5
   ```

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
> elbencho 3.1-5 does **not** read the endpoint from `AWS_ENDPOINT_URL`, even though its help text says
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

Each StatefulSet pod runs an elbencho daemon on port 27123. A headless Service gives each pod a stable
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

---

## 6. Testing the Chart

```bash
tests/render-test.sh    # helm lint + render every mode x protocol + examples (+ server dry-run if a cluster is reachable)
```
