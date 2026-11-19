# DiskTidy

A small Windows app that shows what fills your disk and cleans the junk safely. It explains every item before you delete it.

![DiskTidy: disk map on top, cleanup list below (example data)](docs/screenshot.png)

*The screenshot shows example data, not a real PC.*

**No install, no dependencies, no internet.** It is one PowerShell script that uses only what ships with Windows 10/11 (PowerShell 5.1, WPF and the built-in C# compiler). It never connects anywhere, so nothing about your PC leaves it.

**[Download the latest release](https://github.com/Olexify/DiskTidy/releases/latest)**, unzip it anywhere, and double-click `DiskTidy.cmd`.

## Disk cleanup

- About 30 known places where Windows, browsers, dev tools and apps pile up caches and leftovers: Temp folders, crash dumps, npm, pip, uv, Cargo and Go caches, GPU shader caches, Chrome, Edge and desktop-app caches, old update files, and more.
- Each one shows its real location, its size, a **Safe** or **Caution** badge, and a plain explanation of what it is and what happens if you delete it.
- **Pick exactly what goes.** Expand any item to see what's inside as a tree with checkboxes. Untick a folder to keep it, or open it and untick only part of it.
- Hundreds of look-alike folders, such as render leftovers named `assets-x7f3…`, collapse into one line.
- Folders worth keeping start unticked, for example the session files of AI coding tools.
- Drag the grip under any list to make it taller.
- Right-click any line to open it in Explorer or find it in the disk map.

## Disk map

- A treemap of any drive or folder, like WizTree or WinDirStat: the bigger the block, the more space it takes. Files are coloured by type, and folders the cleanup list can empty get an orange outline.
- Hover over a block to outline it and see its path and size. Click to select, double-click to zoom in.
- Clickable breadcrumbs at the top jump back to any parent folder. Backspace or the mouse back button go up one level.
- Right-click a block to open it in Explorer or zoom.
- It scans only when you press **Scan** or a drive button, using at most half your CPU cores. Turn on **Scan on start** if you want it to scan every time it opens.

## Drives (read-only)

- Every physical disk with its health, temperature, SSD life used, power-on hours and errors the drive could not fix. Temperature, life used and error counts need admin.
- Plain warnings when a drive starts failing, for example "copy your important files off it now".
- Partitions with free-space bars, including which one Windows runs from.
- Buttons for Disk Management (shrink a volume, create a new one) and for disk tools you already have installed, such as Samsung Magician, CrystalDiskInfo or Rescuezilla.
- DiskTidy never writes to a disk here. To move Windows to a new SSD, use a cloning tool.

## RAM cleanup (optional)

- Trims the memory of the apps you pick, like Mem Reduct. Nothing closes and no data is lost. A trimmed app just reloads its memory when you switch back. Nothing is ticked by default.
- **Clear standby cache** drops cached file data from RAM. It needs admin.

## Comfort

- Four themes: Light, Dark, Midnight and Sand.
- Ctrl + mouse wheel zooms the whole window, and Ctrl+0 resets it.
- Drag the dividers to resize the map, its side list and the panel below.
- Theme, zoom, divider sizes and the cleanup list's scroll position are remembered between launches.
- **Desktop shortcut** creates a desktop shortcut with the app's icon.

## Safety rules

- **Never touched:** Downloads, Recycle Bin, Documents, Desktop, your projects, Docker, app settings and logins.
- Files changed in the last 2 hours, and files an app has open, are skipped. That makes it safe to run without rebooting.
- Junctions and symlinks are never followed, so a link can't lead it outside the folder being cleaned.
- Items marked **Caution** (AI models, IDE indexes, build caches) start unticked. Deleting them is harmless, but they get downloaded or rebuilt the next time something needs them.
- Before deleting, it asks you to confirm and shows the size of every item.

Some items (Windows Temp, Windows Update downloads, memory dumps) need admin. Click **Restart as admin** in the app.

## For developers

To check that the cleanup logic still works after you change something, run the built-in self-test. It covers the treemap maths, cleaning with unticked and part-ticked folders, junction safety, look-alike grouping, drive warnings and RAM info:

```powershell
powershell -ExecutionPolicy Bypass -File DiskTidy.ps1 -SelfTest
```

- `DiskTidy.ps1` holds the whole app. The window is WPF in XAML. Scanning, the treemap layout, cleaning and RAM trimming are inline C#, compiled when the app starts.
- Settings are saved to `%APPDATA%\DiskTidy\settings.json`.
- `-Shot <file.png>` saves a screenshot built from example data only. It's used for this README.

## License

MIT, see [LICENSE](LICENSE). Use at your own risk: the app is careful, but it deletes files.
