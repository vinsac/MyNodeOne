# GPU Support Architecture

This document explains how MyNodeOne enables GPU workloads for AI/ML applications like LLM inference, training, and GPU-accelerated computing.

---

## Overview

MyNodeOne supports NVIDIA GPUs for running containerized AI/ML workloads. The architecture separates **host-level** components (drivers) from **container-level** components (ML libraries).

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         CONTAINER (Pod)                                  │
│                                                                          │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │  Your Application                                                │    │
│  │  (vLLM, Ollama, PyTorch, TensorFlow, etc.)                      │    │
│  │                                                                  │    │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐              │    │
│  │  │   CUDA      │  │   cuDNN     │  │  TensorRT   │              │    │
│  │  │  Runtime    │  │             │  │  (optional) │              │    │
│  │  └─────────────┘  └─────────────┘  └─────────────┘              │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                    │                                     │
│                                    ▼                                     │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │              NVIDIA Container Toolkit                            │    │
│  │              (libnvidia-container)                               │    │
│  └─────────────────────────────────────────────────────────────────┘    │
└────────────────────────────────────┼────────────────────────────────────┘
                                     │
═════════════════════════════════════╪═════════════════════════════════════
                                     │  Container ↔ Host Boundary
═════════════════════════════════════╪═════════════════════════════════════
                                     │
┌────────────────────────────────────┼────────────────────────────────────┐
│                         HOST (Node)                                      │
│                                    ▼                                     │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                    NVIDIA Driver                                 │    │
│  │                    (Kernel Module)                               │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                    │                                     │
│                                    ▼                                     │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                    NVIDIA GPU Hardware                           │    │
│  │                    (RTX 3090, A100, etc.)                        │    │
│  └─────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## What to Install Where

### Host Machine (Control Plane / Worker Node)

These components **must be installed on the host OS**:

| Component | Purpose | Install Command |
|-----------|---------|-----------------|
| **NVIDIA Driver** | Kernel module to communicate with GPU hardware | `sudo apt install nvidia-driver-550` |
| **NVIDIA Container Toolkit** | Allows containers to access GPU devices | `sudo apt install nvidia-container-toolkit` |

### Kubernetes Cluster

| Component | Purpose | Install Command |
|-----------|---------|-----------------|
| **NVIDIA Device Plugin** | Exposes GPUs as schedulable resources | `kubectl apply -f nvidia-device-plugin.yml` |

### Container Images (NOT on host)

These come **pre-packaged in container images** - do NOT install on host:

| Library | Purpose | Example Image |
|---------|---------|---------------|
| CUDA Toolkit | GPU programming runtime | `nvidia/cuda:12.2.0-runtime-ubuntu22.04` |
| cuDNN | Deep learning primitives | Included in ML images |
| PyTorch | ML framework | `pytorch/pytorch:2.1.0-cuda12.1-cudnn8-runtime` |
| TensorFlow | ML framework | `tensorflow/tensorflow:2.14.0-gpu` |
| vLLM | LLM inference server | `vllm/vllm-openai:latest` |
| Ollama | LLM runner | `ollama/ollama:latest` |

---

## Offline / Air-Gapped Clusters

GPU support works fully offline after initial setup:

### What Requires Internet (One-Time)

| Component | When | Can Pre-Download? |
|-----------|------|-------------------|
| NVIDIA Driver | Installation | Yes (download .deb/.rpm) |
| Container Toolkit | Installation | Yes (download packages) |
| Device Plugin Image | First pod start | Yes (pre-pull image) |
| ML Container Images | First pod start | Yes (pre-pull images) |

### What Works Offline

| Component | Offline? | Notes |
|-----------|----------|-------|
| NVIDIA Driver | ✓ Yes | Runs locally, no network needed |
| Container Toolkit | ✓ Yes | Local runtime configuration |
| Device Plugin | ✓ Yes | Runs locally, reports GPUs to scheduler |
| GPU Scheduling | ✓ Yes | Kubernetes scheduler is local |
| Running GPU Pods | ✓ Yes | Once images are pulled |

