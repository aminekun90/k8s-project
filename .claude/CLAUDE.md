# k8s-project — Claude Context

## Project Overview
Kubernetes infrastructure configuration (IaC) for a Raspberry Pi k3s home cluster. Deploys Pi-hole (DNS ad-blocker) + Unbound (recursive DNS resolver) and the Adhan API prayer times service.

## Project Structure
```
k8s-project/
├── helm-charts/
│   ├── adhan/          # Adhan API Helm chart
│   └── pihole/         # Pi-hole + Unbound chart
├── namespaces/         # Namespace manifests
├── metallb-pool.yaml   # MetalLB IP pool config
└── pihole-ingress.yaml # Ingress for Pi-hole UI
```

## Tech Stack
- **Orchestration:** k3s (lightweight Kubernetes for ARM)
- **Package manager:** Helm v3
- **Load balancer:** MetalLB (bare-metal LB)
- **DNS:** Pi-hole + Unbound
- **Target hardware:** Raspberry Pi (ARM64/ARMv7)

## Commands
```bash
# Apply a Helm chart
helm upgrade --install adhan ./helm-charts/adhan -n adhan

# Apply raw manifests
kubectl apply -f namespaces/
kubectl apply -f metallb-pool.yaml
kubectl apply -f pihole-ingress.yaml

# Check status
kubectl get pods -A
kubectl get svc -A

# Helm status
helm list -A
helm status adhan -n adhan

# Debug a pod
kubectl logs -n adhan deploy/adhan -f
kubectl describe pod -n adhan <pod-name>

# Rollback
helm rollback adhan -n adhan
```

## Conventions
- **Helm charts for services** — never deploy apps via raw manifests, use Helm for versioning
- **Namespaces per app** — each service gets its own namespace (see `namespaces/`)
- **MetalLB for external IPs** — LoadBalancer services get IPs from the `metallb-pool.yaml` range
- **ARM compatibility** — always verify Docker images support `linux/arm64` or `linux/arm/v7`
- **`values.yaml` for config** — never hardcode env vars directly in deployment templates
- **Secrets** — use Kubernetes Secrets, never embed credentials in `values.yaml`
- **Resource limits** — always set `resources.requests` and `resources.limits` (RPi has limited RAM)

## Helm Chart Structure (adhan)
```
helm-charts/adhan/
├── Chart.yaml       # Chart metadata (version: 0.1.0)
├── values.yaml      # Default values
└── templates/       # K8s manifest templates
```

## Key Considerations for Raspberry Pi
- Pi-hole DNS must bind to port 53 UDP/TCP — verify no conflicts with systemd-resolved
- Unbound as upstream DNS resolver avoids relying on external DNS providers
- Adhan API container must be built for `linux/arm64` — use multi-arch builds
- Limit memory for pods: Pi has 4-8GB RAM shared across all services

## Troubleshooting
```bash
# DNS not resolving
kubectl rollout restart deploy/pihole -n pihole

# Adhan API not reachable
kubectl logs -n adhan deploy/adhan --tail=50

# MetalLB not assigning IP
kubectl describe svc <service> -n <ns>
kubectl logs -n metallb-system deploy/controller
```
