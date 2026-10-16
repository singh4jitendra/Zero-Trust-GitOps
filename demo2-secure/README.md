# Demo 2 — Secure GitOps (the **Trust Gap closed**)

> Maps to slide 10 of the deck (*Secure GitOps Architecture*).

## What this demo proves

The same Argo CD pipeline now:

1. **Refuses** to deploy the tampered image because it isn't signed by the
   expected Cosign identity (slide 6 — Sigstore).
2. Deploys the **signed** image only into a pod that uses `RuntimeClass: kata-cc`
   on an **AKS Confidential Container** node pool backed by an **Azure Confidential
   VM** (AMD SEV-SNP) — slide 7 / 8.
3. **Withholds the database key** until the **Trustee/KBS attestation service**
   has cryptographically verified that the pod is actually running inside a
   genuine TEE measuring the expected image — slide 10 step 4 + 5.
4. Emits **trust signals** (`attestation_success_total`, `image_signature_mismatch_total`)
   that drive the SLO panel — slide 12.

## The 5 pillars of slide 5, realized

| Pillar (slide 5) | Implementation |
|---|---|
| **Software Signing** | `cosign sign --yes ghcr.io/...@sha256:...` in GitHub Actions OIDC (keyless). |
| **Hardware Isolation** | `RuntimeClass: kata-cc` + AKS CoCo node pool → AMD SEV-SNP CVM. |
| **GitOps Orchestration** | Argo CD `Application` syncs only this folder. |
| **Operational Trust** | Prometheus scrapes Trustee + Kyverno → Grafana SLOs. |
| **Speed and Trust** | Whole flow takes <60s end-to-end; no manual approval. |

## Files

- [k8s/runtime-class.yaml](k8s/runtime-class.yaml) — `RuntimeClass: kata-cc`.
- [k8s/deployment.yaml](k8s/deployment.yaml) — clean signed image, no plain Secret, requests attestation init-container.
- [k8s/secret-from-trustee.yaml](k8s/secret-from-trustee.yaml) — empty `Secret` written into by the attestation agent.
- [k8s/service.yaml](k8s/service.yaml)
- [argocd-application.yaml](argocd-application.yaml)

## Run

```bash
# Scenario A: attacker pushes the tampered image
./scripts/20-demo2-secure-blocked.sh
# -> Kyverno denies admission:
#    "image bank-api:tampered failed signature verification"

# Scenario B: real CI pushes the signed image
./scripts/21-demo2-secure-allowed.sh
# -> Admitted, attested, secret released, /balance works
```
