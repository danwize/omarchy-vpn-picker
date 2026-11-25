#!/usr/bin/env bash
#
# Test harness for omarchy-vpn-picker. Everything runs against a temporary
# HOME with stubbed nmcli, openvpn, sudo, op, pgrep, notify-send, menu, and
# terminal programs, so nothing touches the real system.
#
#   tests/run.sh
#
# Stub bodies are single-quoted on purpose (they expand when the stub runs),
# and `cond && ok || bad` is safe because ok always succeeds.
# shellcheck disable=SC2016,SC2015

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PICKER="$ROOT/bin/omarchy-vpn-picker"

PASS=0
FAIL=0
CURRENT=""

ok() { PASS=$((PASS + 1)); }
bad() {
  FAIL=$((FAIL + 1))
  printf 'FAIL [%s] %s\n' "$CURRENT" "$*" >&2
}
assert_eq() {
  if [[ $1 == "$2" ]]; then ok; else bad "${3:-}: expected [$2] got [$1]"; fi
}
assert_contains() {
  if [[ $1 == *"$2"* ]]; then ok; else bad "${3:-}: [$1] does not contain [$2]"; fi
}
assert_not_contains() {
  if [[ $1 != *"$2"* ]]; then ok; else bad "${3:-}: [$1] unexpectedly contains [$2]"; fi
}

# --- sandbox --------------------------------------------------------------------

setup() {
  CURRENT=$1
  T=$(mktemp -d "${TMPDIR:-/tmp}/vpn-picker-test.XXXXXX")
  export HOME="$T/home"
  export XDG_CONFIG_HOME="$HOME/.config"
  export XDG_DATA_HOME="$HOME/.local/share"
  export VPN_PICKER_PROC_DIR="$T/proc"
  export STUB_LOG="$T/log"
  unset VPN_PICKER_CONFIG_DIR VPN_PICKER_VPN_DIR VPN_PICKER_MENU VPN_PICKER_TERMINAL
  mkdir -p "$HOME/vpn" "$XDG_CONFIG_HOME/vpn-picker/profiles" "$T/bin" "$T/proc"
  : >"$STUB_LOG"
  make_stubs
  export PATH="$T/bin:/usr/bin:/bin"
}

teardown() {
  rm -rf "$T"
}

stub() {
  local name=$1 body=$2
  printf '#!/usr/bin/env bash\n%s\n' "$body" >"$T/bin/$name"
  chmod +x "$T/bin/$name"
}

make_stubs() {
  # sudo: no privileges, just run the command (and accept -v).
  stub sudo '[[ $1 == -v ]] && { echo "sudo -v" >>"$STUB_LOG"; exit 0; }; exec "$@"'
  # openvpn: record argv and whatever arrives on stdin when told to read it.
  stub openvpn 'printf "openvpn argv:" >>"$STUB_LOG"; printf " [%s]" "$@" >>"$STUB_LOG"; echo >>"$STUB_LOG"
prev=""; for a in "$@"; do if [[ $prev == --auth-user-pass ]]; then printf "authfile:%s\n" "$(cat "$a")" >>"$STUB_LOG"; fi; prev=$a; done
exit "${OPENVPN_EXIT:-0}"'
  # nmcli: canned connection list; record "up" calls and the passwd-file.
  stub nmcli 'case "$*" in
  "-t -f NAME connection show") printf "%s\n" "Wired connection 1" "Office\\:Net" "work-nm" ;;
  "-t -f TYPE,NAME connection show --active") [[ -n ${NM_ACTIVE:-} ]] && printf "%s\n" "$NM_ACTIVE" ;;
  *" up "*)
    printf "nmcli argv:" >>"$STUB_LOG"; printf " [%s]" "$@" >>"$STUB_LOG"; echo >>"$STUB_LOG"
    prev=""; for a in "$@"; do if [[ $prev == passwd-file ]]; then printf "passwdfile:%s\n" "$(cat "$a")" >>"$STUB_LOG"; fi; prev=$a; done ;;
  *" down "*) printf "nmcli down:%s\n" "${@: -1}" >>"$STUB_LOG" ;;
