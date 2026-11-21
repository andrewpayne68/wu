# wu - Windows Update from the command line

```powershell
irm https://andrewpayne68.github.io/wu | iex
```

1. Elevates itself if needed (UAC prompt, then continues in a new admin window).
2. Checks Microsoft Update (or plain Windows Update if Microsoft Update isn't registered) with a live spinner.
3. Lists updates in three groups: **Recommended**, **Optional** (previews, feature packs) and **Drivers**, with KB, size and a restart flag.
4. You choose what to install:
   - `r` recommended, `o` optional, `d` drivers, `a` all
   - `1,3,5-7` specific numbers (mix freely: `r 9 12`)
   - `h 4,5` hides updates so they stop showing up
   - `l` lists again, `q` quits, Enter means recommended
5. Downloads each update with its own progress bar (percent, MB done / total, speed, elapsed), then installs each one with its own progress bar.
6. Prints a summary (with readable error codes) and offers a restart if one is needed.

## Options

```powershell
& ([scriptblock]::Create((irm https://andrewpayne68.github.io/wu))) -ListOnly
& ([scriptblock]::Create((irm https://andrewpayne68.github.io/wu))) -Install Recommended,Drivers -AutoReboot
```

| Option | Meaning |
|---|---|
| `-ListOnly` | List only. Doesn't need admin. |
| `-Install <sets>` | Install without prompting: `Recommended`, `Optional`, `Drivers`, `All` |
| `-AutoReboot` | Restart after 15 s if an update needs it |
| `-NoMicrosoftUpdate` | Windows Update only (skip Office and other Microsoft products) |

## How it's hosted

GitHub Pages serves `index.html`, which is an exact copy of `wu.ps1` (Pages serves `.ps1` files as downloads, which `irm` handles badly). After editing `wu.ps1`, copy it over `index.html` before committing:

```powershell
Copy-Item wu.ps1 index.html
```

Uses the built-in Windows Update Agent COM API. Works in Windows PowerShell 5.1 and PowerShell 7+.
