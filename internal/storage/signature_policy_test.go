package storage

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.podman.io/image/v5/signature"
)

func mustPolicy(t *testing.T, data string) *signature.Policy {
	t.Helper()
	p, err := signature.NewPartialPolicyFromBytes([]byte(data))
	require.NoError(t, err)

	return p
}

func reqCount(p *signature.Policy, t, s string) int { return len(p.Transports[t][s]) }

func TestComposeNamespaceLayer(t *testing.T) {
	// Cluster layer: default accept, blocked quay.io/bad, CIP quay.io/acme/app signed.
	cluster := mustPolicy(t, `{"default":[{"type":"insecureAcceptAnything"}],"transports":{"docker":{
	  "quay.io/bad":[{"type":"reject"}],
	  "quay.io/acme/app":[{"type":"sigstoreSigned","keyPath":"/k.pub"}],
	  "quay.io/allowed":[{"type":"insecureAcceptAnything"}]}}}`)
	// Namespace layer: quay.io reject (broader than the CIP), a weakening attempt under
	// the blocked registry, an ImagePolicy on an allowed registry, default reject.
	ns := mustPolicy(t, `{"default":[{"type":"reject"}],"transports":{"docker":{
	  "quay.io":[{"type":"reject"}],
	  "quay.io/bad/tool":[{"type":"insecureAcceptAnything"}],
	  "quay.io/allowed":[{"type":"sigstoreSigned","keyPath":"/n.pub"}]}}}`)

	p := composeNamespaceLayer(cluster, ns, "ns1.json")

	assert.Equal(t, 1, reqCount(p, "docker", "quay.io/acme/app"), "cluster scope untouched by the broader namespace scope")
	assert.Equal(t, 1, reqCount(p, "docker", "quay.io"), "no enclosing cluster scope")
	assert.Equal(t, 2, reqCount(p, "docker", "quay.io/bad/tool"), "namespace scope ANDs the enclosing cluster reject")
	assert.Equal(t, 2, reqCount(p, "docker", "quay.io/allowed"), "equal scope ANDs the cluster scope")
	assert.Len(t, p.Default, 2, "namespace default ANDs the cluster default")

	// No namespace default: the cluster default is inherited unchanged.
	p = composeNamespaceLayer(cluster, mustPolicy(t, `{"transports":{"docker":{"quay.io/x":[{"type":"reject"}]}}}`), "ns2.json")
	assert.Len(t, p.Default, 1)
}
