# MyNodeOne Architecture Overview

## Core Security Principle: Direction of Trust

A fundamental security principle in the MyNodeOne architecture is the **unidirectional flow of trust and connectivity**. The cluster's internal network, especially the **Control Plane**, is considered a secure, trusted zone. All external nodes, such as a public-facing **VPS Edge Node**, are considered untrusted.

### Control Plane -> Untrusted Nodes

- **Connections Originate from the Inside:** All administrative connections, such as for installation, configuration, and synchronization, must originate from the Control Plane and connect outwards to the edge nodes (like a VPS).

- **No Inbound Public Access to Control Plane:** The Control Plane's SSH port should **never** be exposed to the public internet. It should only be accessible via your local LAN or a secure private network like Tailscale.

- **Why this is critical:** If a public-facing VPS were ever compromised, an attacker would have no network path and no credentials to access the Control Plane. This minimizes the attack surface and protects the core of your private cloud.

### How Installation Enforces This

The installation scripts, particularly `setup-edge-node.sh`, are designed to be run **on the Control Plane**. The script then reaches out to the target VPS to perform the setup. 

This enforces the security model by ensuring that only the Control Plane needs the private key to manage the cluster. The VPS only has a public key, which allows the Control Plane to connect to it, but not the other way around.
