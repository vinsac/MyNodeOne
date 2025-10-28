#!/bin/bash

# Quick Access Script for MyNodeOne Services
# Run this to access services from your laptop via port-forward

echo "🚀 Starting port forwards to MyNodeOne services..."
echo "Press Ctrl+C to stop all forwards"
echo ""
echo "Services will be available at:"
echo "  • Grafana:    http://localhost:3000"
echo "  • ArgoCD:     http://localhost:8080"
echo "  • MinIO:      http://localhost:9001"
echo "  • Open WebUI: http://localhost:8081"
echo ""

# Run all port forwards in background
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80 &
PF1=$!

kubectl port-forward -n argocd svc/argocd-server 8080:443 &
PF2=$!

kubectl port-forward -n minio svc/minio-console 9001:9001 &
PF3=$!

kubectl port-forward -n llm-chat svc/open-webui 8081:80 &
PF4=$!

echo "✅ Port forwards started!"
echo ""
echo "Open in your browser:"
echo "  • http://localhost:3000 (Grafana)"
echo "  • https://localhost:8080 (ArgoCD - accept self-signed cert)"
echo "  • http://localhost:9001 (MinIO)"
echo "  • http://localhost:8081 (Open WebUI)"
echo ""

# Wait for Ctrl+C
trap "kill $PF1 $PF2 $PF3 $PF4 2>/dev/null; echo 'Port forwards stopped'; exit" INT
wait
