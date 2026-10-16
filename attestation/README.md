# Attestation — Trustee / KBS mock

This directory contains a **mock** of the
[Confidential Containers Trustee/KBS](https://github.com/confidential-containers/trustee)
used **only for the local kind demo**.

## Why a mock?

The real Trustee verifies AMD SEV-SNP / Intel TDX hardware reports. A laptop
without those CPUs cannot produce real evidence. Rather than skip the
attestation step (which would make the demo dishonest), we ship a tiny
Flask service that:

1. Implements the **same protocol surface** the real Trustee exposes
   (`/kbs/v0/auth`, `/kbs/v0/attest`, `/kbs/v0/resource/...`).
2. **Actually evaluates a policy** (`policy.rego`) — change the image, the
   measurement changes, the policy denies, and the secret is **not**
   released. The audience sees this happen live.
3. Emits **Prometheus metrics** matching the deck's SLO panel:
   `trustee_attest_total`, `trustee_attest_success_total`,
   `trustee_secret_released_total`.

Every log line and HTTP response carries `"mock": true` so nobody can mistake
the local demo for real hardware attestation.

## On AKS Confidential Containers

Swap the deployment manifest in `infra/azure/05b-install-trustee.sh` to deploy
the real Trustee Helm chart instead — the bank-api manifests do not change.
That's the whole point: the workload is unaware of whether attestation is
mocked or real.
