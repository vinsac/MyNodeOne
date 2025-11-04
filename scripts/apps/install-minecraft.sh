#!/bin/bash

###############################################################################
# Minecraft Server - One-Click Installation
# 
# Host your own Minecraft server
# Play with friends on your personal cloud
###############################################################################

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load shared validation library
source "$SCRIPT_DIR/lib/validation.sh"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Installing Minecraft Server${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

NAMESPACE="minecraft"

# Validate prerequisites
validate_prerequisites
warn_if_namespace_exists "$NAMESPACE"

echo "📦 Creating namespace..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "💾 Configuring storage..."
kubectl apply -f - <<EOF
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minecraft-data
  namespace: $NAMESPACE
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 10Gi
EOF

echo "🎮 Deploying Minecraft Server..."
kubectl apply -f - <<EOF
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minecraft
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: minecraft
  template:
    metadata:
      labels:
        app: minecraft
    spec:
      containers:
      - name: minecraft
        image: itzg/minecraft-server:latest
        ports:
        - containerPort: 25565
        env:
        - name: EULA
          value: "TRUE"
        - name: TYPE
          value: "PAPER"
        - name: VERSION
          value: "LATEST"
        - name: MEMORY
          value: "2G"
        - name: DIFFICULTY
          value: "normal"
        - name: OPS
          value: "your_minecraft_username"
        volumeMounts:
        - name: data
          mountPath: /data
        resources:
          requests:
            memory: "2Gi"
            cpu: "1000m"
          limits:
            memory: "4Gi"
            cpu: "2000m"
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: minecraft-data
---
apiVersion: v1
kind: Service
metadata:
  name: minecraft
  namespace: $NAMESPACE
spec:
  type: LoadBalancer
  ports:
  - port: 25565
    targetPort: 25565
    protocol: TCP
  selector:
    app: minecraft
EOF

echo "⏳ Waiting for Minecraft server to start (may take 2-3 minutes)..."
kubectl wait --for=condition=available --timeout=300s deployment/minecraft -n "$NAMESPACE"

sleep 20
SERVICE_IP=$(kubectl get svc minecraft -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ✓ Minecraft server installed successfully!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "🎮 Connect to your server:"
echo "   Server Address: $SERVICE_IP:25565"
echo ""
echo "💡 How to connect:"
echo "   1. Open Minecraft (Java Edition)"
echo "   2. Go to Multiplayer"
echo "   3. Add Server"
echo "   4. Enter address: $SERVICE_IP"
echo "   5. Click Done and join!"
echo ""
echo "⚙️ Server Configuration:"
echo "   • Type: Paper (optimized)"
echo "   • Version: Latest"
echo "   • Memory: 2GB (adjustable)"
echo "   • Difficulty: Normal"
echo ""
echo "🔧 Make yourself operator:"
echo "   kubectl exec -it deployment/minecraft -n $NAMESPACE -- rcon-cli op YOUR_USERNAME"
echo ""
echo "📊 Management:"
echo "   • View logs: kubectl logs -f deployment/minecraft -n $NAMESPACE"
echo "   • Console: kubectl exec -it deployment/minecraft -n $NAMESPACE -- rcon-cli"
echo "   • Restart: kubectl rollout restart deployment/minecraft -n $NAMESPACE"
echo "   • Backup: kubectl cp $NAMESPACE/minecraft-xxx:/data ./minecraft-backup"
echo ""

# Configure DNS automatically
echo "🌐 Configuring local DNS..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if bash "$SCRIPT_DIR/../configure-app-dns.sh" > /dev/null 2>&1; then
    # Load cluster domain
    CLUSTER_DOMAIN="mynodeone"
    if [ -f "$HOME/.mynodeone/config.env" ]; then
        source "$HOME/.mynodeone/config.env"
        CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-mynodeone}"
    fi
    echo ""
    echo "✓ DNS configured! Connect using:"
    echo "   minecraft.${CLUSTER_DOMAIN}.local:25565"
    echo ""
else
    echo ""
    echo "⚠️  DNS auto-configuration skipped"
    echo ""
fi
