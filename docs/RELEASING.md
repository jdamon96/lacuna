# Publishing releases

Lacuna uses Sparkle 2.10.0. `Package.resolved` pins the dependency, and SwiftPM verifies the binary archive checksum. Builds embed and sign Sparkle's helpers with the app's signing identity. `scripts/build.sh` works without release credentials.

## Signing key

The official update key is stored in the release maintainer's macOS login Keychain, under Sparkle's service and account `com.jdamon.lacuna.updates`. Only the public key belongs in `Resources/Info.plist`. Keep a secure backup of the private key: the current ad-hoc preview releases cannot recover from its loss through Apple's Developer ID key-rotation mechanism. Never commit a private key or pass it as a command-line argument.

For a fork, resolve dependencies with `swift package resolve`, then run `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account your.unique.account`. Set your public key, HTTPS feed URL, and repository links for your project. Set `SPARKLE_ACCOUNT` and `RELEASE_REPOSITORY` when releasing. Do not replace the official app's verification key during routine releases.

## Build and publish

1. Increase the marketing version and integer build number in `Resources/Info.plist` and the script defaults. Each published build number and archive URL is immutable.
2. Run `swift test`, `scripts/tests/test-highlight-geometry.sh`, `scripts/tests/test-highlight-panel.sh`, and `python3 scripts/tests/test_update_appcast.py`.
3. Put concise plain-text release notes in a file, then run:

   ```sh
   RELEASE_NOTES_FILE=/path/to/notes.txt ./scripts/release.sh
   ```

   This builds the universal app, signs its ZIP using the Keychain key, verifies the signature, and creates `dist/appcast.xml` with a signature covering the feed. Existing feed entries are retained. The script refuses a mismatched signing key or duplicate build. `SIGNING_IDENTITY` and `NOTARY_PROFILE` optionally enable Developer ID signing and notarization; preview builds use ad-hoc Apple code signatures plus Sparkle's cryptographic update signatures.
4. Commit and push the source, then create a GitHub release with the new version tag and upload the corresponding DMG, ZIP, and SHA-256 file from `dist/`. Do not overwrite an existing release archive.
5. After the assets are publicly downloadable, copy `dist/appcast.xml` to the repository's `appcast.xml`, commit it, and push `main`. Its public URL is `https://raw.githubusercontent.com/jdamon96/lacuna/main/appcast.xml`. **Do not edit the signed feed by hand**; any byte change invalidates its signature.
6. Check the live feed and test downloading, installing, and relaunching from an older app build in an isolated folder. Also check that the latest build reports no update. Verify the installed version, not just the download dialog.

The app requires signed feeds and verifies archives before extraction. Release notes are embedded as plain text inside the signed feed. Background checks start only after user opt-in, and update installation is not enabled automatically. Updating replaces the app bundle; it does not remove preferences or Keychain entries. A change in Apple code-signing identity can still cause macOS to request Accessibility or Keychain authorization again.

Sparkle's license and bundled dependency notices are included in the app's `Contents/Resources/Sparkle-LICENSE.txt`.