### Pre-Pulling Images for Offline Use

```bash
# On a machine with internet, pull and save images
docker pull nvcr.io/nvidia/k8s-device-plugin:v0.14.5
docker pull vllm/vllm-openai:latest
docker save nvcr.io/nvidia/k8s-device-plugin:v0.14.5 > device-plugin.tar
docker save vllm/vllm-openai:latest > vllm.tar

# Transfer to offline cluster, then load
sudo ctr -n k8s.io images import device-plugin.tar
sudo ctr -n k8s.io images import vllm.tar
```

### Local Device Plugin Manifest

MyNodeOne includes a local copy of the device plugin manifest:

```bash
# Works without internet
kubectl apply -f manifests/gpu/nvidia-device-plugin.yaml
```

---

## Installation

### Recommended: Install Driver Before MyNodeOne

For the smoothest experience, install the NVIDIA driver **before** running the MyNodeOne installer:

```bash
# 1. Check if you have an NVIDIA GPU
lspci | grep -i nvidia

# 2. Install ubuntu-drivers tool and see recommended driver
sudo apt update
sudo apt install -y ubuntu-drivers-common
ubuntu-drivers devices
# Shows recommended driver for your GPU (e.g., nvidia-driver-570-open for RTX 3090)

# 3. Auto-install the recommended driver
sudo ubuntu-drivers autoinstall

# 4. Reboot (required for driver to load)
sudo reboot

# 5. Verify driver is working
nvidia-smi
# Should show your GPU model and driver version

# 6. Now run MyNodeOne installer
sudo ./scripts/install-control-plane.sh
```

The MyNodeOne installer will automatically:
- Detect your working GPU driver
- Install the NVIDIA Container Toolkit
- Deploy the NVIDIA Device Plugin to Kubernetes

### GPU Setup Script (Standalone)

You can also use the GPU setup script directly:

```bash
# Interactive mode - asks if you want GPU support
sudo ./scripts/lib/gpu-setup.sh

# Auto mode - installs if GPU detected
sudo ./scripts/lib/gpu-setup.sh --auto

# Check GPU status only
sudo ./scripts/lib/gpu-setup.sh --check
```

### Manual Setup

#### Step 1: Install NVIDIA Driver

```bash
# Ubuntu 22.04/24.04 - Auto-install recommended driver
sudo apt update
sudo apt install -y ubuntu-drivers-common
sudo ubuntu-drivers autoinstall

# Reboot required
sudo reboot

# Verify installation
nvidia-smi
```

#### Step 2: Install NVIDIA Container Toolkit

```bash
# Add NVIDIA repository
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
    sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt update
sudo apt install -y nvidia-container-toolkit

# Configure for containerd (K3s uses containerd)
sudo nvidia-ctk runtime configure --runtime=containerd
sudo systemctl restart k3s  # or containerd
```

#### Step 3: Deploy NVIDIA Device Plugin

```bash
# On control plane
kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.14.5/nvidia-device-plugin.yml
```

#### Step 4: Verify

```bash
# Check GPU is recognized by Kubernetes
kubectl describe node <gpu-node> | grep -A5 "Allocatable"
# Should show: nvidia.com/gpu: 1

# Test with a pod
kubectl run gpu-test --rm -it --restart=Never \
    --image=nvidia/cuda:12.2.0-base-ubuntu22.04 \
    --limits=nvidia.com/gpu=1 \
    -- nvidia-smi
```

---

## K3s GPU Configuration (Critical)

K3s handles GPU configuration differently than standard Kubernetes. Understanding this is **essential** for GPU workloads to function correctly.

### How K3s Auto-Detects NVIDIA Runtime

When K3s starts (or restarts), it automatically:

1. **Scans for `nvidia-container-runtime`** in the system PATH
2. **Configures containerd** to use the NVIDIA runtime
3. **Creates Kubernetes RuntimeClasses** for all detected runtimes