esac'
  # op: fixed answers for known references; OP_FAIL=1 simulates signed out.
  stub op '[[ ${OP_FAIL:-0} == 1 ]] && exit 1
ref=${@: -1}
printf "op %s\n" "$*" >>"$STUB_LOG"
case $ref in
  *"/username") printf "op-user" ;;
  *"/password") printf "op-pass" ;;
  *"attrtype=otp") printf "123456" ;;
  *) exit 1 ;;
esac'
  stub pgrep 'printf "%s\n" ${PGREP_PIDS:-}'
  stub notify-send 'printf "notify:%s\n" "$*" >>"$STUB_LOG"'
  # Menu stub: log the offered rows and answer with $MENU_CHOICE.
  stub walker 'cat >"$STUB_LOG.menu"; printf "%s\n" "${MENU_CHOICE:-}"'
  # Terminal stub: run the command in place.
  stub xdg-terminal-exec 'printf "terminal:%s\n" "$*" >>"$STUB_LOG"; exec "$@"'
}

picker() { "$PICKER" "$@"; }
log() { cat "$STUB_LOG"; }

# --- tests --------------------------------------------------------------------------

test_parse_profile() {
  setup parse_profile
  cat >"$XDG_CONFIG_HOME/vpn-picker/profiles/example.conf" <<'EOF'
# a comment
   # indented comment

NAME="Example VPN"
CONFIG = example.ovpn
USERNAME='jdoe'
OTP_OP="op://Private/Example VPN/one-time password?attrtype=otp"
OTP_SEPARATOR=""
EOF
  # shellcheck source=/dev/null
  source "$PICKER"
  vp_load_global_config
  vp_load_profile "$XDG_CONFIG_HOME/vpn-picker/profiles/example.conf"
  assert_eq "$?" 0 "load status"
  assert_eq "${PROFILE[NAME]}" "Example VPN" "quoted name"
  assert_eq "${PROFILE[CONFIG]}" "$HOME/vpn/example.ovpn" "relative config resolves into VPN_DIR"
  assert_eq "${PROFILE[USERNAME]}" "jdoe" "single quotes stripped"
  assert_eq "${PROFILE[OTP_OP]}" "op://Private/Example VPN/one-time password?attrtype=otp" "op ref kept literally"
  assert_eq "${PROFILE[TYPE]}" "openvpn" "type defaults to openvpn"
  assert_eq "${PROFILE[PASSWORD_MODE]}" "otp" "OTP_OP alone infers otp mode"
  assert_eq "${PROFILE[ID]}" "example" "id from file name"
  teardown
}

test_parse_rejects_and_warns() {
  setup parse_rejects
  local p="$XDG_CONFIG_HOME/vpn-picker/profiles"
  printf 'CONFIG=~/elsewhere/a.ovpn\nBOGUS=1\nnot a line\nPASSWORD_OP=op://V/I/password\n' >"$p/a.conf"
  printf 'TYPE=nm\n' >"$p/b.conf"
  printf 'CONFIG=x.ovpn\nPASSWORD_MODE=sometimes\n' >"$p/c.conf"
  printf 'CONNECTION="Office VPN"\nPASSWORD_OP=op://V/I/password\nOTP_OP=op://V/I/otp?attrtype=otp\n' >"$p/d.conf"
  printf 'CONFIG=x.ovpn\nUSERNAME=u\n$(touch %s/pwned)\n' "$T" >"$p/e.conf"
  # shellcheck source=/dev/null
  source "$PICKER"
  vp_load_global_config
  local err
  err=$(vp_load_profile "$p/a.conf" 2>&1 >/dev/null)
  vp_load_profile "$p/a.conf" 2>/dev/null
  assert_eq "${PROFILE[CONFIG]}" "$HOME/elsewhere/a.ovpn" "~ expands to HOME"
  assert_eq "${PROFILE[PASSWORD_MODE]}" "password" "PASSWORD_OP infers password mode"
  assert_contains "$err" "unknown key 'BOGUS'" "unknown key warned"
  assert_contains "$err" "not KEY=value" "malformed line warned"
  vp_load_profile "$p/b.conf" 2>/dev/null
  assert_eq "$?" 1 "nm without CONNECTION rejected"
  vp_load_profile "$p/c.conf" 2>/dev/null
  assert_eq "$?" 1 "bad PASSWORD_MODE rejected"
  vp_load_profile "$p/d.conf" 2>/dev/null
  assert_eq "${PROFILE[TYPE]}" "nm" "CONNECTION infers nm"
  assert_eq "${PROFILE[PASSWORD_MODE]}" "password+otp" "PASSWORD_OP+OTP_OP infers password+otp"
  vp_load_profile "$p/e.conf" 2>/dev/null
  [[ ! -e $T/pwned ]] && ok || bad "profile content was executed"
  teardown
}

