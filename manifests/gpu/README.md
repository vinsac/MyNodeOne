# GPU Support Manifests

This directory contains Kubernetes manifests for enabling GPU support in MyNodeOne clusters, specifically for NVIDIA GPUs.

## 🎯 Purpose

Enable GPU acceleration for AI/ML workloads, scientific computing, and graphics-intensive applications in your MyNodeOne cluster.

## 📋 Prerequisites

### Hardware Requirements
- NVIDIA GPU (RTX 20xx series or newer recommended)
- CUDA-compatible GPU with minimum 4GB VRAM
- Sufficient power supply and cooling

### Software Requirements
- NVIDIA drivers installed on GPU nodes
- MyNodeOne cluster with GPU nodes
- Container runtime with NVIDIA support (configured by installer)

## 🚀 Quick Start

### 1. Verify GPU Detection
```bash
# Check if GPU is detected on the node
nvidia-smi

# Check GPU node status
kubectl get nodes -l accelerator=nvidia-gpu

# Check existing GPU resources
kubectl describe node <gpu-node-name> | grep -i nvidia
```

### 2. Deploy NVIDIA Device Plugin
```bash
# Deploy the NVIDIA device plugin
kubectl apply -f manifests/gpu/nvidia-device-plugin.yaml

# Wait for plugin to be ready
kubectl wait --for=condition=available --timeout=120s daemonset/nvidia-device-plugin-daemonset -n kube-system
```

### 3. Verify GPU Resources
```bash
# Check GPU resources are available
kubectl get nodes -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}'

# Check device plugin pods
kubectl get pods -n kube-system | grep nvidia-device-plugin
```

### 4. Deploy GPU Workload
```bash
# Deploy a test GPU application
kubectl apply -f manifests/examples/llm-gpu-inference.yaml  # If available

# Or create a simple GPU pod
kubectl run gpu-test --image=nvidia/cuda:11.8-base-ubuntu20.04 --rm -it --restart=Never -- nvidia-smi
```

## 📁 Available Manifests

### nvidia-device-plugin.yaml
**Purpose**: NVIDIA GPU device plugin for Kubernetes  
**Function**: Exposes GPU resources to the Kubernetes scheduler  
**Namespace**: `kube-system` (cluster-level)  
**Resources**: DaemonSet (runs on all GPU nodes)

**Features**:
- Automatic GPU discovery and registration
- GPU resource reporting (`nvidia.com/gpu`)
- Device management and isolation
- Health monitoring and recovery

## 🔧 Configuration

### GPU Node Labeling
GPU nodes should be labeled during installation:
```bash
# Check GPU node labels
kubectl get nodes --show-labels | grep accelerator

# Manually label GPU node (if needed)
kubectl label node <gpu-node-name> accelerator=nvidia-gpu
```

### Resource Requests
When deploying GPU applications:
```yaml
resources:
  requests:
    nvidia.com/gpu: 1  # Request 1 GPU
  limits:
    nvidia.com/gpu: 1  # Limit to 1 GPU
```

### Node Taints (Optional)
For dedicated GPU nodes:
```yaml
# Add taint to prevent non-GPU workloads
kubectl taint node <gpu-node-name> nvidia.com/gpu=true:NoSchedule

# Add toleration to GPU workloads
tolerations:
- key: "nvidia.com/gpu"
  operator: "Equal"
  value: "true"
  effect: "NoSchedule"
```

## 📊 Monitoring GPU Usage

### Check GPU Resource Usage
```bash
# View GPU resource allocation
kubectl describe nodes | grep -A 10 "Allocated resources"

# Check GPU-using pods
kubectl get pods --all-namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[*].resources.requests.nvidia\.com/gpu}{"\n"}{end}'
```

### Monitor GPU Performance
```bash
# SSH into GPU node and check GPU status
ssh <gpu-node-ip>
nvidia-smi

# Monitor GPU utilization
watch -n 1 nvidia-smi
```

## 🤖 GPU Workload Examples

### AI/ML Inference
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: llm-inference
spec:
  containers:
  - name: llm
    image: nvcr.io/nvidia/pytorch:23.10-py3
    resources:
      requests:
        nvidia.com/gpu: 1
    command: ["python", "-c", "import torch; print(f'CUDA available: {torch.cuda.is_available()}')"]
```

### Scientific Computing
```bash
# Deploy scientific computing workload
kubectl run scientific-compute \
  --image=nvidia/cuda:11.8-base-ubuntu20.04 \
  --restart=Never \
  --requests=nvidia.com/gpu=1 \
  --limits=nvidia.com/gpu=1 \
  --command -- sleep 3600
```

## 🛠️ Troubleshooting

### Common Issues

#### GPU Not Detected
```bash
# Check NVIDIA drivers
nvidia-smi

# Check kernel modules
lsmod | grep nvidia

# Check device plugin logs
kubectl logs -n kube-system -l app=nvidia-device-plugin-daemonset
```

#### GPU Resources Not Available
```bash
# Check node capacity
kubectl describe node <gpu-node-name> | grep -i capacity

# Check device plugin status
kubectl get daemonset nvidia-device-plugin-daemonset -n kube-system

# Restart device plugin
kubectl delete pod -n kube-system -l app=nvidia-device-plugin-daemonset
```

#### GPU Workload Fails
```bash
# Check pod events
kubectl describe pod <gpu-pod-name>

# Check GPU allocation
kubectl get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[*].resources.requests.nvidia\.com/gpu}{"\n"}{end}'

# Check node conditions
kubectl get nodes -o wide
```

### Debug Commands
```bash
# Check all GPU-related resources
kubectl get all -n kube-system | grep nvidia

# Check GPU device plugin logs
kubectl logs -n kube-system daemonset/nvidia-device-plugin-daemonset

# Verify GPU device files
kubectl exec -n kube-system <device-plugin-pod> -- ls /dev/nvidia*
```

## 🔄 Updates and Maintenance

### Update NVIDIA Drivers
```bash
# On GPU nodes (requires reboot)
sudo apt update
sudo apt install nvidia-driver-535  # Or latest version
sudo reboot

# Verify after reboot
nvidia-smi
```

### Update Device Plugin
```bash
# Redeploy with latest configuration
kubectl delete -f manifests/gpu/nvidia-device-plugin.yaml
kubectl apply -f manifests/gpu/nvidia-device-plugin.yaml
```

## 🔗 Related Documentation

- **GPU Support Guide**: [../../docs/architecture/GPU-SUPPORT.md](../../docs/architecture/GPU-SUPPORT.md)
- **LLM Deployment**: [../../docs/apps/APP-STORE.md](../../docs/apps/APP-STORE.md#ai--assistant)
- **Cluster Management**: [../../docs/operations/CLUSTER-MANAGEMENT.md](../../docs/operations/CLUSTER-MANAGEMENT.md)
- **Troubleshooting**: [../../docs/operations/troubleshooting.md](../../docs/operations/troubleshooting.md)

## 📚 Additional Resources

- [NVIDIA Kubernetes Device Plugin](https://github.com/NVIDIA/k8s-device-plugin)
- [CUDA Documentation](https://docs.nvidia.com/cuda/)
- [Kubernetes GPU Scheduling](https://kubernetes.io/docs/tasks/manage-gpus/scheduling-gpus/)

## 🧹 Cleanup

Remove GPU support:
```bash
# Remove device plugin
kubectl delete -f manifests/gpu/nvidia-device-plugin.yaml

# Remove GPU node labels (optional)
kubectl label node <gpu-node-name> accelerator-

# Remove GPU taints (if applied)
kubectl taint node <gpu-node-name> nvidia.com/gpu-
```
