#!/usr/bin/env bash
#
# One-shot, turnkey deploy for a k3s cluster. Pick what you want to install:
# Pi-hole + Unbound (DNS), the Adhan API, and/or the Increaser CronJob.
# Idempotent: safe to re-run. Run it on the cluster node, or from your Mac with
# KUBECONFIG pointing at the cluster.
#
# Usage:
#   ./deploy.sh                              # interactive: prompts which components
#   COMPONENTS="adhan" ./deploy.sh           # non-interactive: only the Adhan API
#   COMPONENTS="pihole adhan increaser" ...  # explicit set ("all" = everything)
#   PIHOLE_PASSWORD=secret ./deploy.sh       # non-interactive Pi-hole password
#   ADHAN_NODE=raspberrypi ./deploy.sh       # pin Adhan to a node (helm path only)
#   FREEBOX_DNS_IP=192.168.1.42 ./deploy.sh  # point the Freebox DHCP at Pi-hole
#   KEEL_ENABLED=false ./deploy.sh           # skip the Keel OTA auto-updater
#   ARGOCD_ENABLED=false ./deploy.sh         # deploy charts with helm directly (no GitOps)
#
# Prerequisites: a running Kubernetes cluster (e.g. k3s) with `kubectl` and
# `helm` on PATH. Everything else (MetalLB, Keel, Argo CD) is installed here.
#
# With Argo CD enabled (default), charts are deployed from git and kept in sync
# automatically. Adhan image updates still go through Keel approval (approve from
# the Adhan app's About dialog).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PIHOLE_NS="${PIHOLE_NS:-pihole}"
ADHAN_NS="${ADHAN_NS:-adhan}"
INCREASER_NS="${INCREASER_NS:-increaser}"
PIHOLE_SECRET="${PIHOLE_SECRET:-pihole-admin}"
ARGOCD_ENABLED="${ARGOCD_ENABLED:-true}"
KEEL_ENABLED="${KEEL_ENABLED:-true}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH"; exit 1; }; }
need kubectl
need helm

# --- Component selection -----------------------------------------------------
ALL_COMPONENTS="pihole adhan increaser"
COMPONENTS="${COMPONENTS:-}"
if [ -z "$COMPONENTS" ]; then
  if [ -t 0 ]; then
    echo "Which components do you want to install?"
    echo "  available: $ALL_COMPONENTS"
    read -rp "  components [all]: " COMPONENTS
  fi
  COMPONENTS="${COMPONENTS:-all}"
fi
[ "$COMPONENTS" = "all" ] && COMPONENTS="$ALL_COMPONENTS"
want() { case " $COMPONENTS " in *" $1 "*) return 0;; *) return 1;; esac; }

for c in $COMPONENTS; do
  case "$c" in
    pihole|adhan|increaser) ;;
    *) echo "ERROR: unknown component '$c' (valid: $ALL_COMPONENTS)"; exit 1;;
  esac
done
echo "==> Installing: $COMPONENTS"

# --- Namespaces --------------------------------------------------------------
echo "==> Namespaces"
want pihole    && kubectl apply -f namespaces/pihole-namespace.yaml
want adhan     && kubectl apply -f namespaces/adhan-namespace.yaml
if want increaser; then
  kubectl get ns "$INCREASER_NS" >/dev/null 2>&1 || kubectl create namespace "$INCREASER_NS"
fi

# --- MetalLB (only for LoadBalancer services: Pi-hole / Adhan) ---------------
if want pihole || want adhan; then
  echo "==> MetalLB"
  if ! kubectl get ns metallb-system >/dev/null 2>&1; then
    kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml
    echo "    Waiting for the MetalLB controller..."
    kubectl -n metallb-system wait --for=condition=available deploy/controller --timeout=180s || true
    kubectl -n metallb-system wait --for=condition=ready pod -l component=controller --timeout=120s || true
  fi
  # Retry the pool apply: the validating webhook can take a moment to be ready.
  for _ in 1 2 3 4 5; do kubectl apply -f metallb-pool.yaml && break || sleep 5; done
fi

