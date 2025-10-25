#!/bin/bash

###############################################################################
# Deploy NodeZero Documentation Website
# 
# This deploys the website and documentation to your NodeZero cluster
# so users can access help via web browser
###############################################################################

set -euo pipefail

echo "Deploying NodeZero Documentation Website..."

# Create namespace
kubectl create namespace nodezero-docs --dry-run=client -o yaml | kubectl apply -f -

# Deploy nginx with documentation
kubectl apply -f - <<EOF
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-config
  namespace: nodezero-docs
data:
  nginx.conf: |
    server {
        listen 80;
        server_name _;
        root /usr/share/nginx/html;
        index index.html;
        
        location / {
            try_files \$uri \$uri/ =404;
        }
        
        location /docs/ {
            alias /usr/share/nginx/html/docs/;
        }
    }

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nodezero-docs
  namespace: nodezero-docs
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nodezero-docs
  template:
    metadata:
      labels:
        app: nodezero-docs
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
        volumeMounts:
        - name: website
          mountPath: /usr/share/nginx/html
          readOnly: true
        - name: nginx-config
          mountPath: /etc/nginx/conf.d/default.conf
          subPath: nginx.conf
        resources:
          requests:
            memory: "64Mi"
            cpu: "50m"
          limits:
            memory: "128Mi"
            cpu: "200m"
      volumes:
      - name: website
        configMap:
          name: website-content
      - name: nginx-config
        configMap:
          name: nginx-config

---
apiVersion: v1
kind: Service
metadata:
  name: nodezero-docs
  namespace: nodezero-docs
spec:
  type: LoadBalancer
  ports:
  - port: 80
    targetPort: 80
  selector:
    app: nodezero-docs
EOF

# Wait for deployment
echo "Waiting for deployment..."
kubectl wait --for=condition=available --timeout=120s deployment/nodezero-docs -n nodezero-docs

# Get service IP
SERVICE_IP=$(kubectl get svc nodezero-docs -n nodezero-docs -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

if [ -z "$SERVICE_IP" ]; then
    SERVICE_IP=$(kubectl get svc nodezero-docs -n nodezero-docs -o jsonpath='{.spec.clusterIP}')
fi

echo
echo "✓ NodeZero Documentation Website deployed successfully!"
echo
echo "Access it at: http://$SERVICE_IP"
echo
echo "If you have a domain configured, create an IngressRoute:"
echo "See: website/ingress-route-example.yaml"
echo

# Create example IngressRoute
cat > website/ingress-route-example.yaml <<'EOFINGRESS'
# Example IngressRoute for accessing documentation via domain
# Update with your domain and apply: kubectl apply -f ingress-route-example.yaml

apiVersion: traefik.containo.us/v1alpha1
kind: IngressRoute
metadata:
  name: nodezero-docs
  namespace: nodezero-docs
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`docs.yourdomain.com`)  # UPDATE THIS
      kind: Rule
      services:
        - name: nodezero-docs
          port: 80
  tls:
    certResolver: letsencrypt
EOFINGRESS

echo "Created: website/ingress-route-example.yaml"
echo