test_global_config() {
  setup global_config
  mkdir -p "$HOME/my vpns"
  printf 'VPN_DIR="$HOME/my vpns/"\nMENU=fuzzel\n' >"$XDG_CONFIG_HOME/vpn-picker/config"
  # shellcheck source=/dev/null
  source "$PICKER"
  vp_load_global_config
  assert_eq "${VP_CONF[VPN_DIR]}" "$HOME/my vpns" "VPN_DIR from config, \$HOME expanded, trailing slash dropped"
  assert_eq "${VP_CONF[MENU]}" "fuzzel" "MENU from config"
  VPN_PICKER_VPN_DIR=/srv/vpn vp_load_global_config
  assert_eq "${VP_CONF[VPN_DIR]}" "/srv/vpn" "env overrides config"
  teardown
}

test_list_entries() {
  setup list_entries
  mkdir -p "$HOME/vpn/sub"
  : >"$HOME/vpn/claimed.ovpn"
  : >"$HOME/vpn/plain.ovpn"
  : >"$HOME/vpn/sub/Other.OVPN"
  : >"$HOME/vpn/notes.txt"
  printf 'NAME="Claimed VPN"\nCONFIG=claimed.ovpn\n' >"$XDG_CONFIG_HOME/vpn-picker/profiles/claimed.conf"
  printf 'NAME="Work"\nCONNECTION=work-nm\n' >"$XDG_CONFIG_HOME/vpn-picker/profiles/work.conf"
  local out
  out=$(picker list 2>&1)
  assert_eq "$out" $'profile:claimed\tClaimed VPN\nprofile:work\tWork\novpn:plain.ovpn\tplain.ovpn\novpn:sub/Other.OVPN\tsub/Other.OVPN' "entries"
  printf 'NAME="Other"\nCONFIG=./sub//Other.OVPN\n' >"$XDG_CONFIG_HOME/vpn-picker/profiles/other.conf"
  out=$(picker list 2>&1)
  assert_not_contains "$out" "ovpn:sub/Other.OVPN" "non-canonical CONFIG path still claims the file"
  teardown
}

test_credentials_otp_from_op() {
  setup credentials_otp_from_op
  : >"$HOME/vpn/example.ovpn"
  printf 'NAME="Example VPN"\nCONFIG=example.ovpn\nUSERNAME=jdoe\nOTP_OP="op://Private/Example VPN/one-time password?attrtype=otp"\nOP_ACCOUNT=my.1password.com\n' \
    >"$XDG_CONFIG_HOME/vpn-picker/profiles/example.conf"
  picker connect example </dev/null >/dev/null 2>&1
  assert_eq "$?" 0 "connect exit"
  local l
  l=$(log)
  assert_contains "$l" "authfile:jdoe"$'\n'"123456" "username + OTP delivered on stdin"
  assert_contains "$l" "openvpn argv: [--config] [$HOME/vpn/example.ovpn] [--auth-user-pass] [/dev/stdin]" "auth via stdin"
  assert_not_contains "$(grep '^openvpn argv' "$STUB_LOG")" "123456" "OTP not on command line"
  assert_contains "$l" "op read --no-newline --account my.1password.com op://Private/Example VPN/one-time password?attrtype=otp" "op account passed"
  # sudo is primed before the OTP is fetched.
  local sudo_line op_line
  sudo_line=$(grep -n '^sudo -v' "$STUB_LOG" | cut -d: -f1)
  op_line=$(grep -n '^op ' "$STUB_LOG" | head -1 | cut -d: -f1)
  ((sudo_line < op_line)) && ok || bad "sudo -v should run before op"
  teardown
}

