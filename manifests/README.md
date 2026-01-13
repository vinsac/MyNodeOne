# MyNodeOne Kubernetes Manifests

This directory contains Kubernetes manifests that serve as examples, templates, and configurations for MyNodeOne deployments.

## 📁 Directory Structure

```
manifests/
├── examples/           ← Example applications for learning and testing
├── gpu/               ← GPU support manifests for AI/ML workloads  
├── security/          ← Security configurations and policies
└── README.md          ← This file
```

## 🚀 Quick Start

### Deploy Example Applications
```bash
# Deploy a simple hello world app
kubectl apply -f manifests/examples/hello-world-app.yaml

# Deploy a full-stack application example
kubectl apply -f manifests/examples/fullstack-app.yaml

# Deploy LLM inference with CPU support
kubectl apply -f manifests/examples/llm-cpu-inference.yaml
```

### Enable GPU Support
```bash
# Deploy NVIDIA device plugin (if you have NVIDIA GPUs)
kubectl apply -f manifests/gpu/nvidia-device-plugin.yaml
```

### Apply Security Configurations
```bash
# Apply pod security standards
kubectl apply -f manifests/security/pod-security-config.yaml

# Apply network policies (example)
kubectl apply -f manifests/security/network-policy.yaml
```

## 📚 Usage Guidelines

### For Beginners
1. **Start with examples**: Begin with `hello-world-app.yaml` to understand basic deployment
2. **Learn by doing**: Modify the examples and see how changes affect deployment
3. **Check documentation**: Each subdirectory has its own README with detailed instructions

### For Advanced Users
1. **Use as templates**: Copy and modify examples for your own applications
2. **Reference configurations**: Use security manifests as security baselines
3. **GPU workloads**: Follow GPU setup instructions for AI/ML deployments

### For Development
1. **Test changes**: Apply manifests to test cluster before production
2. **Version control**: All manifests are tracked in git
3. **Customize**: Modify values (namespaces, resources, etc.) for your environment

## 🔧 Configuration Notes

### Namespaces
- Examples use dedicated namespaces (e.g., `demo-apps`, `hello-world`)
- Security configs apply to cluster-level resources
- GPU manifests deploy to `kube-system` namespace

### Resource Limits
- All examples include resource requests and limits
- Adjust based on your cluster capacity
- Monitor usage with `kubectl top nodes` and `kubectl top pods`

### Security
- Examples follow Pod Security Standards
- Network policies provide default-deny security
- GPU configs require proper node labels and taints

## 📖 Related Documentation

- **App Store**: [docs/apps/APP-STORE.md](../docs/apps/APP-STORE.md) - Available applications
- **GPU Support**: [docs/architecture/GPU-SUPPORT.md](../docs/architecture/GPU-SUPPORT.md) - Complete GPU setup
- **Security**: [docs/security/SECURITY.md](../docs/security/SECURITY.md) - Security overview
- **Create Apps**: `scripts/operations/create-app.sh` - Generate new app manifests

## 🛠️ Troubleshooting

### Common Issues
```bash
# Check if pods are running
kubectl get pods --all-namespaces

# Check pod events for errors
kubectl describe pod <pod-name> -n <namespace>

# Check node status
kubectl get nodes

# Check GPU availability (if using GPU manifests)
kubectl get nodes -l accelerator=nvidia-gpu
```

### Cleanup
```bash
# Remove example applications
kubectl delete -f manifests/examples/

# Remove GPU support
kubectl delete -f manifests/gpu/

# Remove security configs
kubectl delete -f manifests/security/
```

## 🤝 Contributing

When adding new manifests:
1. **Follow patterns**: Use existing manifests as templates
2. **Include documentation**: Add README for complex examples
3. **Test thoroughly**: Ensure manifests work on fresh clusters
4. **Security first**: Apply Pod Security Standards and resource limits

## 📄 License

These manifests are part of MyNodeOne and licensed under the MIT License.
