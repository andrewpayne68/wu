# wu - Windows Update, winget and Microsoft Store updates from the command line

```powershell
irm https://andrewpayne68.github.io/wu | iex
```

It elevates itself if needed (UAC prompt, then continues in an admin Windows Terminal tab) and shows a menu:

```
  WINDOWS CLI MENU
  ----------------------------------------
    1  Windows Update CLI
    2  Winget Update CLI
    3  Store Update CLI
    4  Oh My Posh Terminal Theme
    5  Chris Titus Windows Utility

    q  Quit
```

After each one finishes you're back at the menu.

- **4** runs the [Windows Terminal + Oh My Posh installer](https://github.com/andrewpayne68/windows-terminal-ohmyposh): `irm https://raw.githubusercontent.com/andrewpayne68/windows-terminal-ohmyposh/main/install.ps1 | iex`
- **5** runs [Chris Titus Tech's Windows Utility](https://github.com/ChrisTitusTech/winutil): `irm christitus.com/win | iex`. WinUtil opens its own window; close it to return to the menu.

Both run in their own Windows PowerShell 5.1 process in the same window, so they can't interfere with the menu.

## 1. Windows Update CLI

1. Checks Microsoft Update (or plain Windows Update if Microsoft Update isn't registered) with a live spinner.
2. Lists updates in three groups: **Recommended**, **Optional** (previews, feature packs) and **Drivers**, with KB, size and a restart flag.
3. You choose what to install:
   - `r` recommended, `o` optional, `d` drivers, `a` all
   - `1,3,5-7` specific numbers (mix freely: `r 9 12`)
   - `h 4,5` hides updates so they stop showing up
   - `l` lists again, `q` quits, Enter means recommended
4. Downloads each update with its own progress bar (percent, MB done / total, speed, elapsed), then installs each one with its own progress bar.
5. If Windows Update is already installing in the background, it waits for it, and it counts updates Windows installed meanwhile as done.
6. Prints a summary (with readable error codes) and offers a restart if one is needed.

## 2. Winget Update CLI

1. Runs `winget upgrade` and lists every app with an upgrade: name, ID, installed version -> new version.
   Pinned apps, and apps whose installer manages its own updates, are listed separately.
2. You choose: `u` (or Enter) all upgrades, `a` everything including the separate list, `1,3,5-7` numbers, `l` list again, `q` quit.
3. Upgrades each app one at a time, silently, with winget's own live download progress bar.
4. Prints a summary with readable winget error codes (for example "the app is in use").

## 3. Store Update CLI

1. Asks the Microsoft Store which of your Store apps have updates, without installing anything yet.
2. Lists them with name, installed version and Store product ID.
3. You choose: `a` (or Enter) all, `1,3,5-7` numbers, `l` list again, `q` quit.
4. Updates each app one at a time with its own progress bar showing the stage (queued, downloading with MB done / total, installing) and the version change when done.
5. Prints a summary.

This uses the Store's own update API, which only Windows PowerShell 5.1 can call, so this part always runs in Windows PowerShell 5.1 (built into Windows) in the same window, even if you started from PowerShell 7.

## Options

These skip the menu:

```powershell
& ([scriptblock]::Create((irm https://andrewpayne68.github.io/wu))) -ListOnly
& ([scriptblock]::Create((irm https://andrewpayne68.github.io/wu))) -Install Recommended,Drivers -AutoReboot
& ([scriptblock]::Create((irm https://andrewpayne68.github.io/wu))) -Winget
& ([scriptblock]::Create((irm https://andrewpayne68.github.io/wu))) -Winget -Install All
& ([scriptblock]::Create((irm https://andrewpayne68.github.io/wu))) -Store -Install All
```

| Option | Meaning |
|---|---|
| `-WindowsUpdate` | Go straight to Windows Update |
| `-Winget` | Go straight to winget app upgrades |
| `-Store` | Go straight to Microsoft Store app updates |
| `-ListOnly` | List only (Windows Update, or with `-Winget` / `-Store`). Doesn't need admin. |
| `-Install <sets>` | Install without prompting. Windows Update: `Recommended`, `Optional`, `Drivers`, `All`. With `-Winget` or `-Store`, any value updates all apps. |
| `-AutoReboot` | Restart after 15 s if a Windows update needs it |
| `-NoMicrosoftUpdate` | Windows Update only (skip Office and other Microsoft products) |

## How it's hosted

GitHub Pages serves `index.html`, which is an exact copy of `wu.ps1` (Pages serves `.ps1` files as downloads, which `irm` handles badly). After editing `wu.ps1`, copy it over `index.html` before committing:

```powershell
Copy-Item wu.ps1 index.html
```

Uses the built-in Windows Update Agent COM API, winget and the Microsoft Store update API. Works in Windows PowerShell 5.1 and PowerShell 7+.
