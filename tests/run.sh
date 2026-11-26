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
  export VPN_PICKER_STATE_FILE="$T/state"
  unset VPN_PICKER_CONFIG_DIR VPN_PICKER_VPN_DIR VPN_PICKER_MENU VPN_PICKER_TERMINAL SUDO_NOPASSWD
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
  # sudo: no privileges, just run the command. -v is logged; -n true and
  # -n -l answer according to SUDO_NOPASSWD (unset: a password is needed,
  # "openvpn": a NOPASSWD rule for openvpn, "other": one for another program,
  # "all": NOPASSWD for everything).
  stub sudo 'case "$1 ${2:-}" in
  "-v "*) echo "sudo -v" >>"$STUB_LOG"; exit 0 ;;
  "-n true") [[ ${SUDO_NOPASSWD:-} == all ]]; exit ;;
  "-n -l")
    case ${SUDO_NOPASSWD:-} in
      all) printf "User u may run the following commands:\n    (ALL) NOPASSWD: ALL\n" ;;
      openvpn) printf "User u may run the following commands:\n    (ALL) ALL\n    (root) NOPASSWD: /usr/bin/openvpn\n" ;;
      other) printf "User u may run the following commands:\n    (ALL) ALL\n    (root) NOPASSWD: /usr/bin/openvpn-helper\n" ;;
      *) echo "sudo: a password is required" >&2; exit 1 ;;
    esac
    exit 0 ;;
esac
exec "$@"'
  # openvpn: record argv and whatever arrives on stdin when told to read it.
  # OPENVPN_UP=1 prints the "tunnel is up" line and records whether the
  # state file was touched by then.
  stub openvpn 'printf "openvpn argv:" >>"$STUB_LOG"; printf " [%s]" "$@" >>"$STUB_LOG"; echo >>"$STUB_LOG"
prev=""; for a in "$@"; do if [[ $prev == --auth-user-pass ]]; then printf "authfile:%s\n" "$(cat "$a")" >>"$STUB_LOG"; fi; prev=$a; done
if [[ ${OPENVPN_WAIT_INT:-} == 1 ]]; then
  trap '"'"'echo "SIGINT received, process exiting"; echo "openvpn got INT" >>"$STUB_LOG"; exit 0'"'"' INT
  : >"$STUB_LOG.running"
  while :; do sleep 0.1; done
fi
if [[ ${OPENVPN_UP:-} == 1 ]]; then
  echo "2026-01-01 Initialization Sequence Completed"
  for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s $VPN_PICKER_STATE_FILE ]] && break; sleep 0.1; done
  [[ -s $VPN_PICKER_STATE_FILE ]] && echo "state-when-up:yes" >>"$STUB_LOG"
fi
exit "${OPENVPN_EXIT:-0}"'
  # nmcli: canned connection list; record "up" calls and the passwd-file.
  stub nmcli 'case "$*" in
  "-t -f TYPE,NAME connection show") printf "%s\n" "802-3-ethernet:Wired connection 1" "802-11-wireless:Home-WiFi" "vpn:Office\\:Net" "vpn:work-nm" "wireguard:wg-home" ;;
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

