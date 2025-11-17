# MyNodeOne System Architecture Overview

This document outlines the core architectural principles, node roles, and communication patterns within a MyNodeOne cluster. Its purpose is to establish a clear foundation for development and troubleshooting.

## Core Principles

1.  **Control Plane as the Source of Truth:** The Control Plane holds all cluster configuration, node registration details, and application definitions. Other nodes are considered stateless clients that receive their configuration from the Control Plane.
2.  **Secure by Default:** Private keys and sensitive credentials should remain on the most secure node (the Control Plane) whenever possible. Communication between nodes is encrypted via Tailscale.
3.  **Automation over Manual Intervention:** Node setup, registration, and configuration synchronization are designed to be automated through scripts, minimizing the need for manual SSH and configuration edits.
4.  **Declarative Configuration:** Node registration and application routing are stored declaratively in Kubernetes ConfigMaps, allowing for version control and easy inspection.

## Node Roles

-   **Control Plane:**
    -   Runs the Kubernetes master components (k3s).
    -   Hosts the `sync-controller` service, which pushes configuration updates to other nodes.
    -   Stores the central `node-registry`, which tracks all nodes in the cluster.
    -   Holds the private SSH keys (`mynodeone_id_ed25519`) required to access and manage all other nodes.

-   **VPS Edge Node:**
    -   A public-facing server that acts as a reverse proxy (using Traefik) for cluster applications.
    -   Does **not** hold private keys for accessing other nodes.
    -   Receives routing updates from the Control Plane's `sync-controller`.
    -   Its primary role is to terminate public TLS and forward traffic to internal services over the Tailscale network.

-   **Worker Node:**
    -   Provides additional compute and storage resources for the Kubernetes cluster.
    -   Joins the cluster using a token provided by the Control Plane.
    -   Receives DNS updates from the `sync-controller`.

-   **Management Laptop:**
    -   A developer's or administrator's machine used for interacting with the cluster via `kubectl`.
    -   Does not run cluster workloads but needs cluster access credentials.
    -   Receives DNS updates from the `sync-controller` to resolve internal `.local` domains.

## Communication & Installation Flow (VPS Example)

This section details the intended flow for adding a new VPS node, which has been a point of friction.

1.  **Prerequisite:** The Control Plane is already installed and running.
2.  **On the VPS:** The user runs the `interactive-setup.sh` wizard.
    -   The wizard identifies itself as a 'VPS Edge Node'.
    -   It prompts for the Control Plane's Tailscale IP and an SSH username.
    -   **Problem Point:** It then attempts to SSH *from the VPS to the Control Plane* to fetch cluster details. This requires the user to have pre-configured key-based SSH from the VPS *to* the Control Plane, which is counter-intuitive and often fails.
3.  **Key Exchange (The Manual Step):**
    -   To make the automation work, the user must manually copy the Control Plane's public SSH key (`/root/.ssh/mynodeone_id_ed25519.pub`) into the VPS's `authorized_keys` file (`/home/sammy/.ssh/authorized_keys`).
    -   This allows the Control Plane to SSH *into* the VPS later.
4.  **On the VPS (Continued):** The user runs `setup-edge-node.sh`.
    -   This script performs local setup (Docker, Traefik, firewall).
    -   Crucially, it then SSHes *back to the Control Plane* and executes `node-registry-manager.sh` to register itself in the central ConfigMap.
    -   **Problem Point:** This step relies on the initial, often-failed SSH connection from step 2 to work.
5.  **Ongoing Management:**
    -   Once registered, the `sync-controller` on the Control Plane periodically SSHes *to the VPS* (using the key from step 3) to run `sync-vps-routes.sh`, keeping its Traefik configuration up-to-date.

## Identified Issues & Areas for Improvement

-   **Confusing SSH Flow:** The installation requires bidirectional SSH access that is not clearly explained or automated. The user shouldn't need to set up keys on the VPS to pull info from the Control Plane.
-   **Fragile Installation:** The process fails if the initial SSH check from the VPS to the Control Plane doesn't work, even though the long-term requirement is for the Control Plane to SSH to the VPS.
-   **Lack of a Centralized Orchestrator:** The installation is initiated from the new node, which has to reach back to the Control Plane. A more robust model might involve initiating the new node addition *from* the Control Plane.

## Proposed Core Principles for Redesign

1.  **Unidirectional Control:** The Control Plane initiates all actions. A new node should never need to SSH into the Control Plane.
2.  **Simplified Bootstrap:** A new node should only need a minimal bootstrap script or command. All complex logic should reside on the Control Plane.
3.  **Clear Security Boundary:** The only required access should be from the Control Plane *to* the new node, initiated by the administrator on the Control Plane.
