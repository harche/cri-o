package storage

import (
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"sync"

	"github.com/sirupsen/logrus"
	"go.podman.io/image/v5/signature"
	"go.podman.io/image/v5/types"
)

// PoC for signature policy drop-ins (policy.json.d) and per-namespace policy layering.

var (
	policyPathsMu sync.RWMutex
	// globalSignaturePolicyPath is crio.conf signature_policy ("" = system default search path).
	globalSignaturePolicyPath string
	// namespaceSignaturePolicyDir is crio.conf signature_policy_dir.
	namespaceSignaturePolicyDir string
)

// SetSignaturePolicyPaths records the configured global policy path and the
// per-namespace policy directory, so that loadSignaturePolicy can tell a
// per-namespace policy file from the global one.
func SetSignaturePolicyPaths(globalPath, namespaceDir string) {
	policyPathsMu.Lock()
	defer policyPathsMu.Unlock()
	globalSignaturePolicyPath = globalPath
	namespaceSignaturePolicyDir = namespaceDir
}

// loadSignaturePolicy returns the signature policy for sys.
//
//   - No SignaturePolicyPath: system policy.json composed with policy.json.d fragments.
//   - SignaturePolicyPath = crio.conf signature_policy: that file is the base, plus the fragments.
//   - SignaturePolicyPath = <signature_policy_dir>/<namespace>.json: the cluster layer
//     (global policy + fragments) with the namespace file layered on top
//     (see composeNamespaceLayer).
func loadSignaturePolicy(sys *types.SystemContext) (*signature.Policy, error) {
	if sys == nil || sys.SignaturePolicyPath == "" {
		return signature.DefaultPolicy(sys)
	}

	policyPathsMu.RLock()
	globalPath, nsDir := globalSignaturePolicyPath, namespaceSignaturePolicyDir
	policyPathsMu.RUnlock()

	if nsDir == "" || filepath.Dir(filepath.Clean(sys.SignaturePolicyPath)) != filepath.Clean(nsDir) {
		return signature.NewPolicyFromFileWithDropIns(sys.SignaturePolicyPath, sys)
	}

	clusterSys := *sys
	clusterSys.SignaturePolicyPath = globalPath

	cluster, err := signature.DefaultPolicy(&clusterSys)
	if err != nil {
		return nil, err
	}

	data, err := os.ReadFile(sys.SignaturePolicyPath)
	if err != nil {
		return nil, err
	}

	ns, err := signature.NewPartialPolicyFromBytes(data)
	if err != nil {
		return nil, fmt.Errorf("invalid namespace policy in %q: %w", sys.SignaturePolicyPath, err)
	}

	return composeNamespaceLayer(cluster, ns, sys.SignaturePolicyPath), nil
}

// composeNamespaceLayer layers a per-namespace policy on top of the cluster policy:
//
//   - Cluster scopes are unchanged: a namespace cannot restrict a cluster scope
//     that is more specific than its own scopes (cluster policy has priority).
//   - A namespace scope ANDs the cluster requirements of the same scope if it
//     exists, else of the nearest enclosing explicit cluster scope: a namespace
//     cannot weaken a cluster rule.
//   - Within the namespace file the most specific scope wins.
//   - The namespace default is ANDed with the cluster default, and a namespace
//     transport-wide "" scope ANDs the cluster default: a namespace can make the
//     fallback stricter (e.g. reject by default), never weaker.
func composeNamespaceLayer(cluster, ns *signature.Policy, nsName string) *signature.Policy {
	res := &signature.Policy{Default: cluster.Default, Transports: map[string]signature.PolicyTransportScopes{}}
	for t, scopes := range cluster.Transports {
		res.Transports[t] = signature.PolicyTransportScopes{}
		for s, reqs := range scopes {
			res.Transports[t][s] = reqs
		}
	}

	if ns.Default != nil {
		res.Default = append(slices.Clone(ns.Default), cluster.Default...)
	}

	for t, scopes := range ns.Transports {
		clusterScopes := cluster.Transports[t]
		if res.Transports[t] == nil {
			res.Transports[t] = signature.PolicyTransportScopes{}
		}

		for s, reqs := range scopes {
			eff := slices.Clone(reqs)
			also := ""

			switch {
			case clusterScopes[s] != nil:
				eff = append(eff, clusterScopes[s]...)
				also = t + ":" + s
			case s == "":
				eff = append(eff, cluster.Default...)
				also = "default"
			default:
				if p, ok := nearestEnclosingScope(t, s, clusterScopes); ok {
					eff = append(eff, clusterScopes[p]...)
					also = t + ":" + p
				}
			}

			res.Transports[t][s] = eff
			logrus.Debugf("Namespace policy scope %s:%s from %q, also requires cluster %q", t, s, nsName, also)
		}
	}

	return res
}

// nearestEnclosingScope returns the most specific explicit scope in scopes that encloses s.
func nearestEnclosingScope(transport, s string, scopes signature.PolicyTransportScopes) (string, bool) {
	best, found := "", false

	for c := range scopes {
		if c == "" || c == s || !signature.PolicyScopeEncloses(transport, c, s) {
			continue
		}

		if !found || len(c) > len(best) {
			best, found = c, true
		}
	}

	return best, found
}
