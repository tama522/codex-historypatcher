# codex-historypatcher

Use this when you want the Codex desktop app's left sidebar to show far more
recent threads, for example stretching the default recent-thread window of
around 25 items up to a configurable limit such as 350.

Small macOS helper script for rebuilding a local `Codex-HistoryPatch.app`
after the official Codex desktop app updates.

It does not redistribute Codex, Electron assets, `app.asar`, or a patched app.
It only automates local patching against your own installed
`/Applications/Codex.app`.

## What It Does

- Copies `/Applications/Codex.app` to a separate patched app.
- Extracts `Contents/Resources/app.asar`.
- Patches recent thread loading limits to a configurable value and follows
  app-server pagination when the app returns smaller pages.
- Avoids sidebar background probes for historical workspaces under
  `/Volumes/...`, which can otherwise trigger repeated Removable Volumes
  dialogs while browsing old threads.
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

Download and run the latest script directly from GitHub:

```sh
curl -fsSL \
  https://raw.githubusercontent.com/tama522/codex-historypatcher/main/scripts/repatch-codex-history.sh \
  -o /tmp/repatch-codex-history.sh
chmod +x /tmp/repatch-codex-history.sh
/tmp/repatch-codex-history.sh --limit 350
```

If you are comfortable piping a remote script directly into a shell, this is
the shortest form:

```sh
curl -fsSL https://raw.githubusercontent.com/tama522/codex-historypatcher/main/scripts/repatch-codex-history.sh | zsh -s -- --limit 350
```

## macOS Privacy Notes

The patched app intentionally uses a different bundle id from the official
Codex app. This keeps Full Disk Access and Removable Volumes permissions from
overwriting the official app's settings.

The script also adds `NSRemovableVolumesUsageDescription` to the patched app's
`Info.plist` files, including nested helper apps and bundles. This does not
grant access by itself. It only gives macOS a clear reason string to show if
the patched app or one of its helpers asks for Removable Volumes access.

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

### When Removable Volumes Access Is Needed

macOS may ask for Removable Volumes access when the patched app touches files
on an external SSD, USB drive, SD card, mounted disk image, or another path
under `/Volumes`.

This is most likely when:

- your project folder is stored on an external drive;
- a Codex workspace, output, or temporary file points to `/Volumes/...`;
- you open or resume a thread whose working directory was on a removable
  volume;
- the app checks file metadata on a removable volume without the access being
  granted through Finder, drag and drop, or an Open/Save panel first.

If repeated Removable Volumes dialogs continue after you allow access, first
quit all `Codex-HistoryPatch.app` processes or reboot once. Old running
processes can keep using the previous bundle identity until they exit.

Because this patcher ad-hoc signs the copied app, macOS can also treat a newly
patched build as a different code identity after `app.asar` or `Info.plist`
changes. In that case, allowing access once for the old patched build may not
fully apply to the next patched build.

The dialog can appear under slightly different names, such as
`Codex-HistoryPatch`, `Codex-HistoryPatch.app.bundle`, or a nested helper app.
That usually means a helper, plugin, or resource bundle inside the copied app
is the process that touched the removable volume. Re-run the latest patcher so
the removable-volumes usage description is applied to nested `Info.plist`
files too.

The sidebar can also trigger dialogs while browsing older threads if many
stored thread working directories point to `/Volumes/...`. The patcher filters
those removable-volume paths out of sidebar background existence checks and
workspace-group discovery. Opening or resuming an individual thread whose
workspace is actually on an external drive can still require access.

### Optional Privacy Repairs

The default script avoids changing privacy state beyond adding the removable
volumes usage description. The following options are intentionally opt-in.

Use `--repair-macos-xattrs` if macOS keeps showing provenance, quarantine, or
Gatekeeper-related warnings for the copied patched app, or if system logs show
messages such as `Unable to apply provenance sandbox` for
`Codex-HistoryPatch.app`:

```sh
./scripts/repatch-codex-history.sh --limit 350 --repair-macos-xattrs
```

This removes only `com.apple.provenance` and `com.apple.quarantine` extended
attributes from the copied patched app. It does not modify the official
`/Applications/Codex.app`.

Use `--reset-removable-volumes-tcc` only when Removable Volumes prompts keep
reappearing after you have quit the app and allowed the permission once:

```sh
./scripts/repatch-codex-history.sh --limit 350 --reset-removable-volumes-tcc
```

This runs:

```sh
tccutil reset SystemPolicyRemovableVolumes local.codex.historypatch
```

It clears the saved Removable Volumes decision for the patched bundle id, so
macOS can ask again cleanly the next time the patched app needs that access.

For repeated dialogs after upgrading from an older patcher version, re-apply
the latest script and reset the patched app's Removable Volumes decision once:

```sh
curl -fsSL https://raw.githubusercontent.com/tama522/codex-historypatcher/main/scripts/repatch-codex-history.sh | zsh -s -- --limit 350 --repair-macos-xattrs --reset-removable-volumes-tcc
```

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
