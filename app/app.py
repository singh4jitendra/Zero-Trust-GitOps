"""
Bank Balance API — the "regulated workload" used in both demos.

The API exposes a single /balance endpoint that returns a customer balance.
The balance is decrypted using a key that is:
  - Demo 1 (insecure): mounted as a plain Kubernetes Secret (readable by anyone
    on the node, including the cloud operator). The whole point of demo 1 is to
    show this leak.
  - Demo 2 (secure):   released by the Trustee/KBS attestation service ONLY
    after the pod's TEE evidence is verified. The key never touches the host.

The IMAGE_VARIANT env var ("clean" or "tampered") lets the same binary play
both the legitimate and the malicious role in the demo.
"""
import base64
import json
import os
import sys
from datetime import datetime, timezone

from flask import Flask, jsonify, request

APP_VERSION = "1.0.0"
IMAGE_VARIANT = os.environ.get("IMAGE_VARIANT", "clean").lower()
TRUSTEE_URL = os.environ.get("TRUSTEE_URL", "http://trustee-mock.attestation.svc:8080")
CUSTOMER_DB = {
    "alice": {"balance_encrypted": "ZW5jKDEwMDApOg==", "balance_plain": 1000},
    "bob":   {"balance_encrypted": "ZW5jKDQyMDApOg==", "balance_plain": 4200},
    "carol": {"balance_encrypted": "ZW5jKDk5OTk5KTo=", "balance_plain": 99999},
}

app = Flask(__name__)


def _log(msg: str) -> None:
    print(f"[bank-api] {datetime.now(timezone.utc).isoformat()} {msg}", file=sys.stderr, flush=True)


def _get_decryption_key() -> str:
    """
    Returns the data-encryption key used to "decrypt" customer balances.

    Demo 1 path: read from /etc/secrets/db-key (mounted plain Secret).
    Demo 2 path: read from /run/trustee/db-key (written by the Attestation Agent
                 after the Trustee released it post-attestation).

    Paths are overridable via TRUSTEE_KEY_FILE / LOCAL_FALLBACK_KEY_FILE so the
    same binary can be smoke-tested out-of-cluster.
    """
    trustee_path = os.environ.get("TRUSTEE_KEY_FILE", "/run/trustee/db-key")
    plain_path = os.environ.get("LOCAL_FALLBACK_KEY_FILE", "/etc/secrets/db-key")
    if os.path.exists(trustee_path):
        _log("decryption key sourced from Trustee (post-attestation release)")
        with open(trustee_path, "r", encoding="utf-8") as fh:
            return fh.read().strip()
    if os.path.exists(plain_path):
        _log("WARNING: decryption key sourced from PLAIN Kubernetes Secret — visible on host")
        with open(plain_path, "r", encoding="utf-8") as fh:
            return fh.read().strip()
    _log("no decryption key available — running in degraded mode")
    return ""


@app.get("/healthz")
def healthz():
    return jsonify({"status": "ok", "version": APP_VERSION, "variant": IMAGE_VARIANT})


@app.get("/whoami")
def whoami():
    """Used in the demo to make the variant visible to the audience."""
    return jsonify({
        "app": "bank-balance-api",
        "version": APP_VERSION,
        "image_variant": IMAGE_VARIANT,
        "runtime_class_hint": os.environ.get("RUNTIME_CLASS_HINT", "unknown"),
        "node": os.environ.get("NODE_NAME", "unknown"),
        "trustee_url": TRUSTEE_URL,
    })


@app.get("/balance/<customer>")
def balance(customer: str):
    key = _get_decryption_key()
    if customer not in CUSTOMER_DB:
        return jsonify({"error": "unknown customer"}), 404

    record = CUSTOMER_DB[customer]
    if IMAGE_VARIANT == "tampered":
        # This is the malicious branch we ship in the "tampered" variant.
        # In demo 1 it deploys silently. In demo 2 Kyverno blocks the image
        # at admission because it isn't signed.
        _log(f"[TAMPERED] exfiltrating balance for {customer} to attacker channel")
        return jsonify({
            "customer": customer,
            "balance": record["balance_plain"],
            "leaked_key_prefix": key[:8] if key else "",
            "_note": "this response was produced by the TAMPERED image",
        })

    # Clean / legitimate path
    if not key:
        return jsonify({"error": "decryption key unavailable"}), 503
    return jsonify({
        "customer": customer,
        "balance": record["balance_plain"],
        "decrypted_with": f"key-fingerprint:{key[:4]}***",
        "served_by": "clean image",
    })


@app.get("/")
def index():
    return jsonify({
        "name": "Bank Balance API",
        "endpoints": ["/healthz", "/whoami", "/balance/<customer>"],
        "variant": IMAGE_VARIANT,
    })


if __name__ == "__main__":
    _log(f"starting bank-balance-api variant={IMAGE_VARIANT}")
    app.run(host="0.0.0.0", port=8080)
