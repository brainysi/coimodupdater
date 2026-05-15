# COI Mod Updater

`COI Mod Updater` is a Windows PowerShell utility for checking installed Captain of Industry mods against the COI Hub and updating them when newer versions are available.

It scans installed mods, compares manifest versions, downloads updated packages, keeps a URL cache for faster future runs, creates backups before merge, and merges validated updates into your game mod folder.

## Features

- Checks installed mods in `%APPDATA%\Captain of Industry\Mods`
- Searches COI Hub for matching mods and follows the mod detail page download link
- Compares installed `manifest.json` versions with the latest hub version
- Downloads archives into `%APPDATA%\Captain of Industry\Mods_dl`
- Keeps a mod id to hub URL/download URL cache in `Mods_dl`
- Extracts and validates downloaded mod packages before install
- Backs up installed mod folders into `%APPDATA%\Captain of Industry\Bkup` before merge
- Merges updates in place instead of deleting and replacing the installed mod folder
- Preserves existing `.txt` and `.json` files during update, except `manifest.json`
- Supports `-WhatIf` for dry runs
- Supports `-ModId <id>` for targeted updates

## Requirements

- Windows
- Windows PowerShell 5.1 or newer
- Internet access to `https://hub.coigame.com`

## Files

- [Update-CoIMods.ps1](./Update-CoIMods.ps1): main updater script
- `mod-url-cache.json`: created automatically in `%APPDATA%\Captain of Industry\Mods_dl`
- `update-log-*.log`: created automatically in `%APPDATA%\Captain of Industry\Mods_dl`

## Usage

Run all installed mods:

```powershell
powershell -ExecutionPolicy Bypass -File ".\Update-CoIMods.ps1"
```

Dry run without changing files:

```powershell
powershell -ExecutionPolicy Bypass -File ".\Update-CoIMods.ps1" -WhatIf
```

Run for one mod only:

```powershell
powershell -ExecutionPolicy Bypass -File ".\Update-CoIMods.ps1" -ModId ProgramableNetwork
```

Verbose output:

```powershell
powershell -ExecutionPolicy Bypass -File ".\Update-CoIMods.ps1" -Verbose
```

## How It Works

1. Ensures these folders exist:
   - `%APPDATA%\Captain of Industry\Mods`
   - `%APPDATA%\Captain of Industry\Mods_dl`
   - `%APPDATA%\Captain of Industry\Bkup`
2. Reads installed mod manifests and collects mod ids and versions.
3. Uses the local cache when possible, otherwise searches the COI Hub.
4. Opens the resolved mod page and finds the latest version and `/Mod/DownloadMod/<id>` download action.
5. Downloads the update ZIP to `Mods_dl`.
6. Extracts and validates the package by inspecting its `manifest.json`.
7. Backs up the existing installed mod.
8. Merges the validated update into the installed mod folder in place.
9. Preserves existing `.txt` and `.json` files, except `manifest.json`, which is always updated.

## Notes

- Some mods may use folder layouts that require nested manifest detection; the tool attempts to handle common cases.
- If COI Hub changes its HTML or routing, the search/version/download parsing may need updates.
- Downloaded archives and logs are intentionally preserved for troubleshooting and reuse.

## Disclaimer

This tool is provided as-is, without warranty of any kind, express or implied. Use it at your own risk.

Although the tool creates backups before merging updates into installed mods, you are responsible for verifying that backups work for your setup and for reviewing any updates before using them in your game environment.

This project is not affiliated with, endorsed by, or sponsored by Mafi Games.

Captain of Industry, COI Hub, mod names, logos, and other related assets or marks are the property of their respective owners. All copyrights and trademarks remain with their respective holders.

## AI Assistance

This project was created with AI assistance for implementation, debugging, and documentation.

## License

This project is licensed under the MIT License. See [LICENSE](./LICENSE).
