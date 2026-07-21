#!/usr/bin/env bash
# Generate heimdall's AmneziaWG keys and print Mishka's client config.
#
# Run on heimdall as root. Idempotent: existing keys are kept, so re-running
# just reprints the client config.
#
#   sudo bash hosts/heimdall/modules/system/amneziawg-keygen.sh
#
# The server private key is created here and never leaves the box. Only the
# public key and the PSK go into the client config.

set -euo pipefail

DIR=/var/lib/amneziawg

if ! command -v awg >/dev/null 2>&1; then
  echo "awg not found — the amneziawg module is not deployed yet." >&2
  echo "That is fine, run this first and the tunnel comes up clean on rebuild:" >&2
  echo "  sudo nix shell nixpkgs#amneziawg-tools -c bash $0" >&2
  echo "(sudo goes on the outside: it resets PATH, so nix shell must run as root.)" >&2
  exit 1
fi

mkdir -p "$DIR"
chmod 700 "$DIR"

if [[ ! -f "$DIR/heimdall.key" ]]; then
  ( umask 077; awg genkey > "$DIR/heimdall.key" )
  awg pubkey < "$DIR/heimdall.key" > "$DIR/heimdall.pub"
  echo "generated $DIR/heimdall.key + heimdall.pub" >&2
else
  echo "keeping existing $DIR/heimdall.key" >&2
fi

if [[ ! -f "$DIR/mishka.psk" ]]; then
  ( umask 077; awg genpsk > "$DIR/mishka.psk" )
  echo "generated $DIR/mishka.psk" >&2
else
  echo "keeping existing $DIR/mishka.psk" >&2
fi

chmod 600 "$DIR/heimdall.key" "$DIR/mishka.psk"
chmod 644 "$DIR/heimdall.pub"

cat >&2 <<'EOF'

--- client config for Mishka (AmneziaWG for Windows) ---
Replace <HER_PRIVATE_KEY> with the private key her client generated.
Everything else below is final. Contains the PSK: hand over securely.

EOF

cat <<EOF
[Interface]
PrivateKey = <HER_PRIVATE_KEY>
Address = 10.9.0.2/24
DNS = 10.0.20.4
MTU = 1280
Jc = 8
Jmin = 8
Jmax = 80
S1 = 0
S2 = 0
H1 = 1148573989
H2 = 1637771080
H3 = 957228754
H4 = 1401450629

[Peer]
PublicKey = $(cat "$DIR/heimdall.pub")
PresharedKey = $(cat "$DIR/mishka.psk")
AllowedIPs = 0.0.0.0/0
Endpoint = wg-home.oryxserver.org:51820
PersistentKeepalive = 25
EOF
