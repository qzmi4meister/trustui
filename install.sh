#!/bin/bash
# Build a local Homebrew tap and install the cask from this checkout.
set -euo pipefail
cd "$(dirname "$0")"
command -v brew >/dev/null || { echo "Homebrew is required: https://brew.sh"; exit 1; }
bash build.sh
TAP_DIR="$(pwd)/build/homebrew-trustui"
ARCHIVE="$(pwd)/dist/TrustUI-0.1.0-$(uname -m).zip"
mkdir -p "$TAP_DIR/Casks"
/usr/bin/ruby -ruri -rdigest -rpathname - "$ARCHIVE" "$TAP_DIR/Casks/trustui.rb" <<'RUBY'
archive, output = ARGV
url = URI::Generic.build(scheme: "file", path: URI::DEFAULT_PARSER.escape(archive)).to_s
File.write(output, <<~CASK)
  cask "trustui" do
    version "0.1.0"
    sha256 "#{Digest::SHA256.file(archive).hexdigest}"

    url "#{url}"
    name "TrustUI"
    desc "Native macOS interface for the local TrustTunnel CLI"
    homepage "https://github.com/qzmi4meister/trustui"

    depends_on macos: ">= :sonoma"
    depends_on formula: "python@3.12"

    app "TrustUI.app"
  end
CASK
RUBY
git -C "$TAP_DIR" init -q
git -C "$TAP_DIR" add Casks/trustui.rb
if ! git -C "$TAP_DIR" diff --cached --quiet; then
    git -C "$TAP_DIR" -c user.name="TrustUI Build" -c user.email="build@trustui.local" \
        commit -qm "build: package TrustUI 0.1.0"
fi
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1
if brew tap | /usr/bin/grep -qx 'trustui/local'; then
    INSTALLED_TAP="$(brew --repository trustui/local)"
    if [ "$(git -C "$INSTALLED_TAP" remote get-url origin)" != "$TAP_DIR" ]; then
        echo "trustui/local points to another checkout; leaving it unchanged."
        exit 1
    fi
    git -C "$INSTALLED_TAP" pull --ff-only
else
    brew tap trustui/local "$TAP_DIR"
fi
# This cask contains only the app just built from this checkout, signed ad hoc.
# Keep this exception local to TrustUI; public releases need Apple notarization.
if brew list --cask trustui/local/trustui >/dev/null 2>&1; then
    brew reinstall --cask --no-quarantine trustui/local/trustui
else
    brew install --cask --no-quarantine trustui/local/trustui
fi
