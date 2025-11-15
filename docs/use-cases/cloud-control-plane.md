# Use Case: Deploying a Control Plane on a Cloud Server (VPS/VDS)

This guide covers the recommended architecture and security posture when your primary Control Plane is not on a physical machine in your home, but is instead a cloud server (like a VPS or VDS) with a public IP address.

## The Challenge: No Physical Security

When your Control Plane is on the public internet, you lose the inherent security of a private home network. You cannot simply hide it behind a router. This makes it a potential target for scans and attacks.

## The Solution: Isolate, Don't Just Hide

The core security principle evolves. Instead of hiding the Control Plane, you must **aggressively isolate it** using a combination of a software firewall and a private networking overlay like Tailscale.

The goal is to create a secure, private network in the cloud that makes your Control Plane completely inaccessible from the public internet, except from your trusted Management Laptop.

## Architectural Pattern

| Component | Physical Control Plane | Cloud Control Plane |
| :--- | :--- | :--- |
| **Secure Zone** | Your Home LAN | Your Management Laptop |
| **Secure Network** | Your Home LAN | Tailscale VPN |
| **Access Method** | SSH directly on LAN | SSH from Laptop over Tailscale IP |
| **Firewall Rule** | Allow SSH from LAN | **Allow SSH *only* from Laptop's Tailscale IP** |
| **Security Principle** | Hide the Control Plane | **Isolate** the Control Plane |

## Step-by-Step Security Workflow

Here is the mandatory workflow for setting up a secure Control Plane on a cloud server.

### 1. Initial Setup

- Provision your cloud server (Machine A) that will act as the Control Plane.
- Provision a laptop/desktop (Machine C) that will be your Management Laptop.
- Install Tailscale on **both** the Control Plane and the Management Laptop. Authenticate both to your Tailscale account.

### 2. Harden the Control Plane Firewall

This is the most critical step. You will configure the firewall on the Control Plane (`ufw` on Ubuntu) to deny all incoming SSH connections by default, and then add a single, specific exception for your Management Laptop's private Tailscale IP.

**On your Cloud Control Plane (Machine A):**

```bash
# First, find your Management Laptop's Tailscale IP.
# Run this on your laptop (Machine C):
tailscale status
# Note the 100.x.y.z IP of your laptop.

# Now, on the Control Plane (Machine A), configure the firewall:

# 1. Deny all incoming traffic by default
sudo ufw default deny incoming

# 2. Allow all outgoing traffic
sudo ufw default allow outgoing

# 3. IMPORTANT: Allow SSH connections ONLY from your laptop's Tailscale IP
# Replace <LAPTOP_TAILSCALE_IP> with the IP you noted.
sudo ufw allow from <LAPTOP_TAILSCALE_IP> to any port 22 proto tcp

# 4. (Optional but Recommended) Allow Tailscale traffic
sudo ufw allow 41641/udp

# 5. Enable the firewall
sudo ufw enable
```

**Result:** The Control Plane's public IP is now a brick wall to the internet. The only way to SSH into it is from your specific Management Laptop, through the secure Tailscale tunnel.

### 3. Proceed with MyNodeOne Installation

From this point forward, the installation process follows the main guide, with one key difference: **you always use Tailscale IPs, never public IPs, to connect to your Control Plane.**

1.  **On your Management Laptop (C)**, SSH into the Control Plane (A) using its **Tailscale IP**.
    ```bash
    ssh <your_user>@<CONTROL_PLANE_TAILSCALE_IP>
    ```
2.  Once inside the Control Plane, follow the `INSTALLATION.md` guide to install the MyNodeOne Control Plane software.
3.  To add another VPS Edge Node (Machine B), you run the `setup-edge-node.sh` script from within the Control Plane, exactly as described in the documentation.

This architecture provides a robust and secure foundation for running your entire MyNodeOne cluster in the cloud.
