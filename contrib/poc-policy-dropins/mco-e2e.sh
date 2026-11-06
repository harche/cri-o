# Install MCO-rendered node files (mco-rendered/<scenario>) and check CRI-O pulls.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd); HERE=${POC_DIR:-$HERE}
R=localhost:5000
# a repo outside every allowed scope
sudo skopeo copy -q --dest-tls-verify=false docker://quay.io/libpod/alpine:latest docker://$R/third/app:unsigned >/dev/null
for ns in ns1 ns2; do
  echo "{\"metadata\":{\"name\":\"p\",\"namespace\":\"$ns\",\"uid\":\"u-$ns\"},\"linux\":{\"security_context\":{\"namespace_options\":{\"network\":2}}}}" > /tmp/pod-$ns.json
done
install_scenario() {
  sudo rm -rf /etc/containers/policy.json.d /etc/crio/policies/*.json /etc/containers/registries.d/poc.yaml /etc/containers/registries.d/sigstore-registries.yaml
  sudo cp -r "$HERE/mco-rendered/$1/etc/." /etc/
}
pull() { # pull <scenario> <want> <image> <ns|->
  sudo crictl rmi "$R/$3" >/dev/null 2>&1
  local pc=""; [ "$4" != "-" ] && pc="--pod-config /tmp/pod-$4.json"
  local got=OK; sudo crictl pull $pc "$R/$3" >/tmp/pull.out 2>&1 || got=FAIL
  local mark=PASS; [ "$got" != "$2" ] && mark=MISMATCH
  echo "$1|$3|$4|$2|$got|$mark"
}
for sc in legacy dropins legacy-allowed dropins-allowed; do
  install_scenario $sc
  allowed=0; [[ $sc == *allowed ]] && allowed=1
  for ns in - ns1 ns2; do
    pull $sc OK   partner/app:signedA $ns
    pull $sc FAIL partner/app:signedB $ns
    pull $sc FAIL partner/app:unsigned $ns
    pull $sc OK   other/app:signedA $ns
    if [ $ns = ns1 ]; then pull $sc FAIL other/app:unsigned $ns; else pull $sc OK other/app:unsigned $ns; fi
    if [ $allowed = 1 ]; then pull $sc FAIL third/app:unsigned $ns; else pull $sc OK third/app:unsigned $ns; fi
  done
done
# Version skew stand-in: distro skopeo (container-libs without drop-in support) with the drop-in files.
for sc in legacy dropins; do
  install_scenario $sc; rm -rf /tmp/skew
  if skopeo copy -q --src-tls-verify=false docker://$R/partner/app:unsigned dir:/tmp/skew >/dev/null 2>&1; then got=OK; else got=FAIL; fi
  echo "skew-$sc (skopeo $(skopeo --version | awk '{print $3}'))|partner/app:unsigned|-|FAIL|$got|$([ $got = FAIL ] && echo PASS || echo 'EXPECTED-GAP')"
done
