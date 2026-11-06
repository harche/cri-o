set -uo pipefail
R=localhost:5000; D=/etc/containers/policy.json.d; K=/etc/pki/poc
sig() { echo "[{\"type\":\"sigstoreSigned\",\"keyPath\":\"$K/$1.pub\",\"signedIdentity\":{\"type\":\"matchRepository\"}}]"; }
ACCEPT='[{"type":"insecureAcceptAnything"}]'
base() { sudo tee /etc/containers/policy.json >/dev/null; }
frag() { sudo mkdir -p $D; sudo tee $D/$1 >/dev/null; }
clean() { sudo rm -rf $D /etc/crio/policies/*.json; }
cat > /tmp/pod-ns1.json <<'P'
{"metadata":{"name":"p","namespace":"ns1","uid":"u1"},"linux":{"security_context":{"namespace_options":{"network":2}}}}
P
pull() { # pull <expect OK|FAIL> <image> [pod-config]
  sudo crictl rmi "$R/$2" >/dev/null 2>&1
  local out; out=$(sudo crictl pull ${3:+--pod-config $3} "$R/$2" 2>&1); local rc=$?
  local got=OK; [ $rc -ne 0 ] && got=FAIL
  local mark=PASS; [ "$got" != "$1" ] && mark="**MISMATCH**"
  local msg=""; [ $rc -ne 0 ] && msg=$(echo "$out" | sed 's#\\"#"#g' | grep -oE '(policy scope|Source image rejected|invalid policy)[^\\]*' | head -1 | cut -c1-150)
  printf '  %-12s %-24s want=%-4s got=%-4s %s\n' "$mark" "$2${3:+ (ns1)}" "$1" "$got" "$msg"
}
BASE="{\"default\":$ACCEPT,\"transports\":{\"docker\":{\"$R/other\":$(sig keyA)}}}"

echo "T0 base only: other/* needs keyA, rest accept"; clean; echo "$BASE" | base
pull OK partner/app:unsigned; pull FAIL other/app:unsigned; pull OK other/app:signedA

echo "T1 + 50-partner.json: partner needs keyA (no restart)"
echo "{\"transports\":{\"docker\":{\"$R/partner\":$(sig keyA)}}}" | frag 50-partner.json
pull OK partner/app:signedA; pull FAIL partner/app:signedB; pull FAIL partner/app:unsigned

echo "T2 remove fragment -> base behavior back"; clean
pull OK partner/app:unsigned

echo "T3 two fragments, same scope -> load error"
echo "{\"transports\":{\"docker\":{\"$R/partner\":$(sig keyA)}}}" | frag 10-a.json
echo "{\"transports\":{\"docker\":{\"$R/partner\":$(sig keyB)}}}" | frag 20-b.json
pull FAIL partner/app:signedA; clean

echo "T4 fragment tries to weaken base (other/app accept-anything)"
echo "{\"transports\":{\"docker\":{\"$R/other/app\":$ACCEPT}}}" | frag 10-weaken.json
pull FAIL other/app:unsigned; pull OK other/app:signedA; clean

echo "T5 fragment sets default -> rejected"
echo "{\"default\":$ACCEPT}" | frag 10-default.json
pull FAIL partner/app:unsigned; clean

echo "T6 broken JSON fragment -> fail closed"
echo '{"transports":' | frag 10-broken.json
pull FAIL partner/app:unsigned; clean

echo "T7 namespace policy /etc/crio/policies/ns1.json + fragment"
sudo mkdir -p /etc/crio/policies; echo "{\"default\":$ACCEPT}" | sudo tee /etc/crio/policies/ns1.json >/dev/null
pull OK partner/app:unsigned /tmp/pod-ns1.json
echo "{\"transports\":{\"docker\":{\"$R/partner\":$(sig keyA)}}}" | frag 50-partner.json
pull FAIL partner/app:unsigned /tmp/pod-ns1.json; pull OK partner/app:signedA /tmp/pod-ns1.json; clean

echo "T8 reject-by-default base + allowlist fragment (default not inherited)"
echo "{\"default\":[{\"type\":\"reject\"}],\"transports\":{\"docker\":{\"$R/other\":$(sig keyA)}}}" | base
echo "{\"transports\":{\"docker\":{\"$R/partner\":$(sig keyA)}}}" | frag 50-partner.json
pull OK partner/app:signedA; pull FAIL partner/app:unsigned; pull FAIL other/app:unsigned; clean
echo "T9 same-file exemption kept; other files still bind it"
echo "{\"transports\":{\"docker\":{\"$R/partner\":$(sig keyA),\"$R/partner/app\":$ACCEPT}}}" | frag 50-cip.json
pull OK partner/app:unsigned
echo "{\"transports\":{\"docker\":{\"$R/other/app\":$ACCEPT}}}" | frag 60-exempt-other.json
pull FAIL other/app:unsigned; clean
echo "$BASE" | base