```bash
# Verify K3s detected the NVIDIA runtime
grep nvidia /var/lib/rancher/k3s/agent/etc/containerd/config.toml

# Check RuntimeClasses were created
kubectl get runtimeclass
# Should show: nvidia, nvidia-experimental, etc.
```

### The Critical runtimeClassName Requirement

**⚠️ IMPORTANT:** Just requesting `nvidia.com/gpu` is NOT enough!

Pods need **two things** to use the GPU:

| Requirement | Purpose | What Happens Without It |
|-------------|---------|------------------------|
| `resources.limits.nvidia.com/gpu: 1` | Reserves GPU from scheduler | Pod won't be scheduled on GPU node |
| `runtimeClassName: nvidia` | Uses NVIDIA container runtime | Container can't access GPU libraries (libnvidia-ml.so) |

### Why runtimeClassName is Required

```
┌─────────────────────────────────────────────────────────────────────────┐
│  WITHOUT runtimeClassName: nvidia                                       │
│                                                                         │
│  Container uses default 'runc' runtime                                 │
│  → NVIDIA libraries NOT mounted into container                          │
│  → nvidia-smi fails: "libnvidia-ml.so.1: cannot open shared object"    │
│  → GPU visible to scheduler but NOT to application                     │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│  WITH runtimeClassName: nvidia                                          │
│                                                                         │
│  Container uses 'nvidia-container-runtime'                             │
│  → NVIDIA libraries mounted from host: /usr/lib/x86_64-linux-gnu/...   │
│  → nvidia-smi works: shows GPU info                                    │
│  → Application (Ollama, vLLM) can use CUDA                             │
└─────────────────────────────────────────────────────────────────────────┘
```

### Correct GPU Pod Specification

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: gpu-pod
spec:
  runtimeClassName: nvidia    # ← CRITICAL: Use NVIDIA container runtime
  containers:
  - name: cuda-container
    image: nvidia/cuda:12.2.0-base-ubuntu22.04
    command: ["nvidia-smi"]
    resources:
      limits:
        nvidia.com/gpu: 1     # ← Reserve GPU from scheduler
```

### NVIDIA Device Plugin Also Needs runtimeClassName

The NVIDIA Device Plugin DaemonSet itself needs `runtimeClassName: nvidia` to function correctly. Without it, the plugin can't access NVIDIA libraries to detect GPUs.

MyNodeOne's device plugin manifest includes this:

```yaml
# manifests/gpu/nvidia-device-plugin.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nvidia-device-plugin-daemonset
  namespace: kube-system
spec:
  template:
    spec:
      runtimeClassName: nvidia   # ← Required for plugin to detect GPUs
      containers:
      - name: nvidia-device-plugin-ctr
        image: nvcr.io/nvidia/k8s-device-plugin:v0.14.5
```

**Note:** The upstream NVIDIA manifest does NOT include `runtimeClassName`. MyNodeOne adds it.

---

## Using GPUs in Pods

### Requesting GPU Resources

**Complete example** with both required elements:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: gpu-pod
spec:
  runtimeClassName: nvidia    # Required for GPU library access
  containers:
  - name: cuda-container
    image: nvidia/cuda:12.2.0-base-ubuntu22.04
    command: ["nvidia-smi"]
    resources:
      limits:
        nvidia.com/gpu: 1     # Required for GPU scheduling
```

### Example: vLLM Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm
  namespace: ai
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vllm
  template:
    metadata:
      labels:
        app: vllm
    spec:
      runtimeClassName: nvidia    # ← CRITICAL
      containers:
      - name: vllm
        image: vllm/vllm-openai:latest
        args:
          - "--model"
          - "mistralai/Mistral-7B-Instruct-v0.2"
          - "--max-model-len"
          - "4096"
        resources:
          limits:
            nvidia.com/gpu: 1
        ports:
        - containerPort: 8000
        env:
        - name: HUGGING_FACE_HUB_TOKEN
          valueFrom:
            secretKeyRef:
              name: hf-token
              key: token
        volumeMounts:
        - name: model-cache
          mountPath: /root/.cache/huggingface
      volumes:
      - name: model-cache
        persistentVolumeClaim:
          claimName: model-cache-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: vllm
  namespace: ai