test_parse_inline_comments() {
  setup parse_inline_comments
  cat >"$XDG_CONFIG_HOME/vpn-picker/profiles/c.conf" <<'EOF'
NAME="Example # VPN"   # the quoted # stays
CONFIG=example.ovpn  # trailing comment
USERNAME='jdoe' # comment after single quotes
PASSWORD_OP=op://Private/Item/pass#word
OTP_OP=op://Private/Item/otp?attrtype=otp	# tab before the comment
OTP_SEPARATOR=#
EOF
  cat >"$XDG_CONFIG_HOME/vpn-picker/profiles/e.conf" <<'EOF'
CONFIG=example.ovpn
OTP_SEPARATOR= # none
USERNAME=	# fill in later
EOF
  # shellcheck source=/dev/null
  source "$PICKER"
  vp_load_global_config
  vp_load_profile "$XDG_CONFIG_HOME/vpn-picker/profiles/e.conf"
  assert_eq "$?" 0 "load status (empty values)"
  assert_eq "${PROFILE[OTP_SEPARATOR]}" "" "whitespace then # after = is an empty value"
  assert_eq "${PROFILE[USERNAME]}" "" "tab then # after = is an empty value"
  vp_load_profile "$XDG_CONFIG_HOME/vpn-picker/profiles/c.conf"
  assert_eq "$?" 0 "load status"
  assert_eq "${PROFILE[NAME]}" "Example # VPN" "# inside quotes kept, comment after quotes dropped"
  assert_eq "${PROFILE[CONFIG]}" "$HOME/vpn/example.ovpn" "comment after unquoted value dropped"
  assert_eq "${PROFILE[USERNAME]}" "jdoe" "comment after single-quoted value dropped"
  assert_eq "${PROFILE[PASSWORD_OP]}" "op://Private/Item/pass#word" "# without whitespace before it is kept"
  assert_eq "${PROFILE[OTP_OP]}" "op://Private/Item/otp?attrtype=otp" "comment after a tab dropped"
  assert_eq "${PROFILE[OTP_SEPARATOR]}" "#" "value that is just # kept"
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

test_config_path_normalised() {
  setup config_path_normalised
  mkdir -p "$HOME/vpn/sub" "$HOME/real"
  : >"$HOME/real/x.ovpn"
  ln -s "$HOME/real/x.ovpn" "$HOME/vpn/sub/link.ovpn"
  printf 'NAME="Linked"\nCONFIG=./sub//link.ovpn\n' >"$XDG_CONFIG_HOME/vpn-picker/profiles/l.conf"
  # shellcheck source=/dev/null
  source "$PICKER"
  vp_load_global_config
  vp_load_profile "$XDG_CONFIG_HOME/vpn-picker/profiles/l.conf"
  assert_eq "${PROFILE[CONFIG]}" "$HOME/real/x.ovpn" "CONFIG made canonical once at load"
  # An openvpn started with a differently written path still gets the label.
  mkdir -p "$T/proc/77"
  printf 'openvpn\0--config\0%s\0' "$HOME/vpn/sub/../sub/link.ovpn" >"$T/proc/77/cmdline"
  assert_eq "$(PGREP_PIDS=77 picker status)" "Connected: Linked" "label matches the canonical CONFIG"
  assert_not_contains "$(picker list)" "ovpn:sub/link.ovpn" "claim matches the canonical CONFIG"
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

test_symlinked_profiles_and_vpn_dir() {
  setup symlinks
  local p="$XDG_CONFIG_HOME/vpn-picker/profiles"
  mkdir -p "$HOME/dotfiles" "$HOME/real-vpn/sub" "$HOME/elsewhere"
  printf 'NAME="Linked Profile"\nCONNECTION=work-nm\n' >"$HOME/dotfiles/linked.conf"
  ln -s "$HOME/dotfiles/linked.conf" "$p/linked.conf"
  ln -s "$HOME/dotfiles/missing.conf" "$p/dangling.conf"
  : >"$HOME/real-vpn/a.ovpn"
  : >"$HOME/real-vpn/sub/b.ovpn"
  : >"$HOME/elsewhere/c.ovpn"
  ln -s "$HOME/elsewhere/c.ovpn" "$HOME/real-vpn/c.ovpn"
  rmdir "$HOME/vpn"
  ln -s "$HOME/real-vpn" "$HOME/vpn"
  local out
  out=$(picker list 2>&1)
  assert_eq "$out" $'profile:linked\tLinked Profile\novpn:a.ovpn\ta.ovpn\novpn:c.ovpn\tc.ovpn\novpn:sub/b.ovpn\tsub/b.ovpn' "symlinked profile, VPN_DIR, and .ovpn followed"
  assert_contains "$(picker doctor 2>&1)" "profile: linked -> nm work-nm" "doctor sees the same profiles"
  picker connect c.ovpn </dev/null >/dev/null 2>&1
  assert_contains "$(log)" "openvpn argv: [--cd] [$HOME/elsewhere] [--config] [$HOME/vpn/c.ovpn]" "symlinked .ovpn connects from its real folder"
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
  assert_contains "$l" "openvpn argv: [--cd] [$HOME/vpn] [--config] [$HOME/vpn/example.ovpn] [--auth-user-pass] [/dev/stdin]" "auth via stdin"
  assert_not_contains "$(grep '^openvpn argv' "$STUB_LOG")" "123456" "OTP not on command line"
  assert_contains "$l" "op read --no-newline --account my.1password.com op://Private/Example VPN/one-time password?attrtype=otp" "op account passed"
  # sudo is primed before the OTP is fetched.
  local sudo_line op_line
  sudo_line=$(grep -n '^sudo -v' "$STUB_LOG" | cut -d: -f1)
  op_line=$(grep -n '^op ' "$STUB_LOG" | head -1 | cut -d: -f1)
  ((sudo_line < op_line)) && ok || bad "sudo -v should run before op"
  teardown
}

test_sudo_prompt_only_when_needed() {
  setup sudo_prompt
  : >"$HOME/vpn/example.ovpn"
  printf 'CONFIG=example.ovpn\nUSERNAME=jdoe\nOTP_OP=op://Private/Example VPN/otp?attrtype=otp\n' \
    >"$XDG_CONFIG_HOME/vpn-picker/profiles/example.conf"
  SUDO_NOPASSWD=openvpn picker connect example </dev/null >/dev/null 2>&1
  assert_eq "$?" 0 "connect with NOPASSWD openvpn"
  assert_not_contains "$(log)" "sudo -v" "no sudo prompt with a NOPASSWD rule for openvpn"
  assert_contains "$(log)" "authfile:jdoe"$'\n'"123456" "credentials still sent"
  : >"$STUB_LOG"
  SUDO_NOPASSWD=all picker connect example </dev/null >/dev/null 2>&1
  assert_not_contains "$(log)" "sudo -v" "no sudo prompt when sudo needs no password"
  : >"$STUB_LOG"
  SUDO_NOPASSWD=other picker connect example </dev/null >/dev/null 2>&1
  assert_contains "$(log)" "sudo -v" "NOPASSWD for another program still primes sudo"
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

test_openvpn_output_state_and_status() {
  setup openvpn_output
  : >"$HOME/vpn/plain.ovpn"
  local out
  out=$(OPENVPN_UP=1 picker connect plain.ovpn </dev/null 2>/dev/null)
  assert_eq "$?" 0 "connect exit"
  assert_contains "$out" "Initialization Sequence Completed" "OpenVPN log still shown"
  assert_contains "$(log)" "state-when-up:yes" "state file touched when the tunnel comes up"
  rm -f "$VPN_PICKER_STATE_FILE"
  OPENVPN_EXIT=3 picker connect plain.ovpn </dev/null >/dev/null 2>&1
  assert_eq "$?" 3 "OpenVPN exit status passed through the log pipe"
  [[ -s $VPN_PICKER_STATE_FILE ]] && ok || bad "state file touched when OpenVPN exits"
  teardown
}

test_ctrl_c_during_openvpn() {
  setup ctrl_c
  : >"$HOME/vpn/plain.ovpn"
  local out="$T/out" pid rc=0
  set -m
  OPENVPN_WAIT_INT=1 "$PICKER" connect plain.ovpn </dev/null >"$out" 2>&1 &
  pid=$!
  set +m
  for _ in $(seq 50); do [[ -e $STUB_LOG.running ]] && break; sleep 0.1; done
  rm -f "$VPN_PICKER_STATE_FILE"
  kill -INT -- "-$pid"
  wait "$pid" || rc=$?
  assert_eq "$rc" 0 "picker exits normally after Ctrl+C"
  assert_contains "$(log)" "openvpn got INT" "OpenVPN received SIGINT"
  assert_contains "$(cat "$out")" "process exiting" "OpenVPN shutdown log still shown"
  [[ -s $VPN_PICKER_STATE_FILE ]] && ok || bad "state file touched after Ctrl+C"
  assert_contains "$(log)" "notify:" "notification sent after Ctrl+C"
  teardown
}

test_no_credentials_for_plain_ovpn() {
  setup plain_ovpn
  : >"$HOME/vpn/plain.ovpn"
  picker connect plain.ovpn </dev/null >/dev/null 2>&1
  assert_contains "$(log)" "openvpn argv: [--cd] [$HOME/vpn] [--config] [$HOME/vpn/plain.ovpn]"$'\n' "plain openvpn"
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
  [[ -s $VPN_PICKER_STATE_FILE ]] && ok || bad "state file touched after nmcli up"
  teardown
}

test_nm_match_only_vpn_types() {
  setup nm_types
  : >"$HOME/vpn/home-wifi.ovpn"
  : >"$HOME/vpn/Wired connection 1.ovpn"
  : >"$HOME/vpn/WG-Home.ovpn"
  picker connect home-wifi.ovpn </dev/null >/dev/null 2>&1
  assert_contains "$(log)" "openvpn argv: [--cd] [$HOME/vpn] [--config] [$HOME/vpn/home-wifi.ovpn]" "Wi-Fi connection with the same name is ignored"
  assert_not_contains "$(log)" "nmcli argv" "Wi-Fi connection not brought up"
  : >"$STUB_LOG"
  picker connect "Wired connection 1.ovpn" </dev/null >/dev/null 2>&1
  assert_not_contains "$(log)" "nmcli argv" "Ethernet connection with the same name is ignored"
  : >"$STUB_LOG"
  picker connect WG-Home.ovpn </dev/null >/dev/null 2>&1
  assert_contains "$(log)" "nmcli argv: [--ask] [connection] [up] [id] [wg-home]" "WireGuard connection with the same name is used"
  teardown
}

test_openvpn_cd_to_config_dir() {
  setup openvpn_cd
  mkdir -p "$HOME/vpn/office"
  printf 'client\nca ca.crt\n' >"$HOME/vpn/office/office.ovpn"
  printf 'NAME=Office\nCONFIG=office/office.ovpn\n' >"$XDG_CONFIG_HOME/vpn-picker/profiles/office.conf"
  picker connect office </dev/null >/dev/null 2>&1
  assert_contains "$(log)" "openvpn argv: [--cd] [$HOME/vpn/office] [--config] [$HOME/vpn/office/office.ovpn]" "--cd to the config folder comes first"
  teardown
}

test_auth_nocache_warning() {
  setup auth_nocache
  printf 'client\n  auth-nocache\n' >"$HOME/vpn/nocache.ovpn"
  printf 'client\n# auth-nocache\n' >"$HOME/vpn/commented.ovpn"
  local p="$XDG_CONFIG_HOME/vpn-picker/profiles"
  printf 'NAME="No Cache"\nCONFIG=nocache.ovpn\nUSERNAME=jdoe\nOTP_OP=op://Private/Example VPN/otp?attrtype=otp\n' >"$p/nocache.conf"
  printf 'NAME="Args"\nCONFIG=commented.ovpn\nUSERNAME=jdoe\nOTP_OP=op://Private/Example VPN/otp?attrtype=otp\nOPENVPN_ARGS=--verb 3 --auth-nocache\n' >"$p/args.conf"
  printf 'NAME="Fine"\nCONFIG=commented.ovpn\nUSERNAME=jdoe\nOTP_OP=op://Private/Example VPN/otp?attrtype=otp\n' >"$p/fine.conf"
  local err
  err=$(picker connect nocache </dev/null 2>&1 >/dev/null)
  assert_contains "$err" "No Cache uses auth-nocache" "connect warns about auth-nocache in the .ovpn"
  assert_contains "$(log)" "notify:VPN Picker No Cache uses auth-nocache" "connect notifies about auth-nocache"
  assert_contains "$(log)" "openvpn argv" "connect still goes ahead"
  : >"$STUB_LOG"
  err=$(picker connect args </dev/null 2>&1 >/dev/null)
  assert_contains "$err" "Args uses auth-nocache" "connect warns about --auth-nocache in OPENVPN_ARGS"
  : >"$STUB_LOG"
  err=$(picker connect fine </dev/null 2>&1 >/dev/null)
  assert_not_contains "$err" "auth-nocache" "a commented-out auth-nocache is ignored"
  local out
  out=$(picker doctor 2>&1)
  assert_contains "$out" "warning: nocache uses auth-nocache" "doctor warns for the .ovpn"
  assert_contains "$out" "warning: args uses auth-nocache" "doctor warns for OPENVPN_ARGS"
  assert_not_contains "$out" "warning: fine" "doctor quiet for a clean profile"
  : >"$STUB_LOG"
  err=$(picker connect nocache.ovpn </dev/null 2>&1 >/dev/null)
  assert_not_contains "$err" "auth-nocache" "no warning when OpenVPN asks for credentials itself"
  teardown
}

test_not_started_message() {
  setup not_started
  : >"$HOME/vpn/example.ovpn"
  printf 'NAME=Example\nCONFIG=example.ovpn\nUSERNAME=jdoe\nPASSWORD_MODE=otp\n' >"$XDG_CONFIG_HOME/vpn-picker/profiles/example.conf"
  printf '\n' | picker connect example >/dev/null 2>&1
  assert_eq "$?" 1 "empty OTP cancels"
  assert_contains "$(log)" "notify:VPN Picker Not connected: Example (no credentials were given)" "cancelled OTP explained"
  assert_not_contains "$(log)" "OpenVPN exited" "no OpenVPN exit message when it never ran"
  : >"$STUB_LOG"
  stub sudo 'case "$1" in -v) exit 1 ;; -n) exit 1 ;; esac; exec "$@"'
  picker connect example </dev/null >/dev/null 2>&1
  assert_contains "$(log)" "notify:VPN Picker Not connected: Example (sudo was cancelled or failed)" "cancelled sudo explained"
  assert_not_contains "$(log)" "openvpn argv" "openvpn not started after sudo fails"
  : >"$STUB_LOG"
  make_stubs
  printf 'NAME=Example\nCONFIG=example.ovpn\nUSERNAME=jdoe\nOTP_OP=op://Private/Example VPN/otp?attrtype=otp\n' >"$XDG_CONFIG_HOME/vpn-picker/profiles/example.conf"
  OPENVPN_EXIT=1 picker connect example </dev/null >/dev/null 2>&1
  assert_contains "$(log)" "notify:VPN Picker OpenVPN exited (1): Example" "real OpenVPN exit still reported"
  teardown
}

test_status() {
  setup status
  local out
  rm -f "$VPN_PICKER_STATE_FILE"
  out=$(picker status --json)
  [[ -e $VPN_PICKER_STATE_FILE ]] && ok || bad "status creates a missing state file"
  printf 'keep\n' >"$VPN_PICKER_STATE_FILE"
  touch -d '2020-01-01' "$VPN_PICKER_STATE_FILE"
  picker status >/dev/null
  assert_eq "$(cat "$VPN_PICKER_STATE_FILE")" "keep" "status leaves an existing state file alone"
  assert_eq "$(stat -c %Y "$VPN_PICKER_STATE_FILE")" "$(date -d '2020-01-01' +%s)" "status does not touch an existing state file"
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
  assert_contains "$l" "openvpn argv: [--cd] [$HOME/vpn] [--config] [$HOME/vpn/plain.ovpn]" "openvpn started from menu"
  : >"$STUB_LOG"
  NM_ACTIVE="vpn:Office" MENU_CHOICE="Disconnect Office" picker menu </dev/null >/dev/null 2>&1
  assert_contains "$(log)" "nmcli down:Office" "disconnect NM from menu"
  : >"$STUB_LOG"
  rm -f "$VPN_PICKER_STATE_FILE"
  NM_ACTIVE="vpn:Office" MENU_CHOICE="Disconnect Office" picker menu </dev/null >/dev/null 2>&1
  [[ -s $VPN_PICKER_STATE_FILE ]] && ok || bad "state file touched after disconnect"
  : >"$STUB_LOG"
  MENU_CHOICE="" picker menu </dev/null >/dev/null 2>&1
  assert_eq "$(log)" "" "cancel does nothing"
  teardown
}

test_menu_rows_unique() {
  setup menu_unique
  export VPN_PICKER_MENU=walker
  local p="$XDG_CONFIG_HOME/vpn-picker/profiles"
  : >"$HOME/vpn/a.ovpn"
  : >"$HOME/vpn/b.ovpn"
  printf 'NAME="Status: not connected"\nCONFIG=a.ovpn\n' >"$p/a.conf"
  printf 'NAME="Disconnect Office"\nCONFIG=b.ovpn\n' >"$p/b.conf"
  MENU_CHOICE="Status: not connected [2]" picker menu </dev/null >/dev/null 2>&1
  assert_contains "$(cat "$STUB_LOG.menu")" "Status: not connected"$'\n'"Status: not connected [2]" "entry label colliding with the status row gets a suffix"
  assert_contains "$(log)" "__terminal-connect profile:a" "suffixed entry connects"
  : >"$STUB_LOG"
  NM_ACTIVE="vpn:Office" MENU_CHOICE="Disconnect Office [2]" picker menu </dev/null >/dev/null 2>&1
  assert_contains "$(log)" "__terminal-connect profile:b" "entry named like a Disconnect row connects, not disconnects"
  assert_not_contains "$(log)" "nmcli down" "Disconnect row not triggered by the look-alike entry"
  : >"$STUB_LOG"
  NM_ACTIVE="vpn:Office" MENU_CHOICE="Disconnect Office" picker menu </dev/null >/dev/null 2>&1
  assert_contains "$(log)" "nmcli down:Office" "real Disconnect row still disconnects"
  # Two OpenVPN tunnels from the same config: one Disconnect row per process.
  mkdir -p "$T/proc/11" "$T/proc/12"
  printf 'openvpn\0--config\0%s\0' "$HOME/vpn/a.ovpn" >"$T/proc/11/cmdline"
  printf 'openvpn\0--config\0%s\0' "$HOME/vpn/a.ovpn" >"$T/proc/12/cmdline"
  printf 'openvpn\n' >"$T/proc/11/comm"
  printf 'openvpn\n' >"$T/proc/12/comm"
  stub kill 'printf "kill:%s\n" "$*" >>"$STUB_LOG"; rm -rf "$VPN_PICKER_PROC_DIR/$2"'
  : >"$STUB_LOG"
  PGREP_PIDS="11 12" MENU_CHOICE="Disconnect Status: not connected (pid 12)" picker menu </dev/null >/dev/null 2>&1
  assert_contains "$(cat "$STUB_LOG.menu")" "Disconnect Status: not connected (pid 11)"$'\n'"Disconnect Status: not connected (pid 12)" "OpenVPN Disconnect rows name the pid"
  assert_contains "$(log)" "kill:-TERM 12" "the chosen tunnel is the one stopped"
  assert_not_contains "$(log)" "kill:-TERM 11" "the other tunnel keeps running"
  teardown
}

test_menu_program_missing() {
  setup menu_missing
  : >"$HOME/vpn/plain.ovpn"
  local err
  err=$(VPN_PICKER_MENU=no-such-menu picker menu 2>&1 </dev/null)
  assert_eq "$?" 1 "missing menu program exits non-zero"
  assert_contains "$err" "menu program not found: no-such-menu" "missing menu reported"
  assert_contains "$(log)" "notify:VPN Picker No menu program found" "missing menu notified"
  printf 'MENU="no-such-menu --dmenu"\n' >"$XDG_CONFIG_HOME/vpn-picker/config"
  assert_contains "$(picker doctor 2>&1)" "missing: a menu program" "doctor reports the missing menu"
  teardown
}

test_disconnect_pid_guard() {
  setup disconnect_pid
  mkdir -p "$T/proc/99"
  printf 'bash\n' >"$T/proc/99/comm"
  picker disconnect pid:99 >/dev/null 2>&1
  assert_eq "$?" 1 "refuses to kill non-openvpn pid"
  stub kill 'printf "kill:%s\n" "$*" >>"$STUB_LOG"; rm -rf "$VPN_PICKER_PROC_DIR/$2"'
  printf 'openvpn\n' >"$T/proc/99/comm"
  picker disconnect pid:99 >/dev/null 2>&1
  assert_contains "$(log)" "kill:-TERM 99" "kills openvpn pid via sudo"
  [[ -s $VPN_PICKER_STATE_FILE ]] && ok || bad "state file touched after openvpn exits"
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
  picker connect "ovpn:.." </dev/null >/dev/null 2>&1
  assert_eq "$?" 1 "bare .. refused"
  : >"$HOME/vpn/office..udp.ovpn"
  picker connect "ovpn:office..udp.ovpn" </dev/null >/dev/null 2>&1
  assert_eq "$?" 0 "'..' inside a file name is allowed"
  assert_contains "$(log)" "[--config] [$HOME/vpn/office..udp.ovpn]" "file with '..' in its name connects"
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
  local err
  err=$(picker add "$T/Download.ovpn" --name $'Evil\nPASSWORD_MODE=none' 2>&1)
  assert_eq "$?" 1 "name with a line break refused"
  assert_contains "$err" "control characters" "line break explained"
  picker add "$T/Download.ovpn" --name 'Evil" OTP_OP="x' >/dev/null 2>&1
  assert_eq "$?" 1 "name with a double quote refused"
  printf 'client\n' >"$T/bad\"name.ovpn"
  picker add "$T/bad\"name.ovpn" --name "Fine Name" >/dev/null 2>&1
  assert_eq "$?" 1 "file name with a double quote refused"
  assert_eq "$(find "$XDG_CONFIG_HOME/vpn-picker/profiles" -name 'evil*' | wc -l)" "0" "no profile written for a refused name"
  printf 'client\n' >"$T/Other.ovpn"
  picker add "$T/Other.ovpn" --name "O'Brien VPN" >/dev/null 2>&1
  assert_eq "$?" 0 "single quote allowed"
  # shellcheck source=/dev/null
  (source "$PICKER"; vp_load_global_config; vp_load_profile "$XDG_CONFIG_HOME/vpn-picker/profiles/o-brien-vpn.conf"; printf '%s' "${PROFILE[NAME]}") >"$T/name"
  assert_eq "$(cat "$T/name")" "O'Brien VPN" "single quote kept in NAME"
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
  printf 'NAME=mine\n' >"$XDG_CONFIG_HOME/vpn-picker/profiles/example.conf.sample"
  "$ROOT/install.sh" >/dev/null
  assert_eq "$(cat "$XDG_CONFIG_HOME/vpn-picker/config")" "VPN_DIR=~/keep" "reinstall keeps config"
  assert_eq "$(cat "$XDG_CONFIG_HOME/vpn-picker/profiles/example.conf.sample")" "NAME=mine" "reinstall keeps the sample profile"
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

# Used by test_harness_counts_early_exit: a test that dies before reporting.
selfcheck_exits_early() {
  setup selfcheck
  ok
  exit 3
}

test_harness_counts_early_exit() {
  CURRENT=harness
  local out results
  results=$(mktemp)
  out=$(
    run_tests "$results" selfcheck_exits_early 2>&1
    echo "rc=$?"
  )
  rm -f "$results"
  assert_contains "$out" "0 passed, 1 failed" "early exit counted as a failure"
  assert_contains "$out" "exited early (status 3)" "early exit explained"
  assert_contains "$out" "rc=1" "early exit fails the run"
}

# Each test runs in a subshell (it sources the picker and changes HOME), so
# results are reported through a file. A test that exits before reporting,
# or whose subshell fails, counts as a failure.
#   run_tests <results-file> <test-function>...
run_tests() {
  local results=$1 t rc before after
  shift
  for t in "$@"; do
    before=$(wc -l <"$results")
    (
      PASS=0
      FAIL=0
      trap '[[ -n ${T:-} ]] && rm -rf "$T"' EXIT
      "$t"
      printf '%s %s\n' "$PASS" "$FAIL" >>"$results"
    )
    rc=$?
    after=$(wc -l <"$results")
    if ((rc != 0 || after == before)); then
      printf 'FAIL [%s] test exited early (status %d) before reporting its results\n' "$t" "$rc" >&2
      printf '0 1\n' >>"$results"
    fi
  done
  local p=0 f=0 a b
  while read -r a b; do
    p=$((p + a))
    f=$((f + b))
  done <"$results"
  printf '%d passed, %d failed\n' "$p" "$f"
  if ((p + f == 0)); then
    echo "FAIL no test results were recorded" >&2
    return 1
  fi
  ((f == 0))
}

RESULTS=$(mktemp)
trap 'rm -f "$RESULTS"' EXIT
mapfile -t ALL_TESTS < <(declare -F | awk '$3 ~ /^test_/ {print $3}')
if ((${#ALL_TESTS[@]} == 0)); then
  echo "FAIL no test_ functions were found" >&2
  exit 1
fi
run_tests "$RESULTS" "${ALL_TESTS[@]}"
