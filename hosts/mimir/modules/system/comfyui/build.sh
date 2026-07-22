#!/usr/bin/env bash
# Build the pinned ComfyUI image on mimir. Run after changing the Containerfile,
# then `sudo nixos-rebuild switch --flake .#mimir` to (re)start the container.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=v0.28.2   # keep in sync with comfyui.nix + Containerfile ARG

sudo podman build -t "localhost/comfyui:${VERSION}" -f Containerfile .
echo "✔ built localhost/comfyui:${VERSION}"
