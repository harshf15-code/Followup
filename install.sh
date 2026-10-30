#!/bin/bash
# Installs (or updates) Followup from the latest GitHub release.
#   curl -fsSL https://raw.githubusercontent.com/harshf15-code/Followup/main/install.sh | bash
#   npx followup-mac   (or: npx github:harshf15-code/Followup)
set -euo pipefail

REPO="harshf15-code/Followup"
DEST="/Applications/Followup.app"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
fail() { printf '\033[31mError:\033[0m %s\n' "$1" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "Followup is a macOS app."
major=$(sw_vers -productVersion | cut -d. -f1)
(( major >= 14 )) || fail "Followup needs macOS 14 Sonoma or later (you have $(sw_vers -productVersion))."

bold "Finding the latest Followup release…"
url=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | grep -o '"browser_download_url": *"[^"]*\.dmg"' | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')
[[ -n "$url" ]] || fail "Couldn't find a DMG in the latest release of $REPO."

tmp=$(mktemp -d)
mnt="$tmp/mnt"
trap 'hdiutil detach "$mnt" -quiet 2>/dev/null || true; rm -rf "$tmp"' EXIT

bold "Downloading $(basename "$url")…"
curl -fL --progress-bar "$url" -o "$tmp/Followup.dmg"
hdiutil attach "$tmp/Followup.dmg" -nobrowse -quiet -mountpoint "$mnt"

# Quit a running copy so it can be replaced.
pkill -x Followup 2>/dev/null && sleep 1 || true

sudo=""
[[ -w /Applications ]] || { sudo="sudo"; bold "Administrator password needed to write to /Applications."; }
$sudo rm -rf "$DEST"
$sudo ditto "$mnt/Followup.app" "$DEST"
# Downloaded with curl, so there's no quarantine flag; clear it anyway in case.
$sudo xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

bold "Installed to $DEST. Launching…"
open "$DEST"

cat <<'EOF'

Next steps:
  1. Allow Accessibility when asked (System Settings → Privacy & Security → Accessibility).
  2. AI: install Claude Code and sign in once:
       curl -fsSL https://claude.ai/install.sh | bash && claude
     or pick Ollama / LM Studio in Followup → Settings.
  3. Select text anywhere and press Control-F.
EOF
