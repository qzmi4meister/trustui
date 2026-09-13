# Contributing to TrustUI

Use English for issues, pull requests, and repository documentation. The app supports both English and Russian; include both translations when changing user-facing text.

## Local checks

On macOS 14 or later with Xcode Command Line Tools and Homebrew installed:

```sh
brew install python@3.12
python3.12 -m unittest discover -s tests -v
bash -n build.sh install.sh
bash build.sh
```

For UI changes, open `build/TrustUI.app` and check both languages. Keep changes focused and describe the behavior changed and the checks performed in your pull request.

## Bug reports

Include your macOS version, Mac architecture, TrustUI commit, CLI version, steps to reproduce, and expected and actual behavior. For connection problems, distinguish a running client process from a successfully connected tunnel.

Do not attach real TOML configurations, credentials, session snapshots, or unreviewed logs. Use a minimal configuration with synthetic values if needed. Log masking in the app does not sanitize the underlying log file.

The tests use a fake client and temporary directories. They do not require a working VPN server. Keep automated checks independent of personal profiles and live network routing.
