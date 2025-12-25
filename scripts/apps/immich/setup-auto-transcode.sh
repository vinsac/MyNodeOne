#!/bin/bash

###############################################################################
# Immich - Automated Video Transcoding Setup
# 
# Sets up nightly automatic video transcoding for smooth playback
###############################################################################

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

NAMESPACE="immich"

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Immich Automated Video Transcoding Setup${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl not found${NC}"
    exit 1
fi

# Check if namespace exists
if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
    echo -e "${RED}Error: Immich namespace not found. Is Immich installed?${NC}"
    exit 1
fi

echo "🎬 Automated Video Transcoding"
echo ""
echo "This will set up a nightly job to automatically transcode new videos."
echo ""
echo "Benefits:"
echo "  • Videos are pre-transcoded for instant playback"
echo "  • No buffering during video viewing"
echo "  • Transcoding happens during off-peak hours"
echo "  • New uploads are automatically processed"
echo ""

# Get API key or create one
echo "🔑 Checking for API key..."
API_KEY=""

# Check if API key secret exists
if kubectl get secret immich-api-key -n "$NAMESPACE" &>/dev/null; then
    API_KEY=$(kubectl get secret immich-api-key -n "$NAMESPACE" -o jsonpath='{.data.api-key}' | base64 -d)
    echo "✓ Found existing API key"
else
    echo ""
    echo "⚠️  No API key found. You need to create one in Immich:"
    echo ""
    echo "1. Open Immich web interface"
    echo "2. Go to Account Settings → API Keys"
    echo "3. Click 'New API Key'"
    echo "4. Name it 'Auto Transcode' and copy the key"
    echo ""
    read -p "Paste your API key here: " API_KEY
    
    if [ -z "$API_KEY" ]; then
        echo -e "${RED}Error: API key cannot be empty${NC}"
        exit 1
    fi
    
    # Store API key in secret
    kubectl create secret generic immich-api-key \
        --from-literal=api-key="$API_KEY" \
        --namespace="$NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    echo "✓ API key stored securely"
fi

echo ""
echo "⏰ Schedule Configuration"
echo ""
echo "When should transcoding run?"
echo "  1) Every night at 2 AM (recommended)"
echo "  2) Every night at 3 AM"
echo "  3) Every night at 4 AM"
echo "  4) Custom schedule"
echo ""
read -p "Select option [1-4, default: 1]: " SCHEDULE_OPTION
SCHEDULE_OPTION="${SCHEDULE_OPTION:-1}"

case $SCHEDULE_OPTION in
    1)
        CRON_SCHEDULE="0 2 * * *"
        SCHEDULE_DESC="2 AM daily"
        ;;
    2)
        CRON_SCHEDULE="0 3 * * *"
        SCHEDULE_DESC="3 AM daily"
        ;;
    3)
        CRON_SCHEDULE="0 4 * * *"
        SCHEDULE_DESC="4 AM daily"
        ;;
    4)
        echo ""
        echo "Enter cron schedule (e.g., '0 2 * * *' for 2 AM daily):"
        read -p "Cron schedule: " CRON_SCHEDULE
        SCHEDULE_DESC="custom schedule"
        ;;
    *)
        CRON_SCHEDULE="0 2 * * *"
        SCHEDULE_DESC="2 AM daily"
        ;;
esac

echo ""
echo "✓ Schedule: $SCHEDULE_DESC ($CRON_SCHEDULE)"
echo ""

# Create the CronJob
echo "📦 Creating automated transcoding job..."

kubectl apply -f - <<EOF
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: immich-auto-transcode
  namespace: $NAMESPACE
