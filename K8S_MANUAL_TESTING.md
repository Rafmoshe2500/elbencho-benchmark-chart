# Manual Kubernetes Verification Guide

This guide describes how to run and verify the `elbencho` benchmark chart locally using **Minikube** and **Helm** on Windows.

---

## 1. Prerequisites

Ensure you have **Docker Desktop** running and the CLI binaries (`minikube.exe`, `helm.exe`, and `kubectl.exe`) in your working directory or system PATH.

---

## 2. Step-by-Step Guide

### Step 1: Create a local storage folder on Windows
This folder will receive the benchmarked writes from Kubernetes:
```powershell
mkdir C:\elbencho-storage
```

### Step 2: Start Minikube
Start the cluster using the Docker driver:
```powershell
.\minikube.exe start --driver=docker
```

### Step 3: Run the Mount Daemon
To synchronize files written in Kubernetes back to your Windows host folder `C:\elbencho-storage`, you must start the mount daemon in a **separate terminal window** and keep it running:
```powershell
.\minikube.exe mount C:\elbencho-storage:/data
```

### Step 4: Apply PersistentVolume (PV) and PVC
Apply the local PV and PVC manifest to bind the mounted `/data` directory in Minikube to a 5GB claim:
```powershell
kubectl apply -f local-pvc.yaml
```

Verify that the PVC is bound successfully:
```powershell
kubectl get pvc local-pvc
```
*Expected Output: STATUS should be `Bound`.*

### Step 5: Load the Docker image into Minikube
Load the locally built `rafmoshe2500/elbencho:3.1-5` image into the Minikube registry:
```powershell
.\minikube.exe image load rafmoshe2500/elbencho:3.1-5
```

### Step 6: Deploy the Helm Chart in Job Mode
Deploy the elbencho chart using the override configuration for the 100MB benchmark write test (using 128KB block size):
```powershell
.\helm.exe install elbencho-job ./charts/elbencho -f job-override.yaml
```

### Step 7: Verify Results
1. Check the Pod execution status:
   ```powershell
   kubectl get pods -l job-name=elbencho-job-job
   ```
   *Expected Output: STATUS should be `Completed`.*

2. Read the benchmark output logs:
   ```powershell
   kubectl logs -l job-name=elbencho-job-job
   ```
   *Example Output:*
   ```
   WRITE       Elapsed time     :        82ms        82ms
               Files/s          :          12          12
               IOPS             :        9690        9690
               Throughput MiB/s :        1211        1211
               Total MiB        :         100         100
   ```

3. Check your Windows host folder `C:\elbencho-storage` using File Explorer or PowerShell:
   ```powershell
   Get-ChildItem -Recurse C:\elbencho-storage
   ```
   You will see the nested folders (`r0\d0\...`) and files created by `elbencho` during the test run!

---

## 3. Cleaning Up
When done, you can delete the Kubernetes resources and stop the cluster:
```powershell
.\helm.exe uninstall elbencho-job
kubectl delete -f local-pvc.yaml
.\minikube.exe stop
```
