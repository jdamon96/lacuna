# Lacuna

Fill the gaps in your writing. Lacuna is an open source macOS menu bar app that turns `{instructions}` into three inline suggestions, wherever compatible text fields are available.

## Requirements

macOS 13 or later, Apple Silicon or Intel, and an OpenAI or Anthropic API key (or an OpenAI-compatible server).

## Install

Download the DMG or ZIP from [GitHub Releases](https://github.com/jdamon96/lacuna/releases), move Lacuna to Applications, and open it. Preview downloads are ad-hoc signed, without Apple Developer ID signing or notarization. macOS may require you to allow the app in **System Settings → Privacy & Security → Open Anyway** after the first launch attempt.

Grant **Accessibility** access when prompted, then open Lacuna’s menu bar settings. Choose your provider, enter your API key, and select a model from the dropdown. **Refresh** loads the available OpenAI or Anthropic models using your key. You can also enter a model ID manually, including for custom servers. Click **Save** when ready.

## Use

1. Type something like `Let’s meet {a friendly way to suggest next Tuesday}.`
2. Keep that text field focused. Lacuna marks the nearest supported template as you type; place the cursor inside one to choose between multiple templates.
3. Press **⇧⌘K** to generate three options using the surrounding text.
4. Press **1**, **2**, or **3** to replace the braces with your choice. **Escape** dismisses the suggestions.

Use **↑/↓** to scroll long suggestions, **Tab** to move to the next option, and **Return** to accept the selected option.

Use single braces. You can change the shortcut, provider, and model in settings. OpenAI and Anthropic use their respective native APIs. Choose **OpenAI-compatible** to configure a custom or local server with a Chat Completions API.

## Privacy and compatibility

Brace detection happens locally in the focused text field. Text is sent directly to your configured provider only when you request suggestions. API keys stay in macOS Keychain. There is no Lacuna server or analytics.

Lacuna uses macOS Accessibility APIs. Support depends on how each app exposes its editable text and text positions; some web editors, terminals, and custom controls may not work. Read-only pages and secure password fields are excluded. Try TextEdit in plain-text mode first.

## Build from source

Install [Xcode Command Line Tools](https://developer.apple.com/xcode/resources/) with Swift 5.9 or later, then:

```sh
git clone https://github.com/jdamon96/lacuna.git
cd lacuna
./scripts/install.sh
```

This builds, installs to `~/Applications`, and opens Lacuna. Use `./scripts/build.sh` to build only, `swift test` to run tests, or `./scripts/release.sh` to create a universal DMG and ZIP in `dist/` (requires full Xcode).

Release scripts default to version `0.2.0`, build `2`; override them with `--version` and `BUILD_NUMBER`. Optional `SIGNING_IDENTITY` and `NOTARY_PROFILE` environment variables enable Developer ID signing and notarization with your existing credentials. Nothing is published automatically.

## License

[MIT](LICENSE). Built with Swift and AppKit.
