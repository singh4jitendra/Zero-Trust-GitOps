#!/usr/bin/env bash
# Verify the toolchain before a stakeholder demo.
set -Eeuo pipefail

green() { printf "\033[0;32m✓\033[0m %s\n" "$1"; }
red()   { printf "\033[0;31m✗\033[0m %s\n" "$1"; }

check() {
  local name=$1 cmd=$2
  if command -v "$cmd" >/dev/null 2>&1; then
    green "$name ($($cmd --version 2>&1 | head -n1 | tr -d '\r'))"
  else
    red "$name — install before running the demo"
    MISSING=1
  fi
}

echo "== Prerequisite check =="
MISSING=0
check "docker"  docker
check "kind"    kind
check "kubectl" kubectl
check "helm"    helm
check "cosign"  cosign
check "jq"      jq
check "curl"    curl

if [[ "${MISSING:-0}" -eq 1 ]]; then
  echo
  echo "Install the missing tools then re-run this script."
  exit 1
fi
echo
green "All prerequisites present."
