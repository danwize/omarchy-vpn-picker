#!/usr/bin/env bash
#
# Install omarchy-vpn-picker without the Omarchy plugin system:
#   * the picker script into ~/.local/bin
#   * an app-launcher entry ("VPN Picker") into ~/.local/share/applications
#   * a starter config and a sample profile into ~/.config/vpn-picker
#     (existing files are never overwritten)
#
#   ./install.sh              install or update
#   ./install.sh --uninstall  remove the script and launcher entry (keeps config)

set -euo pipefail

SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BIN_DIR=${VPN_PICKER_BIN_DIR:-$HOME/.local/bin}
APP_DIR=${XDG_DATA_HOME:-$HOME/.local/share}/applications
CONFIG_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/vpn-picker
TARGET="$BIN_DIR/omarchy-vpn-picker"
DESKTOP="$APP_DIR/omarchy-vpn-picker.desktop"

uninstall() {
  rm -f "$TARGET" "$DESKTOP"
  echo "Removed $TARGET and $DESKTOP"
  echo "Your profiles and VPN configs were left in place ($CONFIG_DIR)."
}

install_files() {
  mkdir -p "$BIN_DIR" "$APP_DIR"
  install -m 755 "$SRC/bin/omarchy-vpn-picker" "$TARGET"

  local exec_path=$TARGET
  [[ $exec_path == *[[:space:]]* ]] && exec_path="\"$exec_path\""
  cat >"$DESKTOP" <<EOF
[Desktop Entry]
Name=VPN Picker
Comment=Connect or disconnect a VPN
Exec=$exec_path menu
Icon=network-vpn
Terminal=false
Type=Application
Categories=Network;Security;
Keywords=VPN;OpenVPN;Network;
EOF

  mkdir -p "$CONFIG_DIR/profiles"
  chmod 700 "$CONFIG_DIR" "$CONFIG_DIR/profiles"
  [[ -e $CONFIG_DIR/config ]] || install -m 600 "$SRC/examples/config" "$CONFIG_DIR/config"
  [[ -e $CONFIG_DIR/profiles/example.conf.sample ]] ||
    install -m 600 "$SRC/examples/profiles/example.conf" "$CONFIG_DIR/profiles/example.conf.sample"

  echo "Installed $TARGET"
  echo "Launcher entry: $DESKTOP"
  echo "Config: $CONFIG_DIR (sample profile: profiles/example.conf.sample)"
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "Note: $BIN_DIR is not on your PATH." ;;
  esac
  echo "Next: put .ovpn files in ~/vpn, or run: omarchy-vpn-picker add <file.ovpn> --name \"My VPN\""
}

case ${1:-} in
  "") install_files ;;
  --uninstall) uninstall ;;
  -h | --help) sed -n '3,11p' "$0" | sed 's/^# \{0,1\}//' ;;
  *)
    echo "unknown option: $1" >&2
    exit 2
    ;;
esac
