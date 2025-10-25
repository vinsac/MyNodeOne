# Contributing to MyNodeOne

Thank you for your interest in contributing to MyNodeOne! This document provides guidelines and information for contributors.

## Code of Conduct

Be respectful, inclusive, and constructive. We're building a community tool for everyone.

## How to Contribute

### Reporting Bugs

1. Check if the issue already exists
2. Use the issue template
3. Include:
   - MyNodeOne version
   - Kubernetes version
   - Operating system
   - Steps to reproduce
   - Expected vs actual behavior
   - Logs and error messages

### Suggesting Features

1. Open an issue with the "enhancement" label
2. Describe the use case
3. Explain why it would benefit MyNodeOne users
4. Consider implementation complexity

### Contributing Code

1. **Fork the repository**
2. **Create a feature branch**
   ```bash
   git checkout -b feature/your-feature-name
   ```

3. **Make your changes**
   - Follow existing code style
   - Add comments for complex logic
   - Update documentation if needed

4. **Test your changes**
   - Test on a real MyNodeOne cluster
   - Verify backward compatibility
   - Check all scripts run successfully

5. **Commit with clear messages**
   ```bash
   git commit -m "Add feature: brief description"
   ```

6. **Push and create a pull request**
   ```bash
   git push origin feature/your-feature-name
   ```

## Development Setup

```bash
# Clone your fork
git clone https://github.com/yourusername/mynodeone.git
cd mynodeone

# Add upstream remote
git remote add upstream https://github.com/original/mynodeone.git

# Create test environment (optional)
# Use a VM or spare machine for testing
```

## Areas for Contribution

### High Priority
- [ ] GPU support for LLM workloads
- [ ] Database operators (PostgreSQL, MySQL, MongoDB)
- [ ] Automated backup and restore
- [ ] Multi-region support
- [ ] Improved monitoring dashboards

### Medium Priority
- [ ] CI/CD pipeline improvements
- [ ] More example applications
- [ ] Performance optimizations
- [ ] Better error handling
- [ ] Additional documentation

### Easy First Issues
- [ ] Documentation improvements
- [ ] Example applications
- [ ] Bug fixes
- [ ] Script improvements
- [ ] README updates

## Coding Standards

### Shell Scripts
- Use `#!/bin/bash`
- Include error handling: `set -euo pipefail`
- Use meaningful variable names
- Add comments for complex sections
- Use functions for reusability
- Check for prerequisites
- Provide helpful error messages

### Kubernetes Manifests
- Follow Kubernetes best practices
- Include resource limits and requests
- Add health checks (liveness/readiness probes)
- Use meaningful labels
- Include comments
- Use versioned API resources

### Documentation
- Write clear, concise documentation
- Include examples
- Update table of contents if needed
- Check spelling and grammar
- Use markdown formatting
- Include code blocks with syntax highlighting

## Testing

Before submitting a PR:

1. **Test bootstrap script**
   ```bash
   # On a clean Ubuntu 24.04 VM
   sudo ./scripts/bootstrap-control-plane.sh
   ```

2. **Test worker node addition**
   ```bash
   sudo ./scripts/add-worker-node.sh
   ```

3. **Test app deployment**
   ```bash
   kubectl apply -f manifests/examples/hello-world-app.yaml
   ```

4. **Verify monitoring**
   - Check Grafana dashboards
   - Verify metrics collection
   - Test alerting

5. **Check documentation**
   - Verify all links work
   - Ensure instructions are clear
   - Test commands on a real cluster

## Pull Request Process

1. **Update documentation** if needed
2. **Add tests** if applicable
3. **Update CHANGELOG.md** (if exists)
4. **Ensure CI passes** (if set up)
5. **Request review** from maintainers
6. **Address feedback** promptly
7. **Squash commits** if requested

## Commit Message Guidelines

```
<type>: <subject>

<body>

<footer>
```

**Types:**
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation changes
- `style`: Code style changes (formatting)
- `refactor`: Code refactoring
- `test`: Adding tests
- `chore`: Maintenance tasks

**Examples:**
```
feat: Add GPU support for LLM workloads

Adds detection and configuration for NVIDIA GPUs
in worker nodes. Includes device plugin installation
and example manifest for GPU-accelerated pods.

Closes #123
```

```
fix: Resolve Longhorn volume attachment issue

Fixes a race condition where volumes would fail to
attach after node restart.

Fixes #456
```

## Documentation Structure

```
docs/
├── architecture.md      # System architecture
├── operations.md        # Day-to-day operations
├── troubleshooting.md   # Common issues
└── scaling.md          # Scaling guide
```

When adding new features, update relevant documentation.

## Release Process

Maintainers handle releases:

1. Update version number
2. Update CHANGELOG.md
3. Create git tag
4. Build and test release
5. Publish release notes
6. Update documentation

## Questions?

- Open a GitHub issue with the "question" label
- Join our community chat (if available)
- Email maintainers

## Recognition

Contributors will be:
- Listed in CONTRIBUTORS.md
- Mentioned in release notes
- Given credit in documentation

Thank you for contributing to MyNodeOne! 🚀
