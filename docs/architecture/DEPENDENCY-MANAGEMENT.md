# Dependency Management & File Ownership

This document outlines the dependency management requirements and file ownership standards for MyNodeOne components.

## Overview

MyNodeOne consists of multiple components that depend on shared libraries and configuration files. Proper dependency management ensures reliable installation and operation across all node types.

## Critical Dependencies

### config-paths.sh

**Purpose**: Centralized configuration path management for MyNodeOne scripts

**Location**: `scripts/lib/config-paths.sh`, sourced from the repository

**Required by**: Various installation and management scripts

**Not required by the Node Agent.** The agent (`scripts/lib/node-agent.sh`, installed as `/usr/local/bin/mynodeone-node-agent`) must not depend on any other file in this repository, so `/usr/local/bin/config-paths.sh` is no longer needed.

**Failure Symptoms on older installs**, whose agent still sources that file:
```
mynodeone-node-agent: line 43: /usr/local/bin/config-paths.sh: No such file or directory
```
To fix this, install the current agent (see [Manual Recovery](#manual-recovery)).

## File Ownership Standards

### System Binaries

All system-level binaries must be owned by root:root:

```bash
# Standard ownership for system binaries
-rwxr-xr-x 1 root root 15893 Jan 24 07:01 /usr/local/bin/mynodeone-node-agent
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

`install-node-agent.sh` and `install-config-sync.sh` both install through `scripts/lib/node-agent-install.sh`, which must ensure:

1. **Agent Installation**: Copy `scripts/lib/node-agent.sh` to `/usr/local/bin/mynodeone-node-agent`, replacing what's there
2. **Unit Installation**: Copy `scripts/lib/mynodeone-node-agent.service` to `/etc/systemd/system/`
3. **Permission Setting**: Set executable permissions on the agent
4. **Ownership Setting**: Set root:root ownership on the agent

### VPS Edge Node Installation

VPS installations have additional requirements:

1. **Partial Repository**: Only scripts directory copied (not full repo)
2. **Runtime Dependencies**: Dependencies must be available at runtime paths
3. **Service Configuration**: systemd services require proper file permissions

## Dependency Installation Process

### During Node Agent Installation

`node_agent_install_files` in `scripts/lib/node-agent-install.sh` always installs the repository's copy, and renames it into place so that a running agent never executes a half-written file.

### Manual Recovery

For an installation whose agent is out of date or won't start:

```bash
# On the affected node, from the repository
sudo ./scripts/installation/install-node-agent.sh \
  --control-plane-ip <ip> --node-name <name> --node-type <type>
```

This replaces the agent and its unit, and restarts the service. With no token option, it keeps the token in an existing `/etc/mynodeone/agent.env`.

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

1. **Old Agent**: Node Agent fails to start, looking for `config-paths.sh`
2. **Wrong Ownership**: Permission denied errors
3. **Missing Execute Bit**: Command not found errors

### Diagnostic Commands

```bash
# Check file existence, permissions and ownership
ls -la /usr/local/bin/mynodeone-node-agent

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

1. **Monitor Node Agent logs** for start failures
2. **Regular health checks** include the agent's status
3. **Document custom dependencies** for system recovery

## Version Compatibility

The scripts in a checkout are written to work together. Update the Node Agent by re-running its installer from the same checkout as the rest of the node's scripts; cross-version compatibility is not guaranteed.

## Related Documentation

- [Sync Controller V2 Architecture](SYNC-CONTROLLER-V2.md)
- [Installation Guide](../installation/INSTALLATION.md)
- [Troubleshooting Guide](../operations/troubleshooting.md)
- [Security Best Practices](../security/BEST-PRACTICES.md)