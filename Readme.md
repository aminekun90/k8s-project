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
│       │   ├── pihole-pvc.yaml.yaml
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

```bash
helm install pihole helm-charts/pihole -n pihole
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

## Step 7: Optional Shell Scripts

You can create `deploy.sh` to deploy everything quickly:

```bash
#!/bin/bash
set -e

echo "Creating namespaces..."
kubectl apply -f namespaces/pihole-namespace.yaml
kubectl apply -f namespaces/adhan-namespace.yaml

echo "Deploying MetalLB..."
kubectl apply -f metallb-pool.yaml

echo "Deploying Pi-hole + Unbound..."
helm upgrade --install pihole helm-charts/pihole -n pihole

echo "Deploying Adhan API..."
helm upgrade --install adhan helm-charts/adhan -n adhan

echo "Done! Use 'kubectl get pods -n <namespace>' to check status."
```

Make executable:

```bash
chmod +x deploy.sh
./deploy.sh
```

---

## Notes

* Pi-hole uses **LoadBalancer IPs** (configure MetalLB accordingly)
* Adhan API requires a **data folder** on the Pi (`audio` + `cities.db`)
* HostNetwork is used for Adhan API to access audio playback directly if needed
* Use **k9s** or `kubectl logs` to debug pods
