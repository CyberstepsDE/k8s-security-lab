# Kubernetes Security Lab - full environment setup for Windows (PowerShell).
# Same steps as setup.sh. Run from the repo folder:
#   powershell -ExecutionPolicy Bypass -File .\setup.ps1
# Needs: Docker Desktop running, minikube and kubectl on PATH.

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

# Run a native command and stop the script if it fails.
function Invoke-Step {
    param([Parameter(Mandatory)][string]$Exe, [Parameter(ValueFromRemainingArguments)][string[]]$Rest)
    & $Exe @Rest
    if ($LASTEXITCODE -ne 0) { throw "Failed: $Exe $($Rest -join ' ')" }
}

# Create a namespaced object idempotently (kubectl create ... --dry-run | kubectl apply).
function Invoke-Ensure {
    param([Parameter(ValueFromRemainingArguments)][string[]]$CreateArgs)
    $yaml = & kubectl create @CreateArgs --dry-run=client -o yaml
    if ($LASTEXITCODE -ne 0) { throw "Failed: kubectl create $($CreateArgs -join ' ')" }
    $yaml | & kubectl apply -f -
    if ($LASTEXITCODE -ne 0) { throw "Failed: kubectl apply for $($CreateArgs -join ' ')" }
}

Write-Host '==> Starting minikube with Calico CNI (needed so NetworkPolicy is actually enforced)'
Invoke-Step minikube start --driver=docker --cni=calico --cpus=4 --memory=3072

Write-Host '==> Building the vulnerable app image for Minikube'
Invoke-Step minikube image build -t k8s-security-lab/vulnerable-app:latest ./app

Write-Host "==> [01] Deploying the vulnerable app (this is the lab's entry point)"
Invoke-Step kubectl apply -f manifests/01-vulnerable-app/rbac.yaml
Invoke-Step kubectl apply -f manifests/01-vulnerable-app/deployment.yaml
Invoke-Step kubectl rollout status deployment/cluster-health-dashboard -n default --timeout=90s

Write-Host '==> [02] RBAC can-i demo: namespace + service account + allow role'
Invoke-Ensure namespace demo
Invoke-Ensure serviceaccount demo-sa -n demo
Invoke-Step kubectl apply -f manifests/02-rbac-can-i/role-allow.yaml
Invoke-Step kubectl apply -f manifests/02-rbac-can-i/rolebinding-allow.yaml

Write-Host '==> [03] RBAC pop-quiz live: victim secret + vulnerable ClusterRole'
Invoke-Step kubectl apply -f manifests/03-rbac-popquiz-live/victim-secret.yaml
Invoke-Step kubectl apply -f manifests/03-rbac-popquiz-live/vulnerable-clusterrole.yaml

Write-Host '==> [04] NetworkPolicy demo: tenant-1 and tenant-2 nginx apps'
Invoke-Step kubectl apply -f manifests/04-network-policy/tenant-1.yaml
Invoke-Step kubectl apply -f manifests/04-network-policy/tenant-2.yaml
Invoke-Step kubectl -n tenant-1 rollout status deployment/nginx --timeout=90s
Invoke-Step kubectl -n tenant-2 rollout status deployment/nginx --timeout=90s

Write-Host '==> [05] Metadata demo: local Azure IMDS simulation'
Invoke-Step kubectl apply -f manifests/05-metadata/mock-azure-imds.yaml
Invoke-Step kubectl rollout status deployment/mock-azure-imds -n default --timeout=60s

Write-Host '==> [06] Pod Security demo: restricted vs. privileged pod'
Invoke-Step kubectl apply -f manifests/06-pod-security/restricted-pod.yaml
Invoke-Step kubectl apply -f manifests/06-pod-security/privileged-pod.yaml
Invoke-Step kubectl wait --for=condition=Ready pod/restricted-pod pod/dangerous-pod -n default --timeout=60s

Write-Host ''
Write-Host '==> Environment ready. Port-forward the vulnerable app to start the attack walkthrough:'
Write-Host '      kubectl port-forward svc/cluster-health-dashboard 5000:5000 -n default'
Write-Host '      then open http://localhost:5000 in your browser'
Write-Host ''
Write-Host '==> Run .\teardown.ps1 when the session is done.'
