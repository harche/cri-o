package storage

import (
	"go.podman.io/image/v5/signature"
	"go.podman.io/image/v5/types"
)

// loadSignaturePolicy returns the signature policy for sys, composed with the
// system drop-in fragments (policy.json.d). When sys.SignaturePolicyPath is set
// (crio.conf signature_policy, or a per-namespace policy in signature_policy_dir),
// that file is the base policy and the system drop-ins still apply.
// PoC for OCPSTRAT-3988.
func loadSignaturePolicy(sys *types.SystemContext) (*signature.Policy, error) {
	if sys != nil && sys.SignaturePolicyPath != "" {
		return signature.NewPolicyFromFileWithDropIns(sys.SignaturePolicyPath, sys)
	}

	return signature.DefaultPolicy(sys)
}
