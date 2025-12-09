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

### Automated Setup (Recommended)

MyNodeOne includes a GPU setup script that handles everything:

```bash
# Interactive mode - asks if you want GPU support
sudo ./scripts/lib/gpu-setup.sh

# Auto mode - installs if GPU detected
sudo ./scripts/lib/gpu-setup.sh --auto

# Check status only
sudo ./scripts/lib/gpu-setup.sh --check
```

### Manual Setup

#### Step 1: Install NVIDIA Driver

```bash
# Ubuntu 22.04/24.04
sudo apt update
sudo apt install -y nvidia-driver-550

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

## Using GPUs in Pods

### Requesting GPU Resources

Add `nvidia.com/gpu` to your pod's resource limits:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: gpu-pod
spec:
  containers:
  - name: cuda-container
    image: nvidia/cuda:12.2.0-base-ubuntu22.04
    command: ["nvidia-smi"]
    resources:
      limits:
        nvidia.com/gpu: 1  # Request 1 GPU
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

### GPU Not Detected by Kubernetes

```bash
# Check driver is working
nvidia-smi

# Check container toolkit
nvidia-ctk --version

# Check device plugin pods
kubectl get pods -n kube-system | grep nvidia

# Check device plugin logs
kubectl logs -n kube-system -l name=nvidia-device-plugin-ds
```

### Pod Stuck in Pending

```bash
# Check if GPU resources are available
kubectl describe node <node-name> | grep -A10 "Allocated resources"

# Check pod events
kubectl describe pod <pod-name>
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