spec:
  type: LoadBalancer
  ports:
  - port: 8000
    targetPort: 8000
  selector:
    app: vllm
```

### Example: Ollama Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ollama
  namespace: ai
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ollama
  template:
    metadata:
      labels:
        app: ollama
    spec:
      runtimeClassName: nvidia    # ← CRITICAL
      containers:
      - name: ollama
        image: ollama/ollama:latest
        resources:
          limits:
            nvidia.com/gpu: 1
        ports:
        - containerPort: 11434
        volumeMounts:
        - name: ollama-data
          mountPath: /root/.ollama
      volumes:
      - name: ollama-data
        persistentVolumeClaim:
          claimName: ollama-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: ollama
  namespace: ai
spec:
  type: LoadBalancer
  ports:
  - port: 11434
    targetPort: 11434
  selector:
    app: ollama
```

---

## How GPU Scheduling Works

### GPU Resources in Kubernetes

The NVIDIA Device Plugin runs as a DaemonSet on every GPU node. It:

1. **Detects GPUs** on each node using the NVIDIA driver
2. **Reports capacity** to Kubernetes (e.g., `nvidia.com/gpu: 1`)
3. **Allocates GPUs** to pods that request them

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         Kubernetes Cluster                               │
│                                                                          │
│  ┌─────────────────────┐    ┌─────────────────────┐                     │
│  │   Control Plane     │    │   Worker Node       │                     │
│  │   (RTX 3090)        │    │   (RTX 3090)        │                     │
│  │                     │    │                     │                     │
│  │   nvidia.com/gpu: 1 │    │   nvidia.com/gpu: 1 │                     │
│  │   ▲                 │    │   ▲                 │                     │
│  │   │ Device Plugin   │    │   │ Device Plugin   │                     │
│  └───┼─────────────────┘    └───┼─────────────────┘                     │
│      │                          │                                        │
│      └──────────┬───────────────┘                                        │
│                 │                                                        │
│                 ▼                                                        │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │              Kubernetes Scheduler                                │    │
│  │                                                                  │    │
│  │  Pod requests nvidia.com/gpu: 1                                 │    │
│  │  → Scheduler finds node with available GPU                      │    │
│  │  → Schedules pod on that node                                   │    │
│  │  → Device Plugin assigns specific GPU to container              │    │
│  └─────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────┘
```

### Key Points

- **Each node reports its own GPUs** - GPUs are NOT shared across nodes
- **Scheduler picks the node** - When you request a GPU, Kubernetes finds a node with one available
- **No internet required** - The Device Plugin runs locally and doesn't need network access
- **GPUs are exclusive** - A GPU assigned to one pod cannot be used by another

### Viewing Available GPUs

```bash
# See GPU capacity on all nodes
kubectl describe nodes | grep -A5 "Allocatable" | grep gpu

# Or more detailed:
kubectl get nodes -o custom-columns="NODE:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu"
```

Example output with 2 GPU nodes:
```
NODE              GPU
control-plane     1
gpu-worker        1
```

---

## Multi-GPU Configurations

### Single Node with Multiple GPUs

If you have multiple GPUs in one node (e.g., 2x RTX 3090):

```yaml
resources:
  limits:
    nvidia.com/gpu: 2  # Request both GPUs
```

For tensor parallelism (splitting one model across GPUs):

```yaml
env:
- name: CUDA_VISIBLE_DEVICES
  value: "0,1"
args:
  - "--tensor-parallel-size"
  - "2"