test_credentials_password_plus_otp() {
  setup credentials_password_plus_otp
  : >"$HOME/vpn/example.ovpn"
  printf 'CONFIG=example.ovpn\nUSERNAME_OP=op://Private/Example VPN/username\nPASSWORD_OP=op://Private/Example VPN/password\nOTP_OP=op://Private/Example VPN/otp?attrtype=otp\nOTP_SEPARATOR=":"\nOPENVPN_ARGS=--mute 5 --verb 3\n' \
    >"$XDG_CONFIG_HOME/vpn-picker/profiles/example.conf"
  picker connect example </dev/null >/dev/null 2>&1
  local l
  l=$(log)
  assert_contains "$l" "authfile:op-user"$'\n'"op-pass:123456" "password+otp joined with separator"
  assert_contains "$l" "[--mute] [5] [--verb] [3] [--auth-user-pass]" "extra openvpn args"
  teardown
}

test_credentials_prompt_fallback() {
  setup credentials_prompt_fallback
  : >"$HOME/vpn/example.ovpn"
  printf 'CONFIG=example.ovpn\nUSERNAME=jdoe\nOTP_OP=op://Private/Example VPN/otp?attrtype=otp\n' \
    >"$XDG_CONFIG_HOME/vpn-picker/profiles/example.conf"
  local err
  err=$(printf '654321\n' | OP_FAIL=1 picker connect example 2>&1 >/dev/null)
  assert_contains "$(log)" "authfile:jdoe"$'\n'"654321" "op signed out falls back to prompt"
  assert_contains "$err" "1Password lookup failed" "fallback explained"
  : >"$STUB_LOG"
  err=$(printf '777777\n' | VPN_PICKER_OP="$T/no-such-op" picker connect example 2>&1 >/dev/null)
  assert_contains "$(log)" "authfile:jdoe"$'\n'"777777" "op missing falls back to prompt"
  assert_contains "$err" "op) not found" "missing op explained"
  : >"$STUB_LOG"
  printf '\n' | VPN_PICKER_OP="$T/no-such-op" picker connect example >/dev/null 2>&1
  assert_eq "$?" 1 "empty answer cancels"
  assert_not_contains "$(log)" "openvpn argv" "openvpn not started after cancel"
  teardown
}

test_no_credentials_for_plain_ovpn() {
  setup plain_ovpn
  : >"$HOME/vpn/plain.ovpn"
  picker connect plain.ovpn </dev/null >/dev/null 2>&1
  assert_contains "$(log)" "openvpn argv: [--config] [$HOME/vpn/plain.ovpn]"$'\n' "plain openvpn"
  assert_not_contains "$(log)" "auth-user-pass" "no auth file when none configured"
  teardown
}

test_nm_connect() {
  setup nm_connect
  : >"$HOME/vpn/Work-NM.ovpn"
  picker connect Work-NM.ovpn </dev/null >/dev/null 2>&1
  assert_contains "$(log)" "nmcli argv: [--ask] [connection] [up] [id] [work-nm]"$'\n' "matching NM connection used for bare ovpn"
  : >"$STUB_LOG"
  printf 'NAME="Office"\nCONNECTION="Office:Net"\nOTP_OP=op://Private/Office/otp?attrtype=otp\n' \
    >"$XDG_CONFIG_HOME/vpn-picker/profiles/office.conf"
  picker connect office </dev/null >/dev/null 2>&1
  local l
  l=$(log)
  assert_contains "$l" "[up] [id] [Office:Net] [passwd-file]" "nm profile passes passwd-file"
  assert_contains "$l" "passwdfile:vpn.secrets.password:123456" "OTP in NM passwd-file"
  assert_not_contains "$(grep '^nmcli argv' "$STUB_LOG")" "123456" "OTP not on nmcli command line"
  teardown
}

