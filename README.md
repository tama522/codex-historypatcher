# codex-historypatcher

Small macOS helper script for rebuilding a local `Codex-HistoryPatch.app`
after the official Codex desktop app updates.

It does not redistribute Codex, Electron assets, `app.asar`, or a patched app.
It only automates local patching against your own installed
`/Applications/Codex.app`.

## What It Does

- Copies `/Applications/Codex.app` to a separate patched app.
- Extracts `Contents/Resources/app.asar`.
- Patches recent thread loading limits to a configurable value.
- Gives the copy a separate bundle id, by default `local.codex.historypatch`.
- Rebuilds `app.asar`, updates the Electron ASAR integrity hash, and ad-hoc
  signs the copied app.
- Installs the result to `/Applications/Codex-HistoryPatch.app`.

## Quick Start

```sh
chmod +x scripts/repatch-codex-history.sh
./scripts/repatch-codex-history.sh --limit 350
```

Custom target:

```sh
./scripts/repatch-codex-history.sh \
  --source /Applications/Codex.app \
  --target /Applications/Codex-HistoryPatch.app \
  --limit 350
```

Skip launch:

```sh
./scripts/repatch-codex-history.sh --limit 350 --no-launch
```

## macOS Privacy Notes

The patched app intentionally uses a different bundle id from the official
Codex app. This keeps Full Disk Access and Removable Volumes permissions from
overwriting the official app's settings.

After the first run, open:

```text
System Settings -> Privacy & Security -> Full Disk Access
```

Then add:

```text
/Applications/Codex-HistoryPatch.app
```

If macOS also shows the app under:

```text
Privacy & Security -> Files and Folders -> Removable Volumes
```

enable it there too.

If repeated Removable Volumes dialogs continue, quit all
`Codex-HistoryPatch.app` processes or reboot once. Old running processes can
keep using the previous bundle identity until they exit.

## Publishing This To GitHub

Keep the repository source-only:

- Do not commit `*.app`, `*.asar`, `app.asar.unpacked`, or copied Codex assets.
- Do not include OpenAI app icons or bundled proprietary resources.
- Keep the project name descriptive and avoid implying official affiliation.
- Add your preferred license and copyright owner before publishing.

This is an unofficial local patching helper. Review the license and terms for
the software you patch before using or distributing automation around it.

## Troubleshooting

Missing `asar` is usually fine. The script uses:

```sh
npx --yes @electron/asar
```

If `npm` or `npx` is not available in GUI-launched shells, run the script from a
normal terminal where Node.js is installed.

Run the script from Terminal, the official Codex app, or another host. Do not
run it from inside the target patched app itself, because the script needs to
stop and replace that app.

If a future Codex update changes the minified bundle structure, the script will
fail instead of blindly patching unrelated code. Re-run with `--keep-work` and
inspect the extracted `webview/assets` files.
