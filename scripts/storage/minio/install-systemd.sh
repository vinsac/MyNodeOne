#!/bin/bash

# Simple MinIO installation as systemd service
# No kubectl, no Kubernetes - just like PostgreSQL or Redis

set -euo pipefail

# Download and install MinIO binary
wget -q https://dl.min.io/server/minio/release/linux-amd64/minio -O /usr/local/bin/minio
chmod +x /usr/local/bin/minio

# Create minio user
if ! id -u minio &>/dev/null; then
    useradd -r -s /sbin/nologin minio
fi

# Set data path ownership
MINIO_DATA_PATH="${1:-/mnt/minio}"
chown -R minio:minio "$MINIO_DATA_PATH"

# Generate credentials
MINIO_ROOT_USER="admin"
MINIO_ROOT_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)

# Create systemd service
cat > /etc/systemd/system/minio.service <<EOF
[Unit]
Description=MinIO Object Storage
Documentation=https://min.io/docs/minio/linux/index.html
After=network.target

[Service]
Type=simple
User=minio
Group=minio
Environment="MINIO_ROOT_USER=${MINIO_ROOT_USER}"
Environment="MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}"
ExecStart=/usr/local/bin/minio server ${MINIO_DATA_PATH} --console-address ":9001" --address ":9000"
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# Start service
systemctl daemon-reload
systemctl enable minio
systemctl start minio

# Wait for startup
sleep 5

if systemctl is-active --quiet minio; then
    echo "✓ MinIO started successfully"
    echo "  API: http://$(hostname -I | awk '{print $1}'):9000"
    echo "  Console: http://$(hostname -I | awk '{print $1}'):9001"
    echo "  Username: $MINIO_ROOT_USER"
    echo "  Password: $MINIO_ROOT_PASSWORD"
else
    echo "✗ MinIO failed to start"
    journalctl -u minio --no-pager -n 20
    exit 1
fi