```

### Multiple Nodes with GPUs

When you have GPUs on different machines (e.g., control plane + worker):

```
┌─────────────────────┐    ┌─────────────────────┐
│   Control Plane     │    │   Worker Node       │
│   RTX 3090 (24GB)   │    │   RTX 3090 (24GB)   │
│                     │    │                     │
│   Pod: vllm-1       │    │   Pod: vllm-2       │
│   (Mistral-7B)      │    │   (Llama-13B)       │
└─────────────────────┘    └─────────────────────┘
```

**Kubernetes automatically distributes GPU workloads:**

```yaml
# This deployment will spread across GPU nodes
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm
spec:
  replicas: 2  # One pod per GPU node
  template:
    spec:
      containers:
      - name: vllm
        resources:
          limits:
            nvidia.com/gpu: 1
```

**To target a specific node:**

```yaml
spec:
  nodeSelector:
    kubernetes.io/hostname: gpu-worker  # Run on specific node
```

**To run on any GPU node:**

```yaml
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: nvidia.com/gpu.present
            operator: Exists
```

### Cross-Node GPU Limitations

**Important:** You cannot combine GPUs from different nodes for a single model. Each pod runs on ONE node and can only use GPUs from that node.

| Scenario | Possible? | Solution |
|----------|-----------|----------|
| Run 2 separate models on 2 GPU nodes | ✓ Yes | Deploy 2 pods, each requests 1 GPU |
| Run 1 model across 2 GPUs on same node | ✓ Yes | Request 2 GPUs, use tensor parallelism |
| Run 1 model across 2 GPUs on different nodes | ✗ No | Use a smaller/quantized model, or add more GPUs to one node |

---

## GPU Memory Considerations

### RTX 3090 (24GB VRAM)

| Model Size | Quantization | Fits in 24GB? | Notes |
|------------|--------------|---------------|-------|
| 7B | FP16 | Yes | ~14GB, room for context |
| 13B | FP16 | Yes | ~26GB tight, use Q8 |
| 13B | Q8 | Yes | ~13GB, comfortable |
| 70B | Q4 | Yes | ~35GB → fits with offloading |
| 70B | FP16 | No | Needs 140GB+ |

### Recommended Settings for RTX 3090

```yaml
# vLLM with 7B model
args:
  - "--model"
  - "mistralai/Mistral-7B-Instruct-v0.2"
  - "--max-model-len"
  - "8192"
  - "--gpu-memory-utilization"
  - "0.9"

# vLLM with larger model (quantized)
args:
  - "--model"
  - "TheBloke/Llama-2-70B-Chat-AWQ"
  - "--quantization"
  - "awq"
  - "--max-model-len"
  - "4096"
```

---

## Troubleshooting

### Quick Diagnostic Commands

```bash
# 1. Check GPU visible to host
nvidia-smi

# 2. Check GPU visible to Kubernetes
kubectl describe node | grep nvidia.com/gpu

# 3. Check RuntimeClass exists
kubectl get runtimeclass nvidia

# 4. Check device plugin is running
kubectl get pods -n kube-system -l name=nvidia-device-plugin-ds

# 5. Check device plugin logs
kubectl logs -n kube-system -l name=nvidia-device-plugin-ds --tail=50

# 6. Check if K3s detected nvidia runtime
grep nvidia /var/lib/rancher/k3s/agent/etc/containerd/config.toml
```

### GPU Not Detected by Kubernetes

Symptom: `kubectl describe node | grep nvidia.com/gpu` shows nothing.

```bash
# Check driver is working
nvidia-smi

# Check container toolkit
nvidia-ctk --version
nvidia-container-runtime --version

# Check device plugin pods
kubectl get pods -n kube-system | grep nvidia

# Check device plugin logs
kubectl logs -n kube-system -l name=nvidia-device-plugin-ds
```

### Device Plugin Shows "Incompatible Platform" or "libnvidia-ml.so not found"

Symptom: Device plugin logs show:
```
E factory.go:115] Incompatible platform detected
E factory.go:116] If this is a GPU node, did you configure the NVIDIA Container Toolkit?
main.go:287] No devices found. Waiting indefinitely.
```

**Root Cause:** Device plugin pod is missing `runtimeClassName: nvidia`.

**Fix:**
```bash
# Use MyNodeOne's patched manifest
kubectl delete daemonset nvidia-device-plugin-daemonset -n kube-system
kubectl apply -f manifests/gpu/nvidia-device-plugin.yaml

