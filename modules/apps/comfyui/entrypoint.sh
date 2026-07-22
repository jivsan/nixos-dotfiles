#!/bin/sh
# Run ComfyUI from a venv that lives on a host volume (/var/lib/comfyui/venv),
# so packages pip-installed at runtime by ComfyUI-Manager survive a restart.
#
# Why this exists: NixOS oci-containers runs podman with `--rm` and does a
# `podman rm -f` in ExecStopPost, so the container filesystem — including
# site-packages — is destroyed on every stop. Persisting custom_nodes alone is
# not enough: a node's Python dependencies would vanish and it would fail to
# import on the next start.
#
# --system-site-packages means torch/ComfyUI's own deps still come from the
# image (they are big and pinned there); only runtime additions land on the
# volume. sys.executable becomes the venv python, which is what Manager shells
# out to for pip/uv installs.
set -e

VENV=/app/venv
PYVER="$(python -c 'import sys; print("%d.%d" % sys.version_info[:2])')"

# Recreate when missing or when the image's python moved on — a venv built
# against a different minor version silently fails to import anything.
if [ ! -x "$VENV/bin/python" ] || [ "$(cat "$VENV/.pyver" 2>/dev/null)" != "$PYVER" ]; then
  echo "[entrypoint] (re)creating persistent venv at $VENV for python $PYVER"
  # $VENV itself is a mount point, so clear its contents rather than the dir.
  rm -rf "$VENV"/* "$VENV"/.[!.]* 2>/dev/null || true
  python -m venv --system-site-packages "$VENV"
  printf '%s' "$PYVER" > "$VENV/.pyver"
fi

echo "[entrypoint] starting ComfyUI via $VENV/bin/python"
exec "$VENV/bin/python" main.py "$@"