# --- Pi-hole admin password Secret -------------------------------------------
if want pihole; then
  echo "==> Pi-hole admin password (Secret '$PIHOLE_SECRET')"
  if kubectl -n "$PIHOLE_NS" get secret "$PIHOLE_SECRET" >/dev/null 2>&1; then
    echo "    Secret already exists — keeping the current password."
  else
    PW="${PIHOLE_PASSWORD:-}"
    if [ -z "$PW" ]; then
      read -rsp "    Enter a Pi-hole admin password: " PW; echo
    fi
    kubectl -n "$PIHOLE_NS" create secret generic "$PIHOLE_SECRET" --from-literal=password="$PW"
    echo "    Created Secret '$PIHOLE_SECRET'."
  fi
fi

# --- Keel (OTA auto-updater for the Adhan Deployment) ------------------------
if want adhan && [ "$KEEL_ENABLED" = "true" ]; then
  echo "==> Keel (OTA auto-updater — polls Docker Hub, redeploys on new images)"
  helm repo add keel https://charts.keel.sh >/dev/null 2>&1 || true
  helm repo update keel >/dev/null
  helm upgrade --install keel keel/keel \
    --namespace keel --create-namespace \
    --set helmProvider.enabled=false \
    --set image.tag=latest
fi

# --- Deploy the selected charts ----------------------------------------------
if [ "$ARGOCD_ENABLED" = "true" ]; then
  echo "==> Argo CD (GitOps — keeps the cluster in sync with this repo)"
  if ! kubectl get deploy argocd-server -n argocd >/dev/null 2>&1; then
    kubectl get ns argocd >/dev/null 2>&1 || kubectl create namespace argocd
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
    # Serve the UI over plain HTTP so traefik (argocd.home) can reach it.
    kubectl -n argocd patch configmap argocd-cmd-params-cm --type merge \
      -p '{"data":{"server.insecure":"true"}}'
    kubectl -n argocd rollout restart deploy/argocd-server >/dev/null 2>&1 || true
  fi
  echo "    Registering selected apps (auto-sync)"
  want pihole    && kubectl apply -f argocd/apps/pihole.yaml
  want adhan     && kubectl apply -f argocd/apps/adhan.yaml
  want increaser && kubectl apply -f argocd/apps/increaser.yaml
  echo "    Argo CD UI: http://argocd.home"
  echo "    Admin password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
else
  if want pihole; then
    echo "==> Deploying Pi-hole + Unbound (helm)"
    helm upgrade --install pihole helm-charts/pihole -n "$PIHOLE_NS" --set existingSecret="$PIHOLE_SECRET"
  fi
  if want adhan; then
    echo "==> Deploying Adhan API (helm)"
    ADHAN_ARGS=()
    if [ -n "${ADHAN_NODE:-}" ]; then
      echo "    Pinning Adhan to node '$ADHAN_NODE'"
      ADHAN_ARGS+=(--set "nodeSelector.kubernetes\.io/hostname=$ADHAN_NODE")
    fi
    helm upgrade --install adhan helm-charts/adhan -n "$ADHAN_NS" ${ADHAN_ARGS[@]+"${ADHAN_ARGS[@]}"}
  fi
  if want increaser; then
    echo "==> Deploying Increaser (helm)"
    helm upgrade --install increaser helm-charts/increaser -n "$INCREASER_NS" --create-namespace
  fi
fi

# Local DNS records + traefik Ingress (pihole.home, aladhan.home, argocd.home,
# ...) come from `localApps` in the Pi-hole chart values — install Pi-hole to
# get them.

# Optional: point the Freebox Pop DHCP at Pi-hole so every device uses it.
if want pihole && [ -n "${FREEBOX_DNS_IP:-}" ]; then
  echo "==> Configuring Freebox DHCP DNS -> $FREEBOX_DNS_IP"
  need python3
  python3 scripts/freebox-dns.py --dns "$FREEBOX_DNS_IP"
fi

echo
echo "Done. Status:"
want pihole    && kubectl get pods,svc -n "$PIHOLE_NS"
want adhan     && kubectl get pods,svc -n "$ADHAN_NS"
want increaser && kubectl get pods,cronjob -n "$INCREASER_NS"
