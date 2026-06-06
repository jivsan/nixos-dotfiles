{ pkgs, ... }:
let
  nasBase = "/mnt/nas-backups-workstation/Backups/mjolnir";

  backup-nixos = pkgs.writeShellScriptBin "backup-nixos" ''
    set -e
    DEST="${nasBase}"
    DATE=$(date +%Y-%m-%d_%H-%M)

    echo "==> NixOS Backup to TrueNAS"
    echo "    Destination: $DEST"
    echo ""

    # Ensure destination directories exist
    mkdir -p "$DEST/nixos-dotfiles"
    mkdir -p "$DEST/config"
    mkdir -p "$DEST/octane-src"

    # Backup nixos-dotfiles
    echo "[1/3] Backing up ~/nixos-dotfiles..."
    ${pkgs.rsync}/bin/rsync -av --delete --no-group --no-owner --no-perms --omit-dir-times \
      --exclude='.git' \
      --exclude='result' \
      "$HOME/nixos-dotfiles/" "$DEST/nixos-dotfiles/"

    # Backup ~/.config
    echo "[2/3] Backing up ~/.config..."
    ${pkgs.rsync}/bin/rsync -av --delete --no-group --no-owner --no-perms --omit-dir-times \
      --exclude='BraveSoftware' \
      --exclude='discord' \
      --exclude='vesktop' \
      --exclude='helium' \
      --exclude='Code' \
      --exclude='VSCodium' \
      "$HOME/.config/" "$DEST/config/"

    # Backup octane-src
    echo "[3/3] Backing up ~/octane-src..."
    ${pkgs.rsync}/bin/rsync -av --delete --no-group --no-owner --no-perms --omit-dir-times \
      "$HOME/octane-src/" "$DEST/octane-src/"

    echo ""
    echo "==> Backup complete! ($DATE)"
    echo "    Location: $DEST"
    du -sh "$DEST/nixos-dotfiles" "$DEST/config" "$DEST/octane-src"
  '';

  restore-nixos = pkgs.writeShellScriptBin "restore-nixos" ''
    set -e
    SRC="${nasBase}"

    echo "==> NixOS Restore from TrueNAS"
    echo "    Source: $SRC"
    echo ""

    if [ ! -d "$SRC/nixos-dotfiles" ]; then
      echo "Error: No backup found at $SRC"
      exit 1
    fi

    echo "[1/3] Restoring ~/nixos-dotfiles..."
    ${pkgs.rsync}/bin/rsync -av --delete --no-group --no-owner --no-perms --omit-dir-times \
      "$SRC/nixos-dotfiles/" "$HOME/nixos-dotfiles/"

    echo "[2/3] Restoring ~/.config..."
    ${pkgs.rsync}/bin/rsync -av --delete --no-group --no-owner --no-perms --omit-dir-times \
      "$SRC/config/" "$HOME/.config/"

    echo "[3/3] Restoring ~/octane-src..."
    mkdir -p "$HOME/octane-src"
    ${pkgs.rsync}/bin/rsync -av --delete --no-group --no-owner --no-perms --omit-dir-times \
      "$SRC/octane-src/" "$HOME/octane-src/"

    echo ""
    echo "==> Restore complete!"
    echo "    Run: sudo nixos-rebuild switch --flake ~/nixos-dotfiles#mjolnir"
    echo "    Run: sudo octane-install ~/octane-src"
  '';
in
{
  environment.systemPackages = [
    backup-nixos
    restore-nixos
  ];
}
