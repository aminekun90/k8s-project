# Kubernetes Home Project

This project deploys a **Pi-hole + Unbound DNS** stack and an **Adhan API** on a Kubernetes cluster using **Helm charts**. It includes network services and persistent volumes, designed to run on a local Raspberry Pi cluster.

---

## Project Structure

```bash
.
├── helm-charts
│   ├── adhan
│   │   ├── Chart.yaml
│   │   ├── templates
│   │   │   ├── adhan-service.yaml
│   │   │   └── deployment.yaml
│   │   └── values.yaml
│   └── pihole
│       ├── Chart.yaml
│       ├── templates
│       │   ├── _helpers.tpl
│       │   ├── pihole-deployment.yaml
│       │   ├── pihole-pvc.yaml
│       │   ├── pihole-secret.yaml
│       │   ├── pihole-service.yaml
│       │   ├── unbound-configmap.yaml
│       │   ├── unbound-deployment.yaml
│       │   └── unbound-service.yaml
│       └── values.yaml
├── metallb-pool.yaml
├── namespaces
│   ├── adhan-namespace.yaml
│   └── pihole-namespace.yaml
└── pihole-ingress.yaml
```

---

## Prerequisites

* Kubernetes cluster running (tested with **k3s** on Raspberry Pi)
* Helm 3.x
* kubectl configured to access your cluster
* Optional: k9s for monitoring
* `scp` or other file transfer tool (for copying Adhan data)

---

## Step 1: Install MetalLB

```bash
kubectl apply -f metallb-pool.yaml
```

Make sure MetalLB assigns IPs in your local network range.

---

## Step 2: Create Namespaces

```bash
kubectl apply -f namespaces/pihole-namespace.yaml
kubectl apply -f namespaces/adhan-namespace.yaml
```

---

## Step 3: Deploy Pi-hole + Unbound

The admin password is stored in a Kubernetes Secret (never in git). Pick one:

```bash
# Recommended — create the Secret once; it survives every helm upgrade:
kubectl -n pihole create secret generic pihole-admin --from-literal=password='YOURPASS'
helm upgrade --install pihole helm-charts/pihole -n pihole --set existingSecret=pihole-admin

# Or let the chart create the Secret (pass the password at install time):
helm upgrade --install pihole helm-charts/pihole -n pihole --set adminPassword='YOURPASS'
```

Check pods and services:

```bash
kubectl get pods -n pihole
kubectl get svc -n pihole
```

Access Pi-hole web interface: `http://<pihole-loadbalancer-ip>/admin`

---

## Step 4: Deploy Adhan API

Make sure the `data` folder exists on the Pi and contains:

```shell
data/
├── audio/
└── cities.db
```

Copy from your Mac if needed:

```bash
scp -r backend/src/data pi@192.168.1.42:/home/pi/data
```

Deploy the Adhan API:

```bash
helm install adhan helm-charts/adhan -n adhan
```

Check pods and services:

```bash
kubectl get pods -n adhan
kubectl get svc -n adhan
```

Adhan API will be available on the assigned LoadBalancer IP (or hostNetwork IP) port 8000. Swagger docs: `http://<adhan-loadbalancer-ip>:8000/docs#/`

---

## Step 5: Access from Your Mac

Copy `k3s` kubeconfig from Pi:

```bash
scp pi@192.168.1.42:/etc/rancher/k3s/k3s.yaml ~/k3s-rpi.yaml
```

Edit `~/k3s-rpi.yaml` to replace:

```yaml
server: https://127.0.0.1:6443
```

with

```yaml
server: https://192.168.1.42:6443
```

Set kubeconfig environment variable:

```bash
export KUBECONFIG=~/k3s-rpi.yaml
kubectl get nodes
```

Use **k9s**:

```bash
KUBECONFIG=~/k3s-rpi.yaml k9s
```

Monitor Pi-hole, Unbound, and Adhan API pods in real-time.

---

## Step 6: Update / Restart Helm Charts

To upgrade Pi-hole or Adhan:

```bash
helm upgrade pihole helm-charts/pihole -n pihole
helm upgrade adhan helm-charts/adhan -n adhan
```

---

## One-shot deploy

Everything above is wrapped in **`deploy.sh`** (idempotent — safe to re-run):

```bash
./deploy.sh                          # prompts for the Pi-hole password (first run)
PIHOLE_PASSWORD=secret ./deploy.sh   # non-interactive
FREEBOX_DNS_IP=192.168.1.42 ./deploy.sh   # also point the Freebox DHCP at Pi-hole
```

It applies the namespaces + MetalLB pool, creates/reuses the Pi-hole admin
Secret, `helm upgrade --install`s both charts, and applies the ingress.

## Make the whole LAN use Pi-hole (any ISP, worldwide)

See **[docs/dns-setup.md](docs/dns-setup.md)** — covers French ISPs (Free,
Orange, Bouygues, SFR), generic routers worldwide, and a universal **Pi-hole
DHCP** fallback for boxes that won't let you set a custom DNS.

Freebox is automated via the local API:

```bash
python3 scripts/freebox-dns.py --dns 192.168.1.42   # press the Freebox arrow once
python3 scripts/freebox-dns.py --show                # check current DHCP DNS
python3 scripts/freebox-dns.py --revert              # hand DNS back to the Freebox
```

For other ISPs/routers, either set the DHCP DNS in the box UI, or enable
Pi-hole's own DHCP server:

```bash
helm upgrade --install pihole helm-charts/pihole -n pihole \
  --set existingSecret=pihole-admin --set dhcp.enabled=true \
  --set dhcp.router=192.168.1.254   # disable the router's DHCP first
```

---

## Notes

* Pi-hole uses **LoadBalancer IPs** (configure MetalLB accordingly)
* Pi-hole admin password lives in a **Secret** — set it once via `deploy.sh` or
  `kubectl create secret generic pihole-admin --from-literal=password=…`
* Adhan API requires a **data folder** on the Pi (`audio` + `cities.db`)
* HostNetwork lets the Adhan API discover Sonos/Freebox and play on the Pi's
  own speakers (`audio.enabled` mounts `/dev/snd`)
* Use **k9s** or `kubectl logs` to debug pods
