#!/usr/bin/env bash
# DEMO 2a — The attacker tries to push the same tampered image into the
# SECURE namespace. Kyverno blocks it at admission.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
banner() { printf "\n\033[1;32m== %s ==\033[0m\n" "$*"; }
pause()  { echo; read -r -p "  ↳ press <enter> for next step ..."; }

banner "Demo 2a: attacker re-runs the same exploit against the SECURE namespace"
echo "We will TRY to deploy the tampered image into 'bank-secure', which is"
echo "guarded by the Kyverno ClusterPolicy 'verify-image-cosign'."
pause

banner "Ensure namespace + RuntimeClass exist"
kubectl create ns bank-secure --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$ROOT/demo2-secure/k8s/runtime-class.yaml" || true

banner "Construct a tampered-image manifest and attempt to apply it"
cat <<'EOF' > /tmp/bank-api-tampered-attempt.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: bank-api-attack
  namespace: bank-secure
spec:
  replicas: 1
  selector: { matchLabels: { app: bank-api-attack } }
  template:
    metadata:
      labels: { app: bank-api-attack }
    spec:
      runtimeClassName: kata-cc
      containers:
        - name: bank-api
          image: bank-api:tampered   # NOT signed by our CI identity
EOF

echo "+ kubectl apply -f /tmp/bank-api-tampered-attempt.yaml"
if kubectl apply -f /tmp/bank-api-tampered-attempt.yaml 2>&1 | tee /tmp/apply.out ; then
  if grep -q "policy.*verify-image-cosign\|signature.*verification\|denied" /tmp/apply.out; then
    echo
    echo "✅ Kyverno rejected the unsigned image at admission. The Trust Gap is closed."
  else
    echo
    echo "⚠️  Object was admitted. Check that ClusterPolicy verify-image-cosign is Enforce."
    kubectl get clusterpolicy verify-image-cosign -o yaml | grep -A2 validationFailureAction
  fi
else
  echo
  echo "✅ Kyverno rejected the unsigned image at admission. The Trust Gap is closed."
fi

echo
echo "Run ./scripts/21-demo2-secure-allowed.sh to see the LEGITIMATE flow."
