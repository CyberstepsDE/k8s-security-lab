#!/usr/bin/env bash
# Kubernetes Security Lab - full environment setup.
# Tested on: minikube v1.37.0, Docker driver, macOS arm64, kubectl v1.35.
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Starting minikube with Calico CNI (needed so NetworkPolicy is actually enforced)"
minikube start --cni=calico --cpus=4 --memory=6000

echo "==> Building the vulnerable app image directly into minikube's Docker daemon"
eval "$(minikube docker-env)"
docker build -t k8s-security-lab/vulnerable-app:latest ./app

echo "==> [01] Deploying the vulnerable app (this is the lab's entry point)"
kubectl apply -f manifests/01-vulnerable-app/rbac.yaml
kubectl apply -f manifests/01-vulnerable-app/deployment.yaml
kubectl rollout status deployment/cluster-health-dashboard -n default --timeout=90s

echo "==> [02] RBAC can-i demo: namespace + service account + allow role"
kubectl create namespace demo --dry-run=client -o yaml | kubectl apply -f -
kubectl create serviceaccount demo-sa -n demo --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f manifests/02-rbac-can-i/role-allow.yaml
kubectl apply -f manifests/02-rbac-can-i/rolebinding-allow.yaml

echo "==> [03] RBAC pop-quiz live: victim secret + vulnerable ClusterRole"
kubectl apply -f manifests/03-rbac-popquiz-live/victim-secret.yaml
kubectl apply -f manifests/03-rbac-popquiz-live/vulnerable-clusterrole.yaml

echo "==> [04] NetworkPolicy demo: tenant-1 and tenant-2 nginx apps"
kubectl apply -f manifests/04-network-policy/tenant-1.yaml
kubectl apply -f manifests/04-network-policy/tenant-2.yaml
kubectl -n tenant-1 rollout status deployment/nginx --timeout=90s
kubectl -n tenant-2 rollout status deployment/nginx --timeout=90s

echo "==> [05] Metadata demo: local Azure IMDS simulation"
kubectl apply -f manifests/05-metadata/mock-azure-imds.yaml
kubectl rollout status deployment/mock-azure-imds -n default --timeout=60s

echo "==> [06] Pod Security demo: restricted vs. privileged pod"
kubectl apply -f manifests/06-pod-security/restricted-pod.yaml
kubectl apply -f manifests/06-pod-security/privileged-pod.yaml
kubectl wait --for=condition=Ready pod/restricted-pod pod/dangerous-pod -n default --timeout=60s

echo
echo "==> Environment ready. Port-forward the vulnerable app to start the attack walkthrough:"
echo "      kubectl port-forward svc/cluster-health-dashboard 5000:5000 -n default"
echo "      open http://localhost:5000"
echo
echo "==> Run ./teardown.sh when the session is done."
