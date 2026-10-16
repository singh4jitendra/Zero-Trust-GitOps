# Demo 1 — Insecure GitOps (the **Trust Gap** in action)

> Maps to slide 4 of the deck (*The Trust Gap in GitOps*).

## What this demo proves

A traditional GitOps pipeline only verifies that the **Git commit** is authentic.
It says **nothing** about whether the **container image** referenced in the manifest
is the one the developer intended — and it says **nothing** about who can read
the pod's memory while it's running.

Stakeholder pitch in one sentence:

> *"Argo CD will happily deploy a malicious image as long as somebody pushes
>  the manifest that points at it — and once it's running, the cloud operator
>  can read every secret it touches."*

## Pieces of the trust gap shown here

| Trust gap (slide 4) | How this demo shows it |
|---|---|
| **Deployment ≠ Trust** | Argo CD reports `Synced / Healthy` for a tampered image. |
| **Signed malware** | The image carries no signature, but the cluster doesn't care. |
| **CI compromise** | We simulate it by pushing the `:tampered` tag — no policy stops it. |
| **Runtime attacks** | The DB key is mounted as a plain `Secret`; we `kubectl exec` into the node-shared filesystem and read it. |

## Files

- [k8s/deployment.yaml](k8s/deployment.yaml) — pulls `bank-api:tampered`, runs as **regular runc**.
- [k8s/service.yaml](k8s/service.yaml)
- [k8s/secret.yaml](k8s/secret.yaml) — plaintext DB key in a base64 K8s `Secret`.
- [argocd-application.yaml](argocd-application.yaml) — Argo CD `Application` syncing this folder.

## Run

```bash
# from poc/
./scripts/10-demo1-insecure.sh
```

Then in the script's output:

```
1. kubectl get application bank-api-insecure -n argocd
   -> SYNCED / HEALTHY                  # GitOps is "green"

2. curl localhost:8080/whoami
   -> {"image_variant": "tampered", ...} # but we are running malware

3. curl localhost:8080/balance/alice
   -> {"leaked_key_prefix": "s3cr3tDB", ...} # secret has leaked

4. kubectl exec demo-attacker -- cat /host-secrets/db-key
   -> s3cr3tDBkey...                    # cloud operator can read it too
```

The audience sees **green dashboards + active attack** simultaneously — exactly the
"Trust Gap" headline on slide 4.
