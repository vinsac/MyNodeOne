# Contributing to MyNodeOne

Contributions are welcome! Please be respectful and constructive.

## Reporting Issues

Before opening an issue, check if it already exists. Include:
- Steps to reproduce
- Expected vs actual behavior
- Relevant logs or error messages

## Contributing Code

1. Fork the repository and create a feature branch
2. Make your changes following existing code style
3. Test on a real cluster before submitting
4. Submit a pull request with a clear description

### Code Guidelines

**Shell scripts:** Use `set -euo pipefail`, meaningful variable names, and helpful error messages.

**Kubernetes manifests:** Include resource limits, health checks, and meaningful labels.

**Documentation:** Keep it clear and concise, include examples, verify links work.

### Testing

Before submitting, test your changes:
```bash
# Test on a clean Ubuntu 24.04 system
sudo ./scripts/install-mynodeone.sh
```

## Pull Requests

- Update documentation if needed
- Describe what the change does and why
- Reference any related issues

Thank you for contributing!
