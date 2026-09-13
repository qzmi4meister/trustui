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

## Publishing a release

1. Update the version and bundle build number in `build.sh`, and the matching version and archive name in `install.sh`. Update the archive name in the README.
2. Run the checks above. `build.sh` compiles both architectures, includes the license, verifies the app signature, and creates `dist/TrustUI-<version>-universal.zip`.
3. Commit and push the source. Create a GitHub release with a matching `v<version>` tag at that commit, attach the universal ZIP, and describe the changes and signing status in English.
4. Calculate the archive's SHA-256 with `shasum -a 256 dist/TrustUI-<version>-universal.zip`. Update the version and checksum in `Casks/trustui.rb` in [homebrew-tap](https://github.com/qzmi4meister/homebrew-tap), then commit and push it.
5. Run `brew update` and `brew fetch --cask qzmi4meister/tap/trustui` to verify the published download. Test installing on a Mac without an existing TrustUI cask.

Published release archives must remain unchanged. If a binary needs fixing, publish a new version and checksum. Ad hoc signing does not provide Apple notarization; keep the first-launch instructions until Developer ID signing and notarization are available.
