# omarchy-vpn-picker

A VPN picker for [Omarchy](https://omarchy.org): a bar icon that shows whether
a VPN is up, and a menu to connect or disconnect one.

- **No setup for plain configs.** Every `*.ovpn` file in `~/vpn` shows up in
  the menu.
- **Drop-in profiles.** One small file per VPN in
  `~/.config/vpn-picker/profiles/` adds a display name, a NetworkManager
  connection, and where the credentials come from.
- **1Password fill.** A profile can read the username, password, and
  one-time password (OTP) from 1Password through the `op` CLI. A VPN that wants
  a fresh OTP at every login connects without opening the 1Password app.
- **Credentials stay off disk.** They are never written to a file and never put
  on a command line. OpenVPN reads them from a pipe; NetworkManager reads them
  from a process-substitution file descriptor.

It ships as an Omarchy bar-widget plugin, and there is a plain installer for an
app-launcher entry on its own.

## Requirements

- `openvpn` and `sudo` for `.ovpn` configs, and/or NetworkManager (`nmcli`)
  for NM VPN connections
- A menu: Omarchy's own menu (used automatically), or `walker`, `fuzzel`,
  `rofi`, or `wofi`. Without one, the picker shows a notification and exits
  with an error (`omarchy-vpn-picker doctor` reports it too).
- `xdg-terminal-exec` (Omarchy has it) or another terminal. Connecting
  happens in a terminal window so you can answer `sudo` and see OpenVPN's log.
- Optional: the [1Password CLI](https://developer.1password.com/docs/cli/) (`op`)

## Install

### As an Omarchy plugin (bar icon)

```sh
omarchy plugin add https://github.com/danwize/omarchy-vpn-picker --enable
```

This puts a VPN icon in the bar. The icon is dimmed while nothing is
connected. Left-click opens the picker, right-click shows the status, and
middle-click refreshes. The icon updates as soon as a connect or disconnect
finishes (the picker touches `$XDG_RUNTIME_DIR/omarchy-vpn-picker.changed`,
which the widget watches), and otherwise on a timer. In the widget settings
you can change the refresh interval or hide the icon while disconnected.

To also get a "VPN Picker" entry in the app launcher, run the installer from
the plugin folder:

```sh
~/.config/omarchy/plugins/io.github.danwize.vpn-picker/install.sh
```

Remove the plugin with `omarchy plugin remove io.github.danwize.vpn-picker`.

### Without the plugin system

```sh
git clone https://github.com/danwize/omarchy-vpn-picker
./omarchy-vpn-picker/install.sh
```

The installer:

- copies the picker to `~/.local/bin/omarchy-vpn-picker`;
- adds `~/.local/share/applications/omarchy-vpn-picker.desktop`, which shows
  up as "VPN Picker" in the app launcher;
- creates `~/.config/vpn-picker/config` and a sample profile
  (`profiles/example.conf.sample`). It never overwrites a file you already
  have, including an edited sample.

Run `./install.sh` again to update. `./install.sh --uninstall` removes the
script and the launcher entry and leaves your config and VPN files alone.

### Keyboard shortcut (optional)

Add a binding to `~/.config/hypr/bindings.conf`, for example:

```
bindd = SUPER ALT, V, VPN picker, exec, omarchy-vpn-picker
```

If you only installed the plugin, use the full path
`~/.config/omarchy/plugins/io.github.danwize.vpn-picker/bin/omarchy-vpn-picker`.

## Adding a VPN

**Simplest:** drop the provider's `.ovpn` file into `~/vpn`. It appears in the
menu under its file name. If a NetworkManager VPN or WireGuard connection
has the same name as the file (ignoring case), the picker connects through
NetworkManager instead; Wi-Fi and wired connections never match. OpenVPN
starts in the config file's folder, so relative `ca`, `cert`, `key`, and
`tls-auth` paths inside it work.
`~/vpn` may be a symlink, and symlinked subfolders, `.ovpn` files, and
profiles are followed.

**With a profile:** let the picker copy the file and write a profile for it:

```sh
omarchy-vpn-picker add ~/Downloads/example.ovpn --name "Example VPN"
```

That copies the file into `~/vpn` with mode 600 and creates
`~/.config/vpn-picker/profiles/example-vpn.conf`. The name and the file name
may not contain double quotes or control characters such as line breaks. Edit the profile to add
credentials. You can also write profiles by hand; see
[`examples/profiles/example.conf`](examples/profiles/example.conf).

A profile for a VPN that takes a fixed username and an OTP as the password:

```ini
NAME="Example VPN"
CONFIG="example.ovpn"
USERNAME="your-username"
OTP_OP="op://Private/Example VPN/one-time password?attrtype=otp"
```

A NetworkManager connection whose password is a password and an OTP joined
together:

```ini
NAME="Office"
CONNECTION="Office VPN"
PASSWORD_OP="op://Private/Office VPN/password"
OTP_OP="op://Private/Office VPN/one-time password?attrtype=otp"
PASSWORD_MODE=password+otp
```

Profiles and the config file are plain `KEY=value` lines. They are parsed,
never executed. Quotes around a value are optional and are taken literally.
Lines starting with `#` are comments, and so is anything after whitespace
and `#` following a value (`CONFIG=work.ovpn  # office`), or after
whitespace following `=` (`OTP_SEPARATOR= # none` sets an empty value, while
`OTP_SEPARATOR=#` is a literal `#`). Quote a value that itself contains ` #`.

### Profile keys

| Key | Meaning |
|-----|---------|
| `NAME` | Label in the menu. Defaults to the file name. |
| `CONFIG` | OpenVPN config. A relative path is looked up in `VPN_DIR`. |
| `CONNECTION` | NetworkManager connection name, used instead of `CONFIG`. |
| `TYPE` | `openvpn` or `nm`. Inferred from `CONFIG` / `CONNECTION`. |
| `USERNAME` | Fixed username (OpenVPN only). |
| `USERNAME_OP` | 1Password reference for the username (OpenVPN only). |
| `PASSWORD_OP` | 1Password reference for the password. |
| `OTP_OP` | 1Password reference for the one-time password. |
| `PASSWORD_MODE` | What is sent as the password. `none` sends nothing and OpenVPN prompts itself. `password` sends the password. `otp` sends the OTP alone. `password+otp` sends the password, then `OTP_SEPARATOR`, then the OTP. |
| `OTP_SEPARATOR` | Text between password and OTP in `password+otp`. Defaults to nothing. |
| `OP_ACCOUNT` | 1Password account for `op --account`, if you have several. |
| `OPENVPN_ARGS` | Extra OpenVPN arguments, split on spaces, e.g. `--verb 3`. Do not use `--auth-nocache` (here or in the `.ovpn` file) with picker-supplied credentials: they are sent once on stdin, so OpenVPN cannot answer the next renegotiation and the tunnel drops. `doctor` warns about it, and so does a notification when you connect. |
| `NM_SECRET_KEY` | NetworkManager secret that receives the password. Defaults to `vpn.secrets.password`. |

When `PASSWORD_MODE` is unset, it is inferred:

| Set in the profile | Inferred mode |
|--------------------|---------------|
| `PASSWORD_OP` and `OTP_OP` | `password+otp` |
| `OTP_OP` only | `otp` |
| `PASSWORD_OP` or a username | `password` |
| nothing | `none` |

A value with no 1Password reference is asked for in the terminal. For example,
`PASSWORD_MODE=otp` without `OTP_OP` prompts for the code.

The OTP is always fetched last, after `sudo` has its password, so the code is
as fresh as possible when OpenVPN sends it. If `sudo` would not ask (a cached
login, or a `NOPASSWD` sudoers rule for `openvpn`), there is no password
prompt at all.

### Global settings

`~/.config/vpn-picker/config` (see [`examples/config`](examples/config)):

| Key | Default | Meaning |
|-----|---------|---------|
| `VPN_DIR` | `~/vpn` | Folder scanned (recursively) for `*.ovpn`. |
| `MENU` | `auto` | `omarchy`, `walker`, `fuzzel`, `rofi`, `wofi`, or any dmenu-style command. |
| `TERMINAL` | `auto` | Terminal command for connecting, e.g. `alacritty -e`. |
| `OP_ACCOUNT` | | Default 1Password account. |
| `OPENVPN_ARGS` | | Extra arguments for every OpenVPN connection. |

The environment variables `VPN_PICKER_CONFIG_DIR`, `VPN_PICKER_VPN_DIR`,
`VPN_PICKER_MENU`, and `VPN_PICKER_TERMINAL` override these settings.

## 1Password setup

1. Install the 1Password desktop app and CLI. On Omarchy,
   `omarchy-install-service-1password` installs both (packages `1password` and
   `1password-cli`).
2. In the desktop app, open **Settings → Developer** and turn on
   **Integrate with 1Password CLI**. `op` then unlocks with the app (system
   authentication or fingerprint), with no `op signin` and no stored session
   token.
3. Find the secret references. In 1Password, open the item, click the arrow
   next to a field, and choose **Copy Secret Reference**. References look like
   `op://<vault>/<item>/<field>`. For the item's one-time password, add
   `?attrtype=otp` to get the current code:

   ```sh
   op read "op://Private/Example VPN/one-time password?attrtype=otp"
   ```

4. Put the references in the profile (`USERNAME_OP`, `PASSWORD_OP`, `OTP_OP`).

If `op` is missing, locked, or the lookup fails, the picker says so and asks
for the value in the terminal instead. A broken 1Password setup never blocks
you from connecting.

## Commands

```
omarchy-vpn-picker                 show the menu
omarchy-vpn-picker connect <name>  connect in the current terminal (profile id or file under VPN_DIR)
omarchy-vpn-picker disconnect      disconnect everything (or nm:<name> / pid:<pid>)
omarchy-vpn-picker status [--json] show active VPNs
omarchy-vpn-picker list            list menu entries
omarchy-vpn-picker add <file.ovpn> [--name "Display Name"]
omarchy-vpn-picker doctor          check dependencies and profiles
```

## How credentials are handled

- OpenVPN runs as
  `sudo openvpn --cd <config folder> --config <file> --auth-user-pass /dev/stdin`.
  The username and password go into that pipe through the shell's `printf`
  builtin, so they never show up in a process list and never touch disk.
- For NetworkManager, the password goes to
  `nmcli connection up ... passwd-file <(...)`. That is a pipe file
  descriptor, not a file.
- Secrets live only in shell variables for the length of the connect step,
  and are cleared right after.
- Profiles hold 1Password references, not secrets. Don't put real passwords in
  them. `omarchy-vpn-picker add` creates profiles and copied configs with mode
  600.

Limitations:

- Servers that use OpenVPN's `static-challenge` still have OpenVPN ask for the
  challenge answer in the terminal.
- OpenVPN keeps running in its terminal window. Closing the window or
  pressing Ctrl+C disconnects, and so does "Disconnect" in the menu.
- OpenVPN gets the credentials once, at connect time. If the tunnel restarts
  on its own (ping-restart, network change), the cached one-time password has
  expired and the reconnect fails; reconnect from the menu.

## Development

```sh
tests/ci.sh                                    # everything CI runs (below)
tests/run.sh                                   # stubbed tests, no root, no network
shellcheck -x bin/omarchy-vpn-picker install.sh tests/run.sh tests/ci.sh
omarchy plugin validate .                      # on an Omarchy machine
```

The tests run against a temporary `HOME`, with stub `nmcli`, `openvpn`,
`sudo`, `op`, menu, and terminal programs. `tests/ci.sh` also needs `jq`, so
the manifest and JSON checks are never skipped. Off Omarchy (for example on
the Ubuntu Actions runner), `omarchy-plugin-validate` is missing, so that one
check is skipped and `tests/ci.sh` says so.

The GitHub Actions workflow (`.github/workflows/ci.yml`) only calls
`tests/ci.sh`. If the Actions job reports that it "was not started" (for
example, because the account is locked over billing), nothing in the code was
checked. Run `tests/ci.sh` locally and treat its result as the CI result.

## License

MIT. See [LICENSE](LICENSE).
