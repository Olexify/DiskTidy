# DiskTidy

A small Windows app that shows what fills your disk and cleans the junk safely. It also explains every item before you delete it.

![DiskTidy in the dark theme](docs/screenshot.png)

**No install, no dependencies.** It is one PowerShell script that uses only what ships with Windows 10/11 (PowerShell 5.1, WPF and the built-in C# compiler).

## What it does

**Disk map (like WizTree / WinDirStat)**
- Scans a drive or folder and draws it as a treemap: the bigger the block, the bigger the folder or file. Files are coloured by type.
- Hover over a block to outline it and see its path and size. Click to select, double-click to zoom in.
- The breadcrumb at the top jumps back to any parent. Backspace or the mouse back button also go up a level.
- Right-click opens a block in Explorer.
- Folders that the cleanup list can empty get an orange outline.

**Disk cleanup**
- About 30 known places where Windows, browsers, dev tools and apps leave caches and leftovers. Each one shows its size, a **Safe** or **Caution** badge, and a plain explanation of what it is and what happens if you delete it.
- Expand any item to choose what to delete. Folders inside show up as a tree with tri-state checkboxes. Look-alike folders, such as hundreds of `render-assets-xxxx` folders, collapse into one line.
- Right-click any line to open it in Explorer or find it in the disk map.

**RAM cleanup** (optional, nothing ticked by default)
- Trims the memory of the apps you pick, like Mem Reduct. Nothing closes and no data is lost. The app just reloads its memory when you switch back.
- "Clear standby cache" drops cached file data from RAM. This one needs admin.

**Other features**
- Four themes: Light, Dark, Midnight, Sand.
- Ctrl + mouse wheel zooms the whole window, and Ctrl+0 resets it.

## Safety rules

- **Never touched:** Downloads, Recycle Bin, Documents, Desktop, your projects, Docker, app settings, logins.
- Files changed in the last 2 hours, and files an app has open, are skipped. That makes it safe to run without rebooting.
- Junctions and symlinks are never followed, so a link can't lead it outside the folder being cleaned.
- Items marked **Caution** (AI models, IDE indexes, build caches) start unticked. Deleting them is harmless, but they get downloaded or rebuilt the next time something needs them.
- Before deleting, it asks you to confirm and shows the size of every item.

## Run it

1. Download the repo (Code → Download ZIP) and unzip it anywhere.
2. Double-click `DiskTidy.cmd`.
3. Optional: click **Desktop shortcut** in the app for a shortcut with the proper icon.

Some items (Windows Temp, Windows Update downloads, memory dumps) need admin. Click **Restart as admin** in the app.

To check that the cleanup logic still works after you change something, run the built-in self-test:

```powershell
powershell -ExecutionPolicy Bypass -File DiskTidy.ps1 -SelfTest
```

## How it works

- `DiskTidy.ps1` holds the whole app. The window is WPF in XAML. Scanning, the treemap layout, cleaning and RAM trimming are inline C#, compiled when the app starts, so scans of a few hundred thousand files take seconds.
- Settings (theme and zoom) are saved to `%APPDATA%\DiskTidy\settings.json`.

## License

MIT, see [LICENSE](LICENSE). Use at your own risk: the app is careful, but it deletes files.
