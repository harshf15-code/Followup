Followup — installing on another Mac
=====================================

1. Drag Followup into the Applications folder.

2. Open it. Because Followup isn't from the App Store or a registered
   developer, macOS blocks the first launch:
     • Click "Done" on the warning.
     • Open System Settings → Privacy & Security, scroll down,
       and click "Open Anyway" next to Followup. Confirm with your password.

3. When asked, allow Accessibility access
   (System Settings → Privacy & Security → Accessibility → Followup on).

4. AI: Followup uses Claude Code on this Mac. Install it and sign in once:
     curl -fsSL https://claude.ai/install.sh | bash
     claude        (sign in, then quit)
   Or choose a local model server (Ollama / LM Studio) in Followup's Settings.

Use: select text anywhere, press Control-F, pick a slice on the wheel.
Needs macOS 14 Sonoma or later. Works on Apple Silicon and Intel Macs.
