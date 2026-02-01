# Dependency Management & File Ownership

This document outlines the dependency management requirements and file ownership standards for MyNodeOne components.

## Overview

MyNodeOne consists of multiple components that depend on shared libraries and configuration files. Proper dependency management ensures reliable installation and operation across all node types.

## Critical Dependencies

### config-paths.sh

**Purpose**: Centralized configuration path management for all MyNodeOne scripts

**Location**: `/usr/local/bin/config-paths.sh`

**Required by**: 
- `mynodeone-node-agent` (all node types)
- Various installation and management scripts

**Installation Requirements**:
```bash
# Copy from repository
cp ~/mynodeone/scripts/lib/config-paths.sh /usr/local/bin/

# Set executable permissions
chmod +x /usr/local/bin/config-paths.sh

# Set ownership (critical for security)
chown root:root /usr/local/bin/config-paths.sh
```

**Failure Symptoms**:
```
mynodeone-node-agent: line 43: /usr/local/bin/config-paths.sh: No such file or directory
```

## File Ownership Standards

### System Binaries

All system-level binaries must be owned by root:root:

```bash
# Standard ownership for system binaries
-rwxr-xr-x 1 root root 15893 Jan 24 07:01 /usr/local/bin/mynodeone-node-agent
-rwxr-xr-x 1 root root  6908 Jan 24 07:04 /usr/local/bin/config-paths.sh
```

### Configuration Files

Configuration files have specific ownership patterns:

```bash
# System configuration (root-owned)
-rw------- 1 root  root    20 Jan 24 15:48 /etc/mynodeone/.agent.state
-rw------- 1 sammy sammy  526 Jan 24 15:41 /etc/mynodeone/agent.env

# User configuration (user-owned)
-rw------- 1 sammy sammy 1156 Jan 24 15:37 /home/sammy/.mynodeone/config.env
```

## Installation Dependencies

### Node Agent Installation

The `install-node-agent.sh` script must ensure:

1. **Binary Installation**: Copy `mynodeone-node-agent` to `/usr/local/bin/`
2. **Dependency Installation**: Copy `config-paths.sh` to `/usr/local/bin/`
3. **Permission Setting**: Set executable permissions on both files
4. **Ownership Setting**: Set root:root ownership on both files

### VPS Edge Node Installation

VPS installations have additional requirements:

1. **Partial Repository**: Only scripts directory copied (not full repo)
2. **Runtime Dependencies**: Dependencies must be available at runtime paths
3. **Service Configuration**: systemd services require proper file permissions

## Dependency Installation Process

### During Node Agent Installation

```bash
# Install to /usr/local/bin if not already there
if [ ! -f "/usr/local/bin/mynodeone-node-agent" ]; then
    cp "$BINARY_SOURCE" /usr/local/bin/mynodeone-node-agent
    chmod +x /usr/local/bin/mynodeone-node-agent
fi

# Install config-paths.sh dependency for Node Agent
if [ ! -f "/usr/local/bin/config-paths.sh" ]; then
    if [ -f "$SCRIPT_DIR/../lib/config-paths.sh" ]; then
        cp "$SCRIPT_DIR/../lib/config-paths.sh" /usr/local/bin/
        chmod +x /usr/local/bin/config-paths.sh
        chown root:root /usr/local/bin/config-paths.sh
        log_success "config-paths.sh dependency installed"
    else
        log_warn "config-paths.sh not found, Node Agent may not work properly"
    fi
fi
```

### Manual Recovery

For existing installations missing dependencies:

```bash
# On affected node
sudo cp ~/mynodeone/scripts/lib/config-paths.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/config-paths.sh
sudo chown root:root /usr/local/bin/config-paths.sh
sudo systemctl restart mynodeone-node-agent
```

## Security Considerations

### Root Ownership

System binaries must be root-owned to:
- Prevent unauthorized modification
- Ensure systemd services can execute them
- Maintain system integrity

### Permission Model

```bash
# System binaries (executable by all, writable only by root)
-rwxr-xr-x 1 root root /usr/local/bin/mynodeone-*

# Configuration files (restricted access)
-rw------- 1 root root /etc/mynodeone/agent.state
-rw------- 1 user user /etc/mynodeone/agent.env
```

## Troubleshooting

### Common Issues

1. **Missing Dependency**: Node Agent fails to start
2. **Wrong Ownership**: Permission denied errors
3. **Missing Execute Bit**: Command not found errors

### Diagnostic Commands

```bash
# Check file existence and permissions
ls -la /usr/local/bin/config-paths.sh
ls -la /usr/local/bin/mynodeone-node-agent

# Check ownership
stat /usr/local/bin/config-paths.sh

# Check Node Agent status
sudo systemctl status mynodeone-node-agent
sudo journalctl -u mynodeone-node-agent -f
```

## Best Practices

### Installation Scripts

1. **Always check dependencies** before starting services
2. **Set proper ownership** explicitly (don't rely on defaults)
3. **Verify file permissions** before service start
4. **Log dependency installation** for debugging

### System Administration

1. **Monitor Node Agent logs** for dependency issues
2. **Regular health checks** include dependency verification
3. **Backup critical dependencies** during system maintenance
4. **Document custom dependencies** for system recovery

## Version Compatibility

Dependencies are version-specific:
- `config-paths.sh` must match the MyNodeOne version
- Node Agent requires compatible dependency versions
- Cross-version compatibility is not guaranteed

## Related Documentation

- [Sync Controller V2 Architecture](SYNC-CONTROLLER-V2.md)
- [Installation Guide](../installation/INSTALLATION.md)
- [Troubleshooting Guide](../operations/troubleshooting.md)
- [Security Best Practices](../security/BEST-PRACTICES.md)