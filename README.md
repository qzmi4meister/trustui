# TrustUI

A native macOS interface for the [TrustTunnel CLI](https://github.com/TrustTunnel/TrustTunnelClient). Choose a server, edit its configuration, start or stop the client, and read its logs from one window or the menu bar.

TrustUI is an independent project. It requires a separately installed TrustTunnel CLI and access to a configured TrustTunnel server. It does not provide a VPN service or bundle the CLI.

## Features

- Server profiles loaded from local TOML files.
- Connection settings, routing exclusions, kill switch, and DNS configuration.
- Start and stop through the macOS administrator prompt.
- Process status, PID, start time, and live CLI logs.
- Atomic configuration saves, timestamped backups, and protection against overwriting external edits.
- English and Russian interfaces with an instant, persistent language switch.
- An offline **Guide** with installation commands, official links, setup steps, and troubleshooting.

## Requirements

- macOS 14 Sonoma or later.
- [Homebrew](https://brew.sh).
- Python 3.12, installed automatically by the Homebrew cask.
- The TrustTunnel CLI, a full client configuration, and server credentials.

The release is a universal app for Apple Silicon and Intel Macs. Local validation has been performed on Apple Silicon with TrustTunnel CLI **1.0.31**. Compatibility with other CLI versions is not yet verified. The DNS editor writes the legacy top-level `dns_upstreams` setting; newer configurations may also define `[endpoint].dns_upstreams`.

## Install TrustUI through Homebrew

```sh
brew install --cask qzmi4meister/tap/trustui
open -a TrustUI
```

Homebrew adds the [public tap](https://github.com/qzmi4meister/homebrew-tap), downloads the app from [GitHub Releases](https://github.com/qzmi4meister/trustui/releases), verifies its SHA-256 checksum, and installs it in `/Applications`. No source checkout or Swift compiler is needed. Install the TrustTunnel CLI separately using the steps below.

You can also add the tap once and use the short cask name:

```sh
brew tap qzmi4meister/tap
brew install --cask trustui
```

TrustUI is distributed through this project's tap, not the official Homebrew Cask repository.

### First launch and Gatekeeper

This release has an ad hoc signature and is **not notarized by Apple**. If macOS blocks the first launch, and you trust this release, open **System Settings → Privacy & Security → Open Anyway** after attempting to open the app. See [Apple's instructions](https://support.apple.com/en-us/102445).

The public cask does not remove quarantine or change Gatekeeper settings. A release that passes Apple's developer verification requires Developer ID signing and notarization.

## Set up the TrustTunnel CLI

If you already have a working CLI installation and `trusttunnel_client.toml`, keep them and proceed to [Connect](#connect).

### 1. Install the CLI

Download the [official installer](https://github.com/TrustTunnel/TrustTunnelClient/blob/master/scripts/install.sh) into the default CLI directory, then run it:

```sh
mkdir -p "$HOME/trusttunnel"
curl -fsSL https://raw.githubusercontent.com/TrustTunnel/TrustTunnelClient/refs/heads/master/scripts/install.sh -o "$HOME/trusttunnel/install-client.sh"
sh "$HOME/trusttunnel/install-client.sh" -o "$HOME/trusttunnel"
"$HOME/trusttunnel/trusttunnel_client" --version
```

The upstream installer selects its release independently of TrustUI. Check the version against the compatibility note above. See the official [installation instructions](https://github.com/TrustTunnel/TrustTunnel#install-the-client), [CLI releases](https://github.com/TrustTunnel/TrustTunnelClient/releases), and [release verification guide](https://github.com/TrustTunnel/TrustTunnelClient/blob/master/VERIFY_RELEASES.md).

### 2. Prepare a client configuration

Obtain an endpoint configuration from your server administrator, or follow the official [server setup instructions](https://github.com/TrustTunnel/TrustTunnel#endpoint-setup). Save the exported configuration as `~/trusttunnel/endpoint.toml`, then generate the full client configuration:

```sh
cd "$HOME/trusttunnel"
test ! -e trusttunnel_client.toml &&
./setup_wizard --mode non-interactive --endpoint_config endpoint.toml --settings trusttunnel_client.toml &&
chmod 600 endpoint.toml trusttunnel_client.toml
```

The guard prevents overwriting an existing configuration. An exported endpoint file alone is not a full client configuration: TrustUI needs `trusttunnel_client.toml` with endpoint and TUN listener settings.

If you have server details instead of an exported file, run the interactive wizard:

```sh
cd "$HOME/trusttunnel"
./setup_wizard
```

Provide the server address, TLS hostname, VPN credentials, and any certificate supplied by the administrator. Save the complete configuration as `trusttunnel_client.toml` and select TUN mode for use with TrustUI. See the [official configuration reference](https://github.com/TrustTunnel/TrustTunnelClient/blob/master/trusttunnel/README.md).

## Connect

1. Open TrustUI. Its default CLI folder is `~/trusttunnel`; choose another folder under **Application** if needed. It must contain `trusttunnel_client` and `trusttunnel_client.toml`.
2. Click **Reload**. Under **Connection**, select a server profile or edit the current endpoint. Additional `*.toml` files in the CLI folder populate the profile list.
3. Review **Routing** for VPN mode, exclusions, kill switch, and DNS settings.
4. Click **Start** (or **Save and start** if you changed settings). Approve the macOS administrator prompt using your Mac account, not your VPN credentials.
5. Inspect **Logs**, then check access to a site that should use the tunnel and verify the expected public IP address.

**“Client is running” confirms that the process exists. It does not prove that the tunnel connected or that traffic uses the VPN.**

If another TrustTunnel client is already running, stop it using the method that started it before connecting through TrustUI. The app prevents duplicate launches and only stops its own session, checking the PID, process start identity, and command.

The **Guide** is available in the sidebar, Help menu, and menu bar. It opens automatically when the CLI or configuration is missing. Its command buttons only copy text; they do not run installers. Choose **English** or **Русский** at the bottom of the sidebar to change the interface and guide language.

### Routing and DNS

In `general` mode, exclusions bypass the tunnel. In `selective` mode, only exclusions use the tunnel. TrustUI edits one local list; it does not fetch address lists from URLs or provide rule priorities. Check the CLI configuration reference for supported domain, wildcard, IP, and subnet matching.

For DNS over HTTPS, an example resolver URL is `https://cloudflare-dns.com/dns-query`. Enter one resolver per line in the DNS field. DNS behavior depends on your CLI version and configuration; see Requirements and the [CLI configuration reference](https://github.com/TrustTunnel/TrustTunnelClient/blob/master/trusttunnel/README.md).

### Everyday use

- Save changed settings, then stop and start the client to apply them.
- Stop the client before changing its folder; folder selection is disabled while it runs.
- Closing the window or quitting TrustUI leaves the client running. Reopening the app restores its session status.
- Automatic connection after restarting macOS is not implemented.

## Configuration and local data

TrustUI uses your home directory and the selected CLI folder. No developer-specific absolute paths are required. Python is located in standard Apple Silicon or Intel Homebrew locations.

| Location | Contents |
| --- | --- |
| Selected CLI folder | CLI binary, main configuration, and server profiles |
| Beside the main configuration | Timestamped `.bak` copies created before saves |
| `~/Library/Application Support/TrustUI/` | Session configuration snapshot, process metadata, and logs |
| macOS user preferences | Selected CLI directory and interface language |

Saves preserve unknown TOML fields but rewrite formatting. Original comments and formatting remain in the backup. If another application edits the file, TrustUI refuses to save a stale form over it.

Passwords remain in TOML files. Configurations, snapshots, and backups created by TrustUI have `0600` permissions. Existing server profile files are left unchanged. To restore a backup, stop the client, replace `trusttunnel_client.toml` with the chosen `.bak` file, and reload.

The UI masks the current session's username and password in the displayed log. Raw logs on disk can contain sensitive data; review and redact them before sharing. The UI reads the last 48 KB. Starting a new session moves the previous log to `client.previous.log`, replacing the older one. There is no size limit within a session; prefer `info` logging for long sessions.

## Update or uninstall

Install the latest published version:

```sh
brew update
brew upgrade --cask qzmi4meister/tap/trustui
```

Quit and reopen TrustUI to load the updated interface. The TrustTunnel CLI is updated separately.

To uninstall, stop the client in TrustUI first, then run:

```sh
brew uninstall --cask qzmi4meister/tap/trustui
brew untap qzmi4meister/tap
```

Uninstalling the app does not stop a running tunnel or remove CLI configurations, backups, or session data.

## Development

The app uses SwiftUI and AppKit with a Python standard-library bridge. There is no local web server or third-party UI framework. The UI runs as the current user; start and stop operations request administrator privileges through `osascript`.

Install Xcode Command Line Tools (`xcode-select --install`), then:

```sh
git clone https://github.com/qzmi4meister/trustui.git
cd trustui
brew install python@3.12
python3.12 -m unittest discover -s tests -v
bash build.sh
open build/TrustUI.app
```

The build produces `dist/TrustUI-0.1.0-universal.zip` with both architectures and checks the bundle signature. Intel runtime behavior still needs testing on an Intel Mac.

For local development, `bash install.sh` builds and installs through a separate `trustui/local` tap. Its cask refers to an archive in this checkout, so keep the directory in place. It uses Homebrew's deprecated `--no-quarantine` option only for that local build. Uninstall the public cask before switching to the local one. To update a source build, run `git pull --ff-only` and `bash install.sh` again.

Tests cover configuration preservation, external-edit conflicts, private backups, credential masking, process ownership checks, fake-client lifecycle, and localization. They use temporary files and a fake client, without connecting a VPN or changing system routes.

| Path | Purpose |
| --- | --- |
| `Sources/TrustUI.swift` | App, forms, process bridge, and menu bar |
| `Sources/GuideView.swift` | Built-in setup guide and copyable commands |
| `Sources/Localization.swift` | Language selection and localized string lookup |
| `Sources/backend.py` | TOML, backups, logs, and client lifecycle |
| `Resources/` | English and Russian translations |
| `tests/` | Backend and localization checks |
| `build.sh`, `install.sh` | App packaging and local Homebrew installation |

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for checks and what to include in a bug report.

## License

TrustUI is available under the [MIT License](LICENSE). The separately installed TrustTunnel CLI and server retain their own licenses. TrustUI is not affiliated with or endorsed by the TrustTunnel project.