# Or patch existing deployment
kubectl patch daemonset nvidia-device-plugin-daemonset -n kube-system \
  --type='json' -p='[{"op": "add", "path": "/spec/template/spec/runtimeClassName", "value": "nvidia"}]'
```

### GPU Detected but Application Shows "0 B VRAM" or "offloaded 0 layers to GPU"

Symptom: Ollama/vLLM logs show:
```
msg="inference compute" id=cpu library=cpu ... total="128.0 GiB"
msg="entering low vram mode" "total vram"="0 B"
msg="offloaded 0/25 layers to GPU"
```

**Root Cause:** Application pod has GPU resource request but missing `runtimeClassName: nvidia`.

**Diagnosis:**
```bash
# Check pod's runtimeClassName
kubectl get pod <pod-name> -n <namespace> -o yaml | grep runtimeClassName
# Should output: runtimeClassName: nvidia

# Check pod's resource requests
kubectl get pod <pod-name> -n <namespace> -o yaml | grep -A10 resources:
```

**Fix:**
```bash
# Patch deployment to add runtimeClassName
kubectl patch deployment <app-name> -n <namespace> --type='json' \
  -p='[{"op": "add", "path": "/spec/template/spec/runtimeClassName", "value": "nvidia"}]'

# Wait for rollout
kubectl rollout status deployment/<app-name> -n <namespace>
```

### Verifying GPU is Actually Being Used

```bash
# For Ollama - check logs for CUDA detection
kubectl logs -n llm-chat -l app=ollama --tail=100 | grep -i -E "cuda|gpu|vram"

# Should show:
#   msg="inference compute" ... library=CUDA ... total="24.0 GiB"
#   msg="gpu memory" ... available="23.1 GiB"
#   ggml_cuda_init: found 1 CUDA devices
#   msg="offloaded 25/25 layers to GPU"

# For any GPU pod - check nvidia-smi inside container
kubectl exec -it <pod-name> -n <namespace> -- nvidia-smi
```

### RuntimeClass Not Found

Symptom: `kubectl get runtimeclass nvidia` returns "not found".

**Root Cause:** K3s didn't detect nvidia-container-runtime at startup.

**Fix:**
```bash
# Verify nvidia-container-runtime exists
which nvidia-container-runtime
# Should return: /usr/bin/nvidia-container-runtime

# Restart K3s to trigger runtime detection
sudo systemctl restart k3s

# Wait and check again
sleep 30
kubectl get runtimeclass nvidia
```

### Pod Stuck in Pending

```bash
# Check if GPU resources are available
kubectl describe node <node-name> | grep -A10 "Allocated resources"

# Check pod events
kubectl describe pod <pod-name>

# Common causes:
# - "Insufficient nvidia.com/gpu" → All GPUs in use
# - "node(s) didn't match Pod's node affinity" → No GPU nodes available
```

### CUDA Out of Memory

```yaml
# Reduce memory usage
env:
- name: PYTORCH_CUDA_ALLOC_CONF
  value: "max_split_size_mb:512"
args:
  - "--gpu-memory-utilization"
  - "0.8"  # Use only 80% of VRAM
```

---

## Summary

| Layer | Component | Install On | Purpose |
|-------|-----------|------------|---------|
| Hardware | NVIDIA GPU | Physical machine | Compute |
| Host | NVIDIA Driver | Each GPU node | Hardware access |
| Host | Container Toolkit | Each GPU node | Container GPU access |
| Kubernetes | Device Plugin | Cluster (DaemonSet) | Resource scheduling |
| Container | CUDA, cuDNN, ML libs | Container images | Application runtime |

**Key Principle:** Install minimal components on host (driver + toolkit). Everything else runs in containers.

---

## Related Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md) - Overall system design
- [SYNC-CONTROLLER-V2.md](SYNC-CONTROLLER-V2.md) - Node configuration sync