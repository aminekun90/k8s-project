# HTTPS de l'API sur le LAN — `qibla-api.duckdns.org`

Mis en place le 2026-10-09. L'app iOS en Release n'accepte que du HTTPS vers un hôte
qu'elle a en liste blanche ; `aladhan.home` ne peut porter aucun certificat reconnu
par un iPhone. Ce nom-ci le peut, sans rien exposer sur internet et à 0 €.

| Pièce | Où | Rôle |
|-|-|-|
| Nom DuckDNS | duckdns.org, compte aminekun90@github | `qibla-api.duckdns.org`, enregistrement public **127.0.0.1** |
| Certificat | Traefik, résolveur `duckdns` | Let's Encrypt en **DNS-01** : un TXT, aucune connexion entrante, aucun port ouvert |
| Stockage | PVC `kube-system/traefik` (local-path) | `acme.json` survit aux redémarrages de k3s |
| Jeton | Secret `kube-system/duckdns-token`, clé `token` | jamais dans git |
| Route | chart adhan, `ingress.secureHost` | Ingress `adhan-api-https` en websecure |
| DNS du LAN | chart pihole, `localApps` | le nom → 192.168.1.42 |

Hors du domicile, le nom répond 127.0.0.1 : l'app échoue aussitôt contre son propre
loopback et reste sur Mawaqit.

## Vérifier

```bash
curl -sS https://qibla-api.duckdns.org/api/v1/health            # depuis le LAN
echo | openssl s_client -connect 192.168.1.42:443 -servername qibla-api.duckdns.org 2>/dev/null \
  | openssl x509 -noout -issuer -enddate                          # Let's Encrypt, échéance
kubectl -n kube-system logs deploy/traefik | grep -i acme
```

## Opérer

- **Traefik** : `clusters/pi/traefik-helmchartconfig.yaml` est **hors Argo CD** —
  `kubectl apply -f` à la main, k3s redéploie Traefik
- **Régénérer le jeton DuckDNS** : bouton sur duckdns.org, puis
  `kubectl -n kube-system create secret generic duckdns-token --from-literal=token=… --dry-run=client -o yaml | kubectl apply -f -`
  et `kubectl -n kube-system rollout restart deploy/traefik`
- **Changer l'IP publique du nom** : `curl "https://www.duckdns.org/update?domains=qibla-api&token=…&ip=127.0.0.1"`
- **Pi-hole** est installé par Helm, **pas** par Argo :
  `helm upgrade pihole charts/pihole -n pihole --set existingSecret=pihole-admin`

## Pièges

- **`--reuse-values` ignore les nouvelles valeurs par défaut du chart** : une entrée
  ajoutée à `localApps` n'est pas déployée. Passer les valeurs explicitement
- **La conf DNS locale est montée en `subPath`** : Kubernetes ne la rafraîchit jamais
  dans un pod vivant. Après tout changement de `localApps`,
  `kubectl -n pihole rollout restart deploy/pihole` — environ 30 s sans DNS sur le LAN
- **Les appareils du LAN interrogent d'abord le DNS IPv6 de la Freebox**, pas le
  Pi-hole : ils obtiennent la réponse publique (127.0.0.1) et manquent la Pi. Vérifier
  avec `scutil --dns` sur un Mac. Le résolveur de Free ne filtre pas les IP privées
- Le renouvellement passe par les résolveurs publics (1.1.1.1, 9.9.9.9), pas par le
  Pi-hole qui surcharge ce nom
