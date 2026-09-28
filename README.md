# Zero-Trust GitOps: Attested Deployments with Argo CD and Confidential Containers

## Overview

This project presents a **Zero-Trust GitOps approach for attested application deployments**, integrating **Argo CD** with **Confidential Containers (CoCo)**.

The proposed architecture enables deployment workflows where workloads can be verified based on their **attestation evidence and trusted execution environment** before being considered eligible for deployment.

The work explores how GitOps principles can be extended beyond configuration and deployment integrity to include **workload trust and attestation-based verification**.

## Key Concepts

- **GitOps-based deployment** using Argo CD
- **Zero-Trust deployment model**
- **Confidential Containers (CoCo)**
- **Workload attestation**
- **Attestation-based trust verification**
- **Policy-driven deployment decisions**
- Secure deployment of workloads into confidential computing environments

## Architecture

The solution explores an architecture where:

1. Application manifests are maintained in a Git repository.
2. Argo CD continuously reconciles the desired state with the Kubernetes cluster.
3. Before or during deployment, the workload environment can be verified through attestation.
4. Attestation evidence is evaluated against the defined trust requirements.
5. Only workloads satisfying the required trust conditions are permitted to proceed.

> **Note:** The detailed architecture, implementation workflow, and evaluation results will be described in the associated publication.

## Implementation Status

🚧 **Research / Publication in Progress**

This repository currently contains a high-level description of the proposed approach.

The **source code, implementation details, deployment manifests, configuration, and supporting artifacts will be made available after the publication of the associated research work**.

Until publication, the repository intentionally does not include the complete implementation.

## Research Focus

The work investigates how confidential computing and remote attestation can be incorporated into a GitOps workflow to strengthen the trust model of Kubernetes application deployments.

In particular, it explores the relationship between:

**Git → GitOps → Deployment → Attestation → Trust Verification → Workload Execution**

## Technology Stack

- Kubernetes
- Argo CD
- Confidential Containers (CoCo)
- Kubernetes Operators
- GitOps
- Remote Attestation
- Confidential Computing

## Availability

The complete implementation will be released following publication of the associated research work.

Please watch this repository for updates.

## Citation

Citation information will be added after publication.

## License

License information will be provided along with the implementation release.
