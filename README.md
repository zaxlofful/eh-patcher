# eh-patcher
<p align="center">
    <img src="icon.png" alt="eh-patcher_icon" width="250">
</p>
A Patcher for Project Ebonhold allowing Users to modify/patch their game with visuals and QoL patches/addons.

## Features

- grouped patch selection with optional dependencies and related patch selection
- automatic Ebonhold folder search with remembered target path
- install detection for active and manually present patches
- per-patch uninstall support
- support for direct file, `.zip`, and `.rar` patch sources
- cached patch downloads for faster reinstallations
- built-in GitHub update support
- Large Address Aware / 4 GB client flag support
- per-patch notices for compatibility and additional information
- multilingual UI support

## Included Patches

**Character Visuals**
- HD Creatures & Mounts
- HD Race & Class Models
- HD Armor, Weapons / Equipment
- HD Spells & Effects `Not all are newly styled`

**World Visuals**
- HD Environment
- HD Watertextures
- HD Trees

**Misc Visuals**
- New Character Select/Creation Screen
- Character Info and Spellbook `Not compatible with ElvUI`

**QoL Improvements**
- Extra Class & Race Combination (e.g. Night Elf Mage, Blood Elf Warrior...)
- Classic & TBC Maps
- Caverns & Mines Maps
    - Requires WDM & Astrolabe

### Usage

Run locally (no installation required — just PowerShell 5.1+, built into Windows 10/11):

```powershell
powershell -ExecutionPolicy Bypass -File app.ps1
```

Or right-click `app.ps1` → *Run with PowerShell*.

No external tools (7-Zip, WinRAR, Python, etc.) are needed.
ZIP archives are extracted with the built-in .NET `System.IO.Compression` library.
RAR archives are extracted via the Windows Shell.Application COM interface (no EXE required).

## Info
No installation is required. The patcher saves your game location and downloaded patches in `%LOCALAPPDATA%\EH-Patcher`.

### Releases

The application is distributed through GitHub as a plain `.ps1` script.
https://github.com/SypherRed/eh-patcher/releases


#### Stuff
*Preview Image*
https://i.imgur.com/9bW2Xjq.png