test_status() {
  setup status
  local out
  out=$(picker status --json)
  assert_eq "$out" '{"connected":false,"count":0,"text":"","tooltip":"VPN: not connected","class":"disconnected","connections":[]}' "disconnected json"
  mkdir -p "$T/proc/4242"
  printf 'openvpn\0--config\0%s\0--auth-user-pass\0/dev/stdin\0' "$HOME/vpn/my \"vpn\".ovpn" >"$T/proc/4242/cmdline"
  printf 'openvpn\n' >"$T/proc/4242/comm"
  out=$(NM_ACTIVE=$'802-11-wireless:Home\nvpn:Office\\:Net\nwireguard:wg0' PGREP_PIDS=4242 picker status --json)
  assert_eq "$out" '{"connected":true,"count":3,"text":"Office:Net, wg0, my \"vpn\".ovpn","tooltip":"VPN: Office:Net, wg0, my \"vpn\".ovpn","class":"connected","connections":["Office:Net","wg0","my \"vpn\".ovpn"]}' "connected json, wifi ignored"
  printf 'NAME="Example VPN"\nCONFIG=%s\n' "$HOME/vpn/my \"vpn\".ovpn" >"$XDG_CONFIG_HOME/vpn-picker/profiles/ex.conf"
  out=$(PGREP_PIDS=4242 picker status)
  assert_eq "$out" "Connected: Example VPN" "profile name shown for active openvpn"
  if command -v jq >/dev/null 2>&1; then
    out=$(NM_ACTIVE="vpn:Tab$(printf '\t')Name" picker status --json | jq -r '.connections[0]')
    assert_eq "$out" "Tab	Name" "json escaping round-trips through jq"
  fi
  teardown
}

test_menu_connect_and_disconnect() {
  setup menu
  export VPN_PICKER_MENU=walker
  : >"$HOME/vpn/plain.ovpn"
  MENU_CHOICE="plain.ovpn" picker menu </dev/null >/dev/null 2>&1
  local l
  l=$(log)
  assert_contains "$(cat "$STUB_LOG.menu")" "Status: not connected"$'\n'"plain.ovpn" "menu rows"
  assert_contains "$l" "terminal:$PICKER __terminal-connect ovpn:plain.ovpn" "connect runs in a terminal"
  assert_contains "$l" "openvpn argv: [--config] [$HOME/vpn/plain.ovpn]" "openvpn started from menu"
  : >"$STUB_LOG"
  NM_ACTIVE="vpn:Office" MENU_CHOICE="Disconnect Office" picker menu </dev/null >/dev/null 2>&1
  assert_contains "$(log)" "nmcli down:Office" "disconnect NM from menu"
  : >"$STUB_LOG"
  MENU_CHOICE="" picker menu </dev/null >/dev/null 2>&1
  assert_eq "$(log)" "" "cancel does nothing"
  teardown
}

test_disconnect_pid_guard() {
  setup disconnect_pid
  mkdir -p "$T/proc/99"
  printf 'bash\n' >"$T/proc/99/comm"
  picker disconnect pid:99 >/dev/null 2>&1
  assert_eq "$?" 1 "refuses to kill non-openvpn pid"
  stub kill 'printf "kill:%s\n" "$*" >>"$STUB_LOG"'
  printf 'openvpn\n' >"$T/proc/99/comm"
  picker disconnect pid:99 >/dev/null 2>&1
  assert_contains "$(log)" "kill:-TERM 99" "kills openvpn pid via sudo"
  local out
  out=$(picker disconnect pid:12345 2>&1; echo "rc=$?")
  assert_contains "$out" "rc=1" "missing pid fails without dying"
  teardown
}

test_resolve_rejects_traversal() {
  setup traversal
  picker connect "ovpn:../../etc/passwd" </dev/null >/dev/null 2>&1
  assert_eq "$?" 1 "path traversal refused"
  picker connect "profile:../x" </dev/null >/dev/null 2>&1
  assert_eq "$?" 1 "profile traversal refused"
  teardown
}

