"""
Mock Trustee / KBS (Key Broker Service) for the LOCAL demo only.

In production this is replaced by the real Trustee (
  https://github.com/confidential-containers/trustee
) which evaluates **hardware** evidence from AMD SEV-SNP / Intel TDX.

For the laptop demo we accept a "fake" evidence blob and apply the same
shape of policy the real Trustee would: the requester must present
  - a workload-identity token from the in-cluster ServiceAccount
  - an attestation_report whose measurements match the expected reference
We log every decision so the stakeholder demo can show the audit trail.

Endpoints
---------
GET  /healthz                            -> liveness
POST /kbs/v0/auth                        -> returns a session nonce
POST /kbs/v0/attest                      -> verify evidence, mint session JWT
POST /kbs/v0/resource/{path}             -> release secret if session is trusted
GET  /metrics                            -> Prometheus counters (slide 12 SLOs)
"""
from __future__ import annotations

import hashlib
import json
import os
import secrets
import sys
import time
from datetime import datetime, timezone
from http import HTTPStatus
from typing import Dict

from flask import Flask, jsonify, request, Response

LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8080"))
# In a real Trustee these come from KMS/Vault. For the demo we keep them in env.
RELEASEABLE_SECRETS: Dict[str, str] = {
    "default/bank-db-key/v1": os.environ.get(
        "BANK_DB_KEY", "TRUSTEE-RELEASED-db-key-only-in-CVM-memory"
    ),
}
# Reference measurements that the real attester would compare evidence against.
EXPECTED_MEASUREMENT = os.environ.get(
    "EXPECTED_MEASUREMENT",
    hashlib.sha256(b"bank-api:clean@reference").hexdigest(),
)

app = Flask(__name__)
_sessions: Dict[str, dict] = {}

# Prometheus-style counters used in the Grafana SLO dashboard.
_metrics = {
    "trustee_attest_total": 0,
    "trustee_attest_success_total": 0,
    "trustee_attest_failure_total": 0,
    "trustee_secret_released_total": 0,
    "trustee_secret_denied_total": 0,
}


def _log(level: str, msg: str, **fields) -> None:
    record = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "level": level,
        "component": "trustee-mock",
        "msg": msg,
        **fields,
    }
    print(json.dumps(record), file=sys.stderr, flush=True)


# ---------------------------------------------------------------------------
# Health & metrics
# ---------------------------------------------------------------------------
@app.get("/healthz")
def healthz():
    return jsonify({"status": "ok", "mock": True})


@app.get("/metrics")
def metrics():
    lines = [
        "# HELP trustee_attest_total Total attestation requests received.",
        "# TYPE trustee_attest_total counter",
        f"trustee_attest_total {_metrics['trustee_attest_total']}",
        "# HELP trustee_attest_success_total Successful attestations.",
        "# TYPE trustee_attest_success_total counter",
        f"trustee_attest_success_total {_metrics['trustee_attest_success_total']}",
        "# HELP trustee_attest_failure_total Failed attestations.",
        "# TYPE trustee_attest_failure_total counter",
        f"trustee_attest_failure_total {_metrics['trustee_attest_failure_total']}",
        "# HELP trustee_secret_released_total Secrets released to attested workloads.",
        "# TYPE trustee_secret_released_total counter",
        f"trustee_secret_released_total {_metrics['trustee_secret_released_total']}",
        "# HELP trustee_secret_denied_total Secret release attempts denied.",
        "# TYPE trustee_secret_denied_total counter",
        f"trustee_secret_denied_total {_metrics['trustee_secret_denied_total']}",
    ]
    return Response("\n".join(lines) + "\n", mimetype="text/plain; version=0.0.4")


# ---------------------------------------------------------------------------
# KBS protocol (greatly simplified for the demo)
# ---------------------------------------------------------------------------
@app.post("/kbs/v0/auth")
def auth():
    body = request.get_json(silent=True) or {}
    workload_id = body.get("workload_id", "anonymous")
    nonce = secrets.token_hex(16)
    session_id = secrets.token_hex(8)
    _sessions[session_id] = {
        "nonce": nonce,
        "workload_id": workload_id,
        "trusted": False,
        "issued": time.time(),
    }
    _log("info", "auth nonce issued", session=session_id, workload=workload_id)
    return jsonify({"session_id": session_id, "nonce": nonce})


@app.post("/kbs/v0/attest")
def attest():
    body = request.get_json(silent=True) or {}
    session_id = body.get("session_id", "")
    evidence = body.get("evidence", {}) or {}
    _metrics["trustee_attest_total"] += 1

    if session_id not in _sessions:
        _metrics["trustee_attest_failure_total"] += 1
        _log("warn", "unknown session", session=session_id)
        return jsonify({"trusted": False, "reason": "unknown session"}), HTTPStatus.UNAUTHORIZED

    session = _sessions[session_id]
    # The real Trustee verifies the SEV-SNP report signature here. We compare a
    # caller-supplied measurement against EXPECTED_MEASUREMENT to keep the
    # demo honest (changing the image changes the measurement -> denial).
    presented = evidence.get("measurement", "")
    tee_type = evidence.get("tee_type", "unknown")
    if presented != EXPECTED_MEASUREMENT:
        _metrics["trustee_attest_failure_total"] += 1
        _log("warn", "measurement mismatch", session=session_id,
             presented=presented[:12], expected=EXPECTED_MEASUREMENT[:12])
        return jsonify({"trusted": False, "reason": "measurement mismatch"}), HTTPStatus.FORBIDDEN

    session["trusted"] = True
    session["tee_type"] = tee_type
    _metrics["trustee_attest_success_total"] += 1
    _log("info", "attestation success", session=session_id, tee_type=tee_type)
    return jsonify({
        "trusted": True,
        "tee_type": tee_type,
        "session_id": session_id,
        "policy_evaluated": "mock-rego-policy@v1",
    })


@app.post("/kbs/v0/resource/<path:resource_path>")
def release_resource(resource_path: str):
    session_id = request.headers.get("X-Session-Id", "")
    session = _sessions.get(session_id)
    if not session or not session.get("trusted"):
        _metrics["trustee_secret_denied_total"] += 1
        _log("warn", "secret release denied (untrusted)",
             session=session_id, resource=resource_path)
        return jsonify({"error": "untrusted session"}), HTTPStatus.FORBIDDEN

    if resource_path not in RELEASEABLE_SECRETS:
        _metrics["trustee_secret_denied_total"] += 1
        _log("warn", "unknown resource", session=session_id, resource=resource_path)
        return jsonify({"error": "unknown resource"}), HTTPStatus.NOT_FOUND

    _metrics["trustee_secret_released_total"] += 1
    _log("info", "secret released", session=session_id, resource=resource_path)
    return jsonify({
        "resource_id": resource_path,
        "value": RELEASEABLE_SECRETS[resource_path],
        "released_at": datetime.now(timezone.utc).isoformat(),
    })


if __name__ == "__main__":
    _log("info", f"trustee-mock starting on :{LISTEN_PORT}",
         expected_measurement_prefix=EXPECTED_MEASUREMENT[:12])
    app.run(host="0.0.0.0", port=LISTEN_PORT)