spec:
  schedule: "$CRON_SCHEDULE"
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
          - name: transcode-trigger
            image: curlimages/curl:latest
            env:
            - name: API_KEY
              valueFrom:
                secretKeyRef:
                  name: immich-api-key
                  key: api-key
            - name: IMMICH_URL
              value: "http://immich-server.${NAMESPACE}.svc.cluster.local"
            command:
            - /bin/sh
            - -c
            - |
              echo "Starting automated video transcoding..."
              echo "Immich URL: \$IMMICH_URL"
              
              # Trigger video transcoding job
              RESPONSE=\$(curl -s -w "\n%{http_code}" -X POST "\${IMMICH_URL}/api/jobs" \\
                -H "Accept: application/json" \\
                -H "x-api-key: \${API_KEY}" \\
                -H "Content-Type: application/json" \\
                -d '{"command":"start","name":"videoConversion"}')
              
              HTTP_CODE=\$(echo "\$RESPONSE" | tail -n1)
              BODY=\$(echo "\$RESPONSE" | head -n-1)
              
              echo "HTTP Status: \$HTTP_CODE"
              echo "Response: \$BODY"
              
              if [ "\$HTTP_CODE" = "201" ] || [ "\$HTTP_CODE" = "200" ]; then
                echo "✓ Video transcoding job triggered successfully"
                exit 0
              else
                echo "✗ Failed to trigger transcoding job"
                exit 1
              fi
            resources:
              requests:
                memory: "64Mi"
                cpu: "100m"
              limits:
                memory: "128Mi"
                cpu: "200m"
EOF

echo "✓ CronJob created"
echo ""

# Create a manual trigger script
echo "📝 Creating manual trigger script..."

cat > /tmp/trigger-transcode.sh << 'SCRIPT_EOF'
#!/bin/bash
# Manual trigger for video transcoding

NAMESPACE="immich"
API_KEY=$(kubectl get secret immich-api-key -n "$NAMESPACE" -o jsonpath='{.data.api-key}' 2>/dev/null | base64 -d)

if [ -z "$API_KEY" ]; then
    echo "Error: API key not found"
    exit 1
fi

echo "Triggering video transcoding job..."

kubectl run immich-transcode-manual --rm -i --restart=Never \
  --image=curlimages/curl:latest \
  --namespace="$NAMESPACE" \
  --env="API_KEY=$API_KEY" \
  --env="IMMICH_URL=http://immich-server.${NAMESPACE}.svc.cluster.local" \
  -- sh -c '
    curl -X POST "${IMMICH_URL}/api/jobs" \
      -H "Accept: application/json" \
      -H "x-api-key: ${API_KEY}" \
      -H "Content-Type: application/json" \
      -d "{\"command\":\"start\",\"name\":\"videoConversion\"}"
    echo ""
    echo "✓ Transcoding job triggered"
  '
SCRIPT_EOF

chmod +x /tmp/trigger-transcode.sh
sudo cp /tmp/trigger-transcode.sh /usr/local/bin/immich-transcode
rm /tmp/trigger-transcode.sh

echo "✓ Manual trigger installed: immich-transcode"
echo ""

echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Automated Transcoding Setup Complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "📅 Schedule: $SCHEDULE_DESC"
echo ""
echo "🎬 What happens now:"
echo "  • New videos uploaded during the day"
echo "  • At $SCHEDULE_DESC, transcoding runs automatically"
echo "  • Videos are converted to H.264 for smooth playback"
echo "  • No manual intervention needed"
echo ""
echo "📝 Management Commands:"
echo ""
echo "  • Trigger transcoding now:"
echo "    sudo immich-transcode"
echo ""
echo "  • View scheduled jobs:"
echo "    kubectl get cronjobs -n $NAMESPACE"
echo ""
echo "  • View job history:"
echo "    kubectl get jobs -n $NAMESPACE"
echo ""
echo "  • View last run logs:"
echo "    kubectl logs -n $NAMESPACE -l job-name=immich-auto-transcode --tail=50"
echo ""
echo "  • Disable auto-transcoding:"
echo "    kubectl delete cronjob immich-auto-transcode -n $NAMESPACE"
echo ""
echo "  • Change schedule:"
echo "    kubectl edit cronjob immich-auto-transcode -n $NAMESPACE"
echo ""
echo "💡 Pro Tip: Run 'sudo immich-transcode' now to transcode existing videos!"
echo ""
