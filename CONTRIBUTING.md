# Contributing to Followup

Thanks for helping! Followup is a small native Swift app, so getting set up is quick.

## Setup

You need macOS 14+ and Swift 5.10+. The Xcode Command Line Tools are enough (`xcode-select --install`).

```sh
git clone https://github.com/harshf15-code/Followup.git
cd Followup
./test.sh            # run the tests
./build.sh install   # build, install to /Applications and launch
```

`test.sh` adds the flags Swift Testing needs when only the Command Line Tools are installed. With full Xcode, plain `swift test` works too.

## Seeing your changes

- `swift build && .build/debug/Followup --render-previews /tmp/fu` renders the wheel and a sample mind map to PNGs. It's the fastest way to check UI changes.
- `.build/debug/Followup --try snippet.txt research /tmp/fu` runs a text file through your configured AI and prints the mind map and one ✨ draft. Use it when you change prompts.
- Capture logs: `log stream --predicate 'subsystem == "com.harshsharma.followup"'`

## Where things live

- **`Sources/FollowupCore`** has no UI and is fully tested: models, the SQLite store, prompts, parsing of AI responses, and the LLM clients. New logic should go here with a test.
- **`Sources/Followup`** is the AppKit/SwiftUI app: hotkey, capture, wheel, windows.

## Pull requests

1. Keep each PR focused on one thing. Small PRs get merged fastest.
2. Add or update tests in `Tests/FollowupCoreTests` for any change to core logic.
3. Run `./test.sh` before pushing.
4. For UI changes, include a before/after screenshot.
5. Never commit real captures or personal data. Use made-up examples in tests and previews.

## Reporting bugs

Use the [bug report form](https://github.com/harshf15-code/Followup/issues/new/choose). Include your macOS version, the app you captured from, and which AI backend you use.
