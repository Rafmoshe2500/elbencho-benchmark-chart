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
   Use Docker to compile `elbencho` (v3.1.5) and package the final minimal image:
   ```bash
   docker build -t rafmoshe2500/elbencho:3.1.5 .
   ```

4. **Push the image to Docker Hub**:
   ```bash
   docker push rafmoshe2500/elbencho:3.1.5
   ```

---

## 2. Helm Chart Structure & Configuration

The Helm Chart is located at `./charts/elbencho` and supports 3 deployment modes (`mode` parameter in `values.yaml`):

| Mode | Kind | Command | Use Case |
| :--- | :--- | :--- | :--- |
| `standalone` *(default)* | `Deployment` | `tail -f /dev/null` | For interactive manual benchmarking. You shell into the pod and run elbencho commands. |
| `service` | `StatefulSet` | `elbencho --service` | Runs elbencho as a daemon service on port 27123 for distributed benchmarking tests. |
| `job` | `Job` | Customizable `job.args` | Automated one-time benchmarking job. Useful for CI/CD storage verification. |

### Persistence Options

The Helm chart is fully generic and handles PVCs according to your requirements:

1. **Mount an Existing PVC**:
   Set `persistence.existingClaim` to the name of your pre-created PVC.
   ```yaml
   persistence:
     enabled: true
     existingClaim: "my-existing-storage-claim"
     create: false # Do not create a new PVC
   ```

2. **Dynamically Create a New PVC**:
   Leave `persistence.existingClaim` empty and set `persistence.create: true`.
   ```yaml
   persistence:
     enabled: true
     existingClaim: ""
     create: true
     storageClass: "gp3" # Specify StorageClass (omit for default)
     size: 10Gi
     accessModes:
       - ReadWriteOnce
   ```

---

## 3. How to Deploy the Helm Chart

To install the Helm Chart on your Kubernetes cluster:

1. **Deploy in Standalone (Interactive) Mode with a New PVC**:
   ```bash
   helm install my-elbencho ./charts/elbencho \
     --set mode=standalone \
     --set persistence.create=true \
     --set persistence.size=20Gi
   ```

2. **Deploy in Standalone Mode mounting an Existing PVC**:
   ```bash
   helm install my-elbencho ./charts/elbencho \
     --set mode=standalone \
     --set persistence.existingClaim="my-existing-pvc"
   ```

3. **Deploy as a Distributed Service**:
   This spins up a StatefulSet. If `persistence.create=true`, each pod receives its own unique dynamically-provisioned PVC via `volumeClaimTemplates` so they do not conflict.
   ```bash
   helm install elbencho-daemons ./charts/elbencho \
     --set mode=service \
     --set replicaCount=3 \
     --set persistence.size=50Gi
   ```

4. **Deploy as an Automated One-off Job**:
   ```bash
   helm install elbencho-job ./charts/elbencho \
     --set mode=job \
     --set job.args="{-t,8,-s,10g,-b,1m,-w,/data}"
   ```

---

## 4. Running Benchmarks Manually (Standalone Mode)

After deploying in `standalone` mode, you can run benchmarks interactively by executing commands inside the pod:

1. Get the pod name:
   ```bash
   POD_NAME=$(kubectl get pods -l app.kubernetes.io/name=elbencho -o jsonpath="{.items[0].metadata.name}")
   ```

2. Exec into the pod:
   ```bash
   kubectl exec -it $POD_NAME -- /bin/bash
   ```

3. Run a write benchmark with elbencho (e.g., 4 threads, 10G total size, 1M block size on your mounted PVC `/data`):
   ```bash
   elbencho -t 4 -s 10G -b 1M -w /data
   ```

4. Run a read benchmark:
   ```bash
   elbencho -t 4 -s 10G -b 1M -r /data
   ```
