# WUtility

**Windows, but yours.** A Windows setup / debloat / config tool — WinUtil-style, but
it works like a Linux tool: everything WinUtil does with a mouse, WUtility does with
one command. One script, one window, zero setup.

## Run it on any PC

The whole tool is one file: **`peak.ps1`**. Copy it (with `peak.cmd`, optional but
nicer) to a USB stick, cloud folder, email attachment — anywhere.

**Easiest way:** double-click **`peak.cmd`**. It unblocks the script, bypasses the
execution policy, and opens the GUI — no PowerShell knowledge needed.

From a terminal on *any* Windows 10/11 PC:

```powershell
powershell -ExecutionPolicy Bypass -File .\peak.ps1

# GUI (like WinUtil)          -> just runs with no arguments
# See everything it can do    -> .\peak.ps1 -List
```

The script auto-elevates to Administrator when it needs to (UAC prompt). No install,
no registry entries of its own, nothing left behind except its log and backups.

**Portable mode:** if you can't write next to the script (e.g. USB write-protect),
it automatically falls back to `Documents\WUtility` for its log, backups, and cache.
If the script folder IS writable, everything stays next to the script — so a USB
stick keeps its own data.

**No winget? No problem.** If the PC doesn't have winget (fresh Windows installs
often don't), WUtility tries to install it for you automatically and then carries on.

## The one-liner (no files at all)

WinUtil's whole model is `irm christitus.com/win | iex`. WUtility does exactly the
same — no download, no files, no setup. On any Windows 10/11 PC, open
**PowerShell as Administrator** (right-click Start → *"Terminal (Admin)"* or
*"Windows PowerShell (Admin)"*) and paste:

```powershell
irm https://raw.githubusercontent.com/bckyle1-debug/WUtility/main/peak.ps1 | iex
```

That's it. It opens the full GUI, auto-elevates when a task needs it, and leaves
no files behind.

**Too long to type or share?** Shorten it once at [tinyurl.com](https://tinyurl.com)
(paste the link above, pick a name like `wuutility`) and share:

```powershell
irm https://tinyurl.com/wuutility | iex
```

**Advanced / scripting** (no GUI, no elevation prompt for read-only stuff):

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/bckyle1-debug/WUtility/main/peak.ps1))) -List
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/bckyle1-debug/WUtility/main/peak.ps1))) -Install vscode,git
```

## CLI (the WinUtil superpower)

```powershell
# Discover
.\peak.ps1 -List                                  # full catalog: tweaks, apps, features

# Install apps (id or winget id, multi-value)
.\peak.ps1 -Install vscode,git,firefox
.\peak.ps1 -Install "Google.Chrome"               # raw winget id works too

# Apply tweaks by id or category (privacy / performance / ui / all)
.\peak.ps1 -Tweaks privacy,ui
.\peak.ps1 -Tweaks all -Backup

# Undo exactly what you did (every tweak has revert values)
.\peak.ps1 -UndoTweaks ui

# Preview without touching anything
.\peak.ps1 -Everything -DryRun

# Debloat with a safety net
.\peak.ps1 -Debloat -RestorePoint

# Windows Update control
.\peak.ps1 -Updates security                      # patches only, feature updates deferred 1y
.\peak.ps1 -Updates disable                       # fully stop updates
.\peak.ps1 -Updates default                       # restore Windows defaults
.\peak.ps1 -Updates retry                         # force an update check now

# Windows features
.\peak.ps1 -Features wsl,hyperv                   # also: sandbox, net35, vmp

# Combo (a full "new PC" setup)
.\peak.ps1 -Install vscode,git,7zip,discord,steam -Tweaks privacy,ui,perf -Updates security -Debloat -RestorePoint

# Recover
.\peak.ps1 -RestoreBackup 20261121_122029-tweaks  # re-import a registry backup
```

## What's better than WinUtil

| | WinUtil | WUtility |
|---|---|---|
| GUI | yes | yes (dark, non-freezing worker, live log pane) |
| CLI / one-line automation | no | full `param`-based CLI |
| Undo tweaks | not per-tweak | every tweak has built-in revert values |
| Automatic registry backup before changes | no | every run, timestamped backups |
| Shows apps you already have | no | green "✓ installed" badges on load (one fast `winget export`, cached 1h); installs skip them automatically |
| Auto-installs winget if missing | no | yes, per-user, no admin needed |
| Dry-run mode | no | `-DryRun` prints everything it would do |
| Restore points | manual | `-RestorePoint` flag on any command |
| Exit codes for scripting | no | yes |

## Installed-app detection

On GUI start (and in `-List`), WUtility runs one fast `winget export` to learn what's
already on the machine:

- **GUI**: installed apps get a green `✓ installed` badge; a counter shows
  "5 of 31 apps already installed"; "Install selected" skips them automatically.
- **CLI**: `-List` prints `[installed]` next to them, and `-Install` skips them.
- Results are cached in `installed-cache.json` (next to the script, or in
  `Documents\WUtility`) for 1 hour, invalidated automatically after an install.

## Where things go

- Log: `<script folder (if writable) or Documents\WUtility>\peak.log`
- Backups: `<same>\backups\<timestamp>-<tag>\` (full `.reg` exports + value-level snapshots)

## Add your own

- **Tweak**: add an entry to `$Script:TweakDefs` (registry keys with apply + revert
  values, optional services/scheduled tasks, optional free-form Apply/Revert commands).
- **App**: add an entry to `$Script:Apps` (winget id) and list the id in
  `$Script:AppCatalog` — it appears in `-List` and in the GUI automatically.
- **Bloat**: append names to `$Script:Bloat` (Appx package names).

## Safety notes

- Every registry-changing run backs up the keys it touches, automatically.
- `-UndoTweaks <same ids>` reverses exactly those tweaks.
- Debloat removes consumer-bloat `Appx` packages for all users — nothing is removed
  that Windows Update or winget can't reinstall, and it never touches Microsoft Store,
  Security/Defender, or .NET runtimes.
- `-Updates disable` is reversible: `-Updates default`.
- Always `-DryRun` first if you're unsure.
