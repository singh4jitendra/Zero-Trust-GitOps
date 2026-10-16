# Rego policy that the *real* Trustee evaluates. We keep it here so the
# stakeholder demo can show "this is the policy that decides whether the
# DB key is released" — independent of the mock implementation.
package trustee.release

default allow := false

# Allowed only when:
#   - evidence proves the workload is running in a genuine TEE,
#   - the launch measurement matches a known-good image, and
#   - the requested resource is one the workload is entitled to.
allow if {
    valid_tee
    valid_measurement
    valid_resource
}

valid_tee if {
    input.evidence.tee_type == "snp"   # AMD SEV-SNP
    input.evidence.signature_valid == true
}

valid_measurement if {
    input.evidence.measurement == data.reference_values.bank_api_clean
}

valid_resource if {
    input.request.resource == "default/bank-db-key/v1"
    input.request.workload_namespace == "bank-secure"
}

decision := {
    "allow": allow,
    "reason": reason,
}

reason := "ok" if allow
reason := "tee_invalid" if not valid_tee
reason := "measurement_mismatch" if valid_tee
                                  if not valid_measurement
reason := "unauthorized_resource" if valid_tee
                                  if valid_measurement
                                  if not valid_resource
