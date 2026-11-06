set -euo pipefail
K=/etc/pki/poc; sudo mkdir -p $K; cd /tmp
# local registry
sudo podman rm -f reg >/dev/null 2>&1 || true
sudo podman run -d --name reg -p 5000:5000 quay.io/libpod/registry:2.8.2 >/dev/null
# CRI-O / containers: plain-http localhost registry, read sigstore attachments
sudo tee /etc/containers/registries.conf.d/50-poc.conf >/dev/null <<'R'
[[registry]]
location = "localhost:5000"
insecure = true
R
sudo mkdir -p /etc/containers/registries.d
sudo tee /etc/containers/registries.d/poc.yaml >/dev/null <<'R'
docker:
  localhost:5000:
    use-sigstore-attachments: true
R
# two sigstore keys
for k in keyA keyB; do
  [ -f $K/$k.pub ] || { printf 'pass' | sudo tee $K/$k.pass >/dev/null; sudo skopeo generate-sigstore-key --output-prefix $K/$k --passphrase-file $K/$k.pass >/dev/null; }
done
BB=docker://quay.io/libpod/busybox:latest; AL=docker://quay.io/libpod/alpine:latest
cp_img() { sudo skopeo copy -q --dest-tls-verify=false "$@"; }
SA="--sign-by-sigstore-private-key $K/keyA.private --sign-passphrase-file $K/keyA.pass"
SB="--sign-by-sigstore-private-key $K/keyB.private --sign-passphrase-file $K/keyB.pass"
# distinct manifest digests per tag (sigstore attachments are per digest)
cp_img $SA $BB docker://localhost:5000/partner/app:signedA
cp_img $SB --format oci $BB docker://localhost:5000/partner/app:signedB
cp_img $AL docker://localhost:5000/partner/app:unsigned
cp_img $SA $BB docker://localhost:5000/other/app:signedA
cp_img $AL docker://localhost:5000/other/app:unsigned
for t in partner/app:signedA partner/app:signedB partner/app:unsigned other/app:signedA other/app:unsigned; do
  echo "$t $(skopeo inspect --tls-verify=false docker://localhost:5000/$t --format '{{.Digest}}' | cut -c1-19)"; done
sudo systemctl reload crio
curl -s localhost:5000/v2/_catalog; ls $K
