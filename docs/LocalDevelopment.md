# Run DreamLog on another Mac

## Requirements

- Xcode 26 or later, with an iOS 26+ simulator runtime. The current implementation was compiled with Xcode 27.
- uv installed following https://docs.astral.sh/uv/getting-started/installation/ . uv installs the pinned Python 3.14 runtime and dependencies.
- Git and OpenSSL (macOS includes these command-line tools).

Clone the code repository and run commands from its root. No wiki checkout or cloud account is required to run Foundation. The design source remains the project wiki; `docs/Foundation.md` records the implementation scope.

## Backend

```sh
./scripts/run-local.sh
```

The script runs `uv sync --locked`, creates a local HTTPS certificate valid for 100 days if absent, and starts Granian on port 8443. Certificate/key/database files stay in ignored `backend/.local/`. Foundation sends no AI calls and uses a clearly labeled placeholder key locally. Later AI increments require a real server-side key and the provider checks in the wiki.

Keep this terminal running. Running the app from Xcode does not start the backend; Notes cannot save while this server is stopped. Wait for `Listening at: https://0.0.0.0:8443` before trying Save. In a second terminal:

```sh
cd backend
uv run --locked pytest -q
uv run --locked python tests/smoke_https.py
```

The smoke test explicitly trusts the local certificate and checks authentication, settings and Journal/Notes/Profile read/write/deletion over HTTPS/HTTP2. Do not use `curl -k` or disable certificate validation in the app.

## VS Code Python interpreter

Open `ShuttleCode` as the workspace folder. Its `.vscode/settings.json` points discovery and the default interpreter at `backend/.venv`, created by `uv sync --locked`. Run `Developer: Reload Window`, then `Python: Select Interpreter` and select that environment. If it is still absent, use `Enter interpreter path…` and paste the absolute path to `backend/.venv/bin/python`. A previously selected interpreter may require this explicit selection even after changing workspace settings. Do not select the underlying system Python: dependencies are installed in the virtual environment.

## iOS Simulator

Open `ios/DreamLog.xcodeproj`, select the shared DreamLog scheme and an iPhone simulator running iOS 26+. Run it once to boot the simulator, then trust this checkout's certificate:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun simctl keychain booted add-root-cert backend/.local/server.crt
```

Run the app again. The default server URL is `https://127.0.0.1:8443`; it reaches the backend on the same Mac. The short development notice appears before the tabs. In Journal, + opens an editor; Done saves automatically, Revert abandons edits. Notes retains Save and supports Add photos; photo-only notes are allowed. Tap a saved row to read, edit or delete it. Unsent Journal text remains as a local draft; unsent Notes/photos stay only in the open editor. Settings lets you edit name, age and other profile fields, add/remove fields and Save profile. It also exposes history, the shared privacy text and Delete my journal. See [Architecture.md](Architecture.md) and [API.md](API.md).

Run tests with Product → Test or:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project ios/DreamLog.xcodeproj -scheme DreamLog \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Choose a simulator name installed on your Mac. For a real app/backend lifecycle test, keep the backend running, boot and trust the certificate on the selected simulator, then use the `DreamLogHTTPS` scheme with `-parallel-testing-enabled NO`. This explicitly enables the optional HTTPS integration test; the normal DreamLog scheme runs the isolated unit tests and skips that one network test.

The `DreamLogUI` scheme runs actual screen interaction tests against the local backend: first Notes save/reopen/delete and Journal automatic save/Revert/delete. Use the same simulator certificate trust and disable parallel clones as above. It creates only invented entries and deletes its own entries; it does not clear existing journals.

Keep simulator signing enabled: Keychain tests require the signed test host. No paid developer account is needed for a simulator. Personal signing team/bundle overrides and Xcode user settings are not committed.

## Another backend address or a physical phone

The Xcode build setting `DREAMLOG_SERVER_URL` is the single app endpoint configuration. Override it in a local configuration or on the build command, for example `DREAMLOG_SERVER_URL=https://api.example.org`. The generated Info.plist supplies it to AppModel. Use the HTTPS origin only, without `/v1`.

For a physical phone the localhost address refers to the phone. Use the Mac's LAN IP and generate a certificate whose subjectAltName contains that IP, point the app at `https://<Mac-LAN-IP>:8443`, and ensure the Mac firewall permits the connection. Install and explicitly trust that local certificate on the phone. The certificate is a local certificate authority: trust only a certificate generated by the developer, keep its private key private, and remove the trust when testing ends. Renew the certificate after 100 days and reinstall it on test devices.

The same backend reads `DATA_DIR`, `TLS_CERT`, `TLS_KEY`, `PORT` and `GEMINI_API_KEY` from the environment. `scripts/run-local.sh` sets local defaults; production systemd supplies its environment file. The script does not change API behavior or ownership rules.

## Common failures

- `_UIKBFeedbackGenerator` / missing `hapticpatternlibrary.plist`: a known system keyboard-feedback issue reported with simulator TextField/TextEditor. Apple DTS identifies FB18465343 and has no recommended workaround in [its response](https://developer.apple.com/forums/thread/812392). The app's Notes save path does not call a haptic API. This console entry alone does not indicate a failed save; check whether the note can be reopened and whether the memory request returned success or an application error.
- `xcodebuild requires Xcode`: select Xcode in Settings → Locations → Command Line Tools, or use the DEVELOPER_DIR prefix above.
- Notes Save fails / Done asks to discard: keep the editor open, start `./scripts/run-local.sh`, and retry Save without losing the text. The updated editor shows a save-failure alert and Done also offers Save and close or Keep editing. A backend must be running for storage; Xcode only starts the app.
- Connection/certificate error: check the running backend, port, server URL, certificate dates/SAN and simulator trust. Trust the certificate separately on each simulator you use.
- Keychain error: retain code signing, unlock the device, then retry. The app intentionally does not generate a temporary fallback ID.
- Schema version error: do not silently overwrite the database. Backend schema version 3 upgrades versions 1/2 additively with profiles/note photos and preserves existing records; other mismatches refuse startup. The phone draft schema remains version 1.

The app never shows its identity. Reinstalling alone does not reliably clear Keychain or delete server data; use Delete my journal for a full reset.