test_add() {
  setup add
  printf 'client\n' >"$T/Download.ovpn"
  picker add "$T/Download.ovpn" --name "Example VPN" >/dev/null
  assert_eq "$?" 0 "add exit"
  assert_eq "$(stat -c %a "$HOME/vpn/Download.ovpn")" "600" "config copied mode 600"
  assert_eq "$(stat -c %a "$XDG_CONFIG_HOME/vpn-picker/profiles/example-vpn.conf")" "600" "profile mode 600"
  assert_contains "$(picker list)" $'profile:example-vpn\tExample VPN' "added profile listed"
  assert_not_contains "$(picker list)" "ovpn:Download.ovpn" "added config claimed by profile"
  picker add "$T/Download.ovpn" --name "Example VPN" >/dev/null 2>&1
  assert_eq "$?" 1 "refuses to overwrite"
  teardown
}

test_install_script() {
  setup install
  "$ROOT/install.sh" >/dev/null
  assert_eq "$?" 0 "install exit"
  local desktop="$XDG_DATA_HOME/applications/omarchy-vpn-picker.desktop"
  [[ -f $desktop ]] && ok || bad "desktop entry missing"
  assert_contains "$(cat "$desktop")" "Exec=$HOME/.local/bin/omarchy-vpn-picker" "desktop Exec"
  [[ -x $HOME/.local/bin/omarchy-vpn-picker ]] && ok || bad "launcher not installed"
  [[ -f $XDG_CONFIG_HOME/vpn-picker/config ]] && ok || bad "config not created"
  [[ -f $XDG_CONFIG_HOME/vpn-picker/profiles/example.conf.sample ]] && ok || bad "sample profile missing"
  assert_eq "$("$HOME/.local/bin/omarchy-vpn-picker" version)" "$("$PICKER" version)" "installed copy runs"
  printf 'VPN_DIR=~/keep\n' >"$XDG_CONFIG_HOME/vpn-picker/config"
  "$ROOT/install.sh" >/dev/null
  assert_eq "$(cat "$XDG_CONFIG_HOME/vpn-picker/config")" "VPN_DIR=~/keep" "reinstall keeps config"
  "$ROOT/install.sh" --uninstall >/dev/null
  [[ ! -e $desktop && ! -e $HOME/.local/bin/omarchy-vpn-picker ]] && ok || bad "uninstall left files"
  [[ -f $XDG_CONFIG_HOME/vpn-picker/config ]] && ok || bad "uninstall must keep config"
  teardown
}

test_manifest() {
  CURRENT=manifest
  if command -v omarchy-plugin-validate >/dev/null 2>&1; then
    omarchy-plugin-validate "$ROOT" && ok || bad "omarchy-plugin-validate failed"
  fi
  if command -v jq >/dev/null 2>&1; then
    jq -e '.schemaVersion == 1 and (.id | test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and (.id | startswith("omarchy.") | not)
      and (.kinds | index("bar-widget")) and (.entryPoints.barWidget | type == "string")' \
      "$ROOT/manifest.json" >/dev/null && ok || bad "manifest shape"
    [[ -f $ROOT/$(jq -r .entryPoints.barWidget "$ROOT/manifest.json") ]] && ok || bad "entry point missing"
    assert_eq "$(jq -r .version "$ROOT/manifest.json")" "$("$PICKER" version)" "manifest and script versions match"
  fi
  [[ -z $(find "$ROOT" -name .git -prune -o -type l -print) ]] && ok || bad "symlinks are not allowed in a plugin"
}

# Each test runs in a subshell (it sources the picker and changes HOME), so
# results are reported through a file.
RESULTS=$(mktemp)
trap 'rm -f "$RESULTS"' EXIT
run_all() {
  local t
  for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
    (
      "$t"
      printf '%s %s\n' "$PASS" "$FAIL" >>"$RESULTS"
    )
  done
  local p=0 f=0 a b
  while read -r a b; do
    p=$((p + a))
    f=$((f + b))
  done <"$RESULTS"
  printf '%d passed, %d failed\n' "$p" "$f"
  ((f == 0))
}

run_all
