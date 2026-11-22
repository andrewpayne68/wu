<#
    wu.ps1 - a no-nonsense update CLI for Windows Update, winget and the Microsoft Store

    Quick start (paste into an admin or normal PowerShell / Terminal):
        irm https://andrewpayne68.github.io/wu | iex
    The WINDOWS CLI MENU then offers:
        1) Windows Update CLI   2) Winget Update CLI   3) Store Update CLI
        4) OhMyPosh Terminal Setup and Theme   5) Chris Titus Windows Utility
        6) Repair Windows   7) Clean Up Disk Space   8) Update History
        9) Install PDFcraft   10) Install Store and Winget (LTSC/Server)

    With options (skip the menu):
        & ([scriptblock]::Create((irm https://andrewpayne68.github.io/wu))) -ListOnly
        & ([scriptblock]::Create((irm https://andrewpayne68.github.io/wu))) -Install Recommended -AutoReboot
        & ([scriptblock]::Create((irm https://andrewpayne68.github.io/wu))) -Winget
        & ([scriptblock]::Create((irm https://andrewpayne68.github.io/wu))) -Winget -Install All
        & ([scriptblock]::Create((irm https://andrewpayne68.github.io/wu))) -Store -Install All

    Options:
        -WindowsUpdate            Go straight to Windows Update.
        -Winget                   Go straight to winget app upgrades.
        -Store                    Go straight to Microsoft Store app updates.
        -ListOnly                 Just list available updates, install nothing.
        -Install <set[,set]>      Non-interactive. Windows Update: Recommended, Optional, Drivers or All.
                                  With -Winget or -Store, any value updates all apps.
        -AutoReboot               Reboot automatically if an update needs it.
        -NoMicrosoftUpdate        Only use Windows Update (skip Office / other MS products).

    Works with Windows PowerShell 5.1 and PowerShell 7+. Uses the built-in
    Windows Update Agent COM API and winget - nothing extra is installed.
#>

function Invoke-WUCli {
    [CmdletBinding()]
    param(
        [switch]$ListOnly,
        # Recommended, Optional, Drivers or All. Checked below rather than with ValidateSet,
        # because the elevated relaunch passes "Recommended,Drivers" as a single string.
        [string[]]$Install,
        [switch]$AutoReboot,
        [switch]$NoMicrosoftUpdate,
        [switch]$WindowsUpdate,
        [switch]$Winget,
        [switch]$Store
    )

    $ErrorActionPreference = 'Stop'
    if ($Install -and -not $Winget -and -not $Store) {
        $Install = @($Install -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $validSets = 'Recommended', 'Optional', 'Drivers', 'All'
        foreach ($set in $Install) {
            if ($set -notin $validSets) {
                Write-Host "Unknown -Install value '$set'. Use: $($validSets -join ', ')" -ForegroundColor Red
                return
            }
        }
    }
    $FULL  = [string][char]0x2588
    $LIGHT = [string][char]0x2591
    $spin  = '|', '/', '-', '\'

    # ------------------------------------------------------------ helpers
    function Write-Line([string]$Text = '', [ConsoleColor]$Color = 'Gray', [switch]$NoNewline) {
        Write-Host $Text -ForegroundColor $Color -NoNewline:$NoNewline
    }

    function Get-ConsoleWidth {
        try { [Math]::Max(60, $Host.UI.RawUI.WindowSize.Width) } catch { 100 }
    }

    function Format-Size([double]$Bytes) {
        if ($Bytes -le 0) { return '-' }
        $units = 'B', 'KB', 'MB', 'GB'
        $i = 0
        while ($Bytes -ge 1024 -and $i -lt $units.Count - 1) { $Bytes /= 1024; $i++ }
        if ($i -eq 0) { return '{0:N0} {1}' -f $Bytes, $units[$i] }
        '{0:N1} {1}' -f $Bytes, $units[$i]
    }

    function Format-Elapsed([TimeSpan]$t) {
        if ($t.TotalHours -ge 1) { return $t.ToString('h\:mm\:ss') }
        $t.ToString('mm\:ss')
    }

    function Limit-Text([string]$s, [int]$max) {
        if ($s.Length -le $max) { return $s }
        $s.Substring(0, [Math]::Max(1, $max - 3)) + '...'
    }

    function Write-Status([string]$Text, [ConsoleColor]$Color = 'Cyan') {
        # Rewrites the current console line in place.
        $w = (Get-ConsoleWidth) - 1
        $Text = Limit-Text $Text $w
        Write-Host ("`r" + $Text.PadRight($w)) -NoNewline -ForegroundColor $Color
    }

    function Get-Bar([double]$Pct, [int]$Width = 28) {
        $Pct = [Math]::Min([double]100, [Math]::Max([double]0, $Pct))
        $n = [int][Math]::Round($Pct / 100 * $Width)
        ($FULL * $n) + ($LIGHT * ($Width - $n))
    }

    $hrText = @{
        '80240022' = 'all updates in the operation failed'
        '8024200D' = 'update needs more data - retry'
        '80070005' = 'access denied - run as administrator'
        '80240016' = 'another install is already in progress'
        '8024402C' = 'cannot reach the update server'
        '80244022' = 'update server is busy (HTTP 503)'
        '800F0922' = 'servicing failed (often low System Reserved space or VPN)'
        '80073712' = 'component store is damaged - try DISM /RestoreHealth'
        '80070643' = 'installation failed (fatal MSI/installer error)'
        '8024A105' = 'Windows Update needs a restart first'
        '80240438' = 'no route to the update service'
        '80240034' = 'download failed'
    }
    function Format-HResult([int]$hr) {
        $hex = '{0:X8}' -f $hr
        if ($hrText.ContainsKey($hex)) { "0x$hex ($($hrText[$hex]))" } else { "0x$hex" }
    }

    # ------------------------------------------------------------ elevation
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not $isAdmin -and -not $ListOnly) {
        Write-Line 'Administrator rights are needed to install updates - relaunching elevated...' Yellow
        $tmp = Join-Path $env:TEMP 'wu-cli.ps1'
        $self = "function Invoke-WUCli {`n$(${function:Invoke-WUCli})`n}`nInvoke-WUCli @args`n"
        Set-Content -Path $tmp -Value $self -Encoding UTF8
        # No -NoProfile: the tab stays open afterwards (-NoExit), so load your profile
        # (Oh My Posh prompt, aliases) like any other Terminal tab.
        $argList = @('-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$tmp`"")
        if ($Install)           { $argList += '-Install'; $argList += ($Install -join ',') }
        if ($AutoReboot)        { $argList += '-AutoReboot' }
        if ($NoMicrosoftUpdate) { $argList += '-NoMicrosoftUpdate' }
        if ($WindowsUpdate)     { $argList += '-WindowsUpdate' }
        if ($Winget)            { $argList += '-Winget' }
        if ($Store)             { $argList += '-Store' }
        # Relaunch with the same PowerShell that's running now (pwsh 7 or Windows PowerShell 5.1).
        $exe = (Get-Process -Id $PID).Path
        if ($exe -like '*\Program Files\WindowsApps\*') {
            # Store-installed PowerShell: launch through its app alias rather than the package folder.
            $alias = Get-Command (Split-Path $exe -Leaf) -ErrorAction SilentlyContinue
            if ($alias) { $exe = $alias.Source }
        }
        $wt  =Get-Command wt.exe -ErrorAction SilentlyContinue
        $cancelled = $false
        $launched  = $false
        if ($wt) {
            # Open an elevated Windows Terminal tab running this script. No -p profile is given,
            # so it uses your default profile's look; the command line below sets the shell.
            $wtArgs = @('new-tab', '--title', '"Windows CLI"', "`"$exe`"") + $argList
            try {
                Start-Process -FilePath $wt.Source -Verb RunAs -ArgumentList $wtArgs | Out-Null
                $launched = $true
            } catch {
                # 1223 = the user said No at the UAC prompt; don't ask a second time.
                if ($_.Exception.InnerException.NativeErrorCode -eq 1223 -or $_.Exception.NativeErrorCode -eq 1223) { $cancelled = $true }
            }
        }
        if (-not $launched -and -not $cancelled) {
            # No Windows Terminal (or it failed to start): fall back to a plain console window.
            try {
                Start-Process -FilePath $exe -Verb RunAs -ArgumentList $argList | Out-Null
                $launched = $true
            } catch { $cancelled = $true }
        }
        if ($launched) {
            Write-Line 'Continuing in the new administrator window.' Green
        } else {
            Write-Line 'Elevation was cancelled. Run PowerShell as administrator, or use -ListOnly.' Red
        }
        return
    }

    # ================================================================ WINDOWS UPDATE
    # (body not re-indented: the C# here-string below must stay at column 0)
    function Invoke-WindowsUpdatePart {

    # ------------------------------------------------------------ COM callbacks
    # WUA's async Begin* methods require callback objects; these do nothing
    # because progress is polled from the job objects instead.
    if (-not ('WuCli.NoopCallback' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace WuCli {
    [ComImport, Guid("88AEE058-D4B0-4725-A2F1-814A67AE964C"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface ISearchCompletedCallback { void Invoke([MarshalAs(UnmanagedType.IDispatch)] object job, [MarshalAs(UnmanagedType.IDispatch)] object args); }
    [ComImport, Guid("8C3F1CDD-6173-4591-AEBD-A56A53CA77C1"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IDownloadProgressChangedCallback { void Invoke([MarshalAs(UnmanagedType.IDispatch)] object job, [MarshalAs(UnmanagedType.IDispatch)] object args); }
    [ComImport, Guid("77254866-9F5B-4C8E-B9E2-C77A8530D64B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IDownloadCompletedCallback { void Invoke([MarshalAs(UnmanagedType.IDispatch)] object job, [MarshalAs(UnmanagedType.IDispatch)] object args); }
    [ComImport, Guid("E01402D5-F8DA-43BA-A012-38894BD048F1"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IInstallationProgressChangedCallback { void Invoke([MarshalAs(UnmanagedType.IDispatch)] object job, [MarshalAs(UnmanagedType.IDispatch)] object args); }
    [ComImport, Guid("45F4F6F3-D602-4F98-9A8A-3EFA152AD2D3"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IInstallationCompletedCallback { void Invoke([MarshalAs(UnmanagedType.IDispatch)] object job, [MarshalAs(UnmanagedType.IDispatch)] object args); }

    [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
    public class NoopCallback : ISearchCompletedCallback, IDownloadProgressChangedCallback, IDownloadCompletedCallback,
                                IInstallationProgressChangedCallback, IInstallationCompletedCallback {
        public void Invoke(object job, object args) { }
    }
}
'@
    }
    $cb = New-Object WuCli.NoopCallback

    Write-Line '  WINDOWS UPDATE' White
    Write-Line

    # ------------------------------------------------------------ search
    $session  = New-Object -ComObject Microsoft.Update.Session
    $session.ClientApplicationID = 'wu-cli'
    $searcher = $session.CreateUpdateSearcher()

    $source = 'Windows Update'
    if (-not $NoMicrosoftUpdate) {
        $muId = '7971f918-a847-4430-9279-4a52d1efe18d'
        $sm = New-Object -ComObject Microsoft.Update.ServiceManager
        $mu = $sm.Services | Where-Object { $_.ServiceID -eq $muId }
        if ($mu) {
            $searcher.ServerSelection = 3   # ssOthers
            $searcher.ServiceID = $muId
            $source = 'Microsoft Update'
        }
    }

    $criteria = 'IsInstalled=0 and IsHidden=0'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $result = $null
    try {
        $job = $searcher.BeginSearch($criteria, $cb, $null)
        $i = 0
        try {
            while (-not $job.IsCompleted) {
                Write-Status ("  {0} Checking {1} for updates...  {2}" -f $spin[$i++ % 4], $source, (Format-Elapsed $sw.Elapsed))
                Start-Sleep -Milliseconds 150
            }
            $result = $searcher.EndSearch($job)
        } finally {
            if (-not $job.IsCompleted) { $job.RequestAbort() }
        }
    } catch [System.Management.Automation.PipelineStoppedException] {
        throw
    } catch {
        if ($null -eq $result) {
            # Fallback: synchronous search (no spinner) if async is unavailable.
            Write-Status ("  Checking {0} for updates..." -f $source)
            try { $result = $searcher.Search($criteria) }
            catch { Write-Line; Write-Line ("  Search failed: {0}" -f $_.Exception.Message) Red; return }
        }
    }
    Write-Status ("  Checked {0} in {1}" -f $source, (Format-Elapsed $sw.Elapsed)) DarkGray
    Write-Line

    # ------------------------------------------------------------ classify
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($u in $result.Updates) {
        $class = ($u.Categories | Where-Object { $_.Type -eq 'UpdateClassification' } | Select-Object -First 1).Name
        if ($u.Type -eq 2) {
            $group = 'Drivers'; $label = 'Driver'
        } elseif ($u.BrowseOnly) {
            $group = 'Optional'; $label = if ($class) { $class } else { 'Optional' }
        } else {
            $group = 'Recommended'; $label = if ($class) { $class } else { 'Update' }
        }
        if ($u.MsrcSeverity) { $label = "$label ($($u.MsrcSeverity))" }
        $kb = if ($u.KBArticleIDs.Count -gt 0) { 'KB' + $u.KBArticleIDs.Item(0) } else { '' }
        $list.Add([pscustomobject]@{
            Group  = $group
            Label  = $label
            KB     = $kb
            Title  = $u.Title
            # Defender definitions report the full engine package as max size; the real delta is tiny.
            Size   = if ($class -eq 'Definition Updates') { [double]$u.MinDownloadSize } else { [double]$u.MaxDownloadSize }
            Reboot = ($u.InstallationBehavior.RebootBehavior -ne 0)
            Update = $u
        })
    }
    $order = @{ Recommended = 0; Optional = 1; Drivers = 2 }
    $items = @($list | Sort-Object { $order[$_.Group] }, Title)
    for ($n = 0; $n -lt $items.Count; $n++) { $items[$n] | Add-Member -NotePropertyName Index -NotePropertyValue ($n + 1) }

    if ($items.Count -eq 0) {
        Write-Line
        Write-Line '  You''re up to date. No updates available.' Green
        Write-Line
        return
    }

    # ------------------------------------------------------------ list
    function Show-List {
        $w = Get-ConsoleWidth
        $titleW = [Math]::Max(20, $w - 56)
        foreach ($g in 'Recommended', 'Optional', 'Drivers') {
            $rows = @($items | Where-Object Group -eq $g)
            if (-not $rows) { continue }
            $total = ($rows | Measure-Object Size -Sum).Sum
            $color = @{ Recommended = 'Green'; Optional = 'Yellow'; Drivers = 'Magenta' }[$g]
            Write-Line
            Write-Line ("  {0} ({1})  {2}" -f $g.ToUpper(), $rows.Count, (Format-Size $total)) $color
            Write-Line ('  ' + ('-' * ($w - 4))) DarkGray
            foreach ($r in $rows) {
                Write-Line ('  {0,3}  ' -f $r.Index) White -NoNewline
                Write-Line ('{0,-26}' -f (Limit-Text $r.Label 26)) DarkCyan -NoNewline
                Write-Line ('{0,-10}' -f $r.KB) Gray -NoNewline
                $sz = if ($r.Size -gt 0) { Format-Size $r.Size } else { 'small' }
                Write-Line ('{0,9}  ' -f $sz) DarkGray -NoNewline
                $t = Limit-Text $r.Title $titleW
                if ($r.Reboot) { $t = Limit-Text $r.Title ($titleW - 3); Write-Line $t -NoNewline; Write-Line ' *R' DarkYellow }
                else { Write-Line $t }
            }
        }
        Write-Line
        Write-Line '  *R = may require a restart' DarkGray
    }
    Show-List

    if ($ListOnly) { Write-Line; return }

    # ------------------------------------------------------------ selection
    function Resolve-Selection([string]$text) {
        $sel = New-Object System.Collections.Generic.HashSet[int]
        foreach ($tok in ($text -split '[,\s]+' | Where-Object { $_ })) {
            switch -Regex ($tok.ToLower()) {
                '^(a|all)$'     { $items | ForEach-Object { [void]$sel.Add($_.Index) }; continue }
                '^(r|rec)$'     { $items | Where-Object Group -eq 'Recommended' | ForEach-Object { [void]$sel.Add($_.Index) }; continue }
                '^(o|opt)$'     { $items | Where-Object Group -eq 'Optional'    | ForEach-Object { [void]$sel.Add($_.Index) }; continue }
                '^(d|drv)$'     { $items | Where-Object Group -eq 'Drivers'     | ForEach-Object { [void]$sel.Add($_.Index) }; continue }
                '^(\d+)-(\d+)$' { [int]$matches[1]..[int]$matches[2] | ForEach-Object { [void]$sel.Add($_) }; continue }
                '^\d+$'         { [void]$sel.Add([int]$tok); continue }
                default         { throw "Didn't understand '$tok'" }
            }
        }
        @($sel | Where-Object { $_ -ge 1 -and $_ -le $items.Count } | Sort-Object | ForEach-Object { $items[$_ - 1] })
    }

    $selected = @()
    if ($Install) {
        $map = @{ Recommended = 'r'; Optional = 'o'; Drivers = 'd'; All = 'a' }
        $selected = @(Resolve-Selection (($Install | ForEach-Object { $map[$_] }) -join ' '))
    } else {
        $hasRec = [bool]($items | Where-Object Group -eq 'Recommended')
        while ($true) {
            Write-Line
            Write-Line '  Choose updates:  ' White -NoNewline
            Write-Line 'r' Green -NoNewline; Write-Line '=recommended  ' -NoNewline
            Write-Line 'o' Yellow -NoNewline; Write-Line '=optional  ' -NoNewline
            Write-Line 'd' Magenta -NoNewline; Write-Line '=drivers  ' -NoNewline
            Write-Line 'a' White -NoNewline; Write-Line '=all  ' -NoNewline
            Write-Line '1,3,5-7' White -NoNewline; Write-Line '=numbers'
            Write-Line '                   h 1,3=hide   l=list again   q=quit' DarkGray
            $default = if ($hasRec) { 'r' } else { 'q' }
            $answer = Read-Host "  Selection [$default]"
            if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $default }
            $answer = $answer.Trim()
            if ($answer -match '^(q|quit|exit)$') { Write-Line '  Nothing installed.' DarkGray; return }
            if ($answer -match '^(l|list)$') { Show-List; continue }
            if ($answer -match '^h(ide)?\s+(.+)$') {
                try {
                    foreach ($h in (Resolve-Selection $matches[2])) {
                        $h.Update.IsHidden = $true
                        Write-Line ("  Hidden: {0}" -f $h.Title) DarkGray
                    }
                } catch { Write-Line "  $($_.Exception.Message)" Red }
                continue
            }
            try { $selected = @(Resolve-Selection $answer) } catch { Write-Line "  $($_.Exception.Message)" Red; continue }
            if ($selected.Count -eq 0) { Write-Line '  Nothing selected.' Yellow; continue }
            $hidden = @($selected | Where-Object { $_.Update.IsHidden })
            $selected = @($selected | Where-Object { -not $_.Update.IsHidden })
            if ($hidden) { Write-Line ("  Skipping {0} hidden update(s)." -f $hidden.Count) DarkGray }
            break
        }
    }
    if ($selected.Count -eq 0) { Write-Line '  Nothing to install.' Yellow; return }

    $totalSize = ($selected | Measure-Object Size -Sum).Sum
    Write-Line
    if ($totalSize -gt 0) {
        Write-Line ("  Installing {0} update(s), up to {1} to download." -f $selected.Count, (Format-Size $totalSize)) White
    } else {
        Write-Line ("  Installing {0} update(s)." -f $selected.Count) White
    }
    Write-Line '  Ctrl+C aborts the current step.' DarkGray

    foreach ($s in $selected) {
        if (-not $s.Update.EulaAccepted) { $s.Update.AcceptEula() }
    }

    # ------------------------------------------------------------ download
    $count = $selected.Count
    $results = @{}
    Write-Line
    Write-Line '  DOWNLOAD' Cyan
    $k = 0
    foreach ($s in $selected) {
        $k++
        $head = "  [{0}/{1}] {2}" -f $k, $count, $s.Title
        Write-Line (Limit-Text $head ((Get-ConsoleWidth) - 1)) White
        if ($s.Update.IsDownloaded) {
            Write-Status ("        {0} 100%  already downloaded" -f (Get-Bar 100)) DarkGray; Write-Line
            continue
        }
        $coll = New-Object -ComObject Microsoft.Update.UpdateColl
        [void]$coll.Add($s.Update)
        $dl = $session.CreateUpdateDownloader()
        $dl.Updates = $coll
        try { $dl.Priority = 3 } catch {}
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $lastBytes = 0; $lastT = 0.0; $rate = 0.0
        try {
            $job = $dl.BeginDownload($cb, $cb, $null)
            try {
                $i = 0
                while (-not $job.IsCompleted) {
                    $p = $job.GetProgress()
                    $done = [double]$p.TotalBytesDownloaded
                    $tot  = [double]$p.TotalBytesToDownload
                    $t = $sw.Elapsed.TotalSeconds
                    if ($t - $lastT -ge 1) {
                        $inst = ($done - $lastBytes) / ($t - $lastT)
                        $rate = if ($rate -eq 0) { $inst } else { 0.6 * $rate + 0.4 * $inst }
                        $lastBytes = $done; $lastT = $t
                    }
                    $phase = switch ($p.CurrentUpdateDownloadPhase) { 1 { 'starting' } 3 { 'verifying' } default { '' } }
                    $detail = if ($tot -gt 0) { '{0} / {1}' -f (Format-Size $done), (Format-Size $tot) } else { 'waiting for server' }
                    if ($rate -gt 0 -and $phase -eq '') { $detail += '  {0}/s' -f (Format-Size $rate) }
                    if ($phase) { $detail += "  $phase" }
                    Write-Status ("      {0} {1} {2,3}%  {3}  {4}" -f $spin[$i++ % 4], (Get-Bar $p.PercentComplete), $p.PercentComplete, $detail, (Format-Elapsed $sw.Elapsed))
                    Start-Sleep -Milliseconds 250
                }
                $r = $dl.EndDownload($job)
            } finally {
                if (-not $job.IsCompleted) { $job.RequestAbort(); Write-Line; Write-Line '  Download aborted.' Yellow }
            }
            $ur = $r.GetUpdateResult(0)
            if ($ur.ResultCode -in 2, 3) {
                $sizeNote = if ($s.Size -gt 0) { (Format-Size $s.Size) + '  ' } else { '' }
                Write-Status ("        {0} 100%  {1}downloaded in {2}" -f (Get-Bar 100), $sizeNote, (Format-Elapsed $sw.Elapsed)) Green
            } else {
                Write-Status ("        download FAILED  {0}" -f (Format-HResult $ur.HResult)) Red
                $results[$s.Index] = 'Download failed: ' + (Format-HResult $ur.HResult)
            }
        } catch [System.Management.Automation.PipelineStoppedException] {
            throw
        } catch {
            Write-Status ("        download FAILED  {0}" -f $_.Exception.Message) Red
            $results[$s.Index] = 'Download failed: ' + $_.Exception.Message
        }
        Write-Line
    }

    # ------------------------------------------------------------ install
    $toInstall = @($selected | Where-Object { -not $results.ContainsKey($_.Index) })
    $rebootNeeded = $false

    # Quick local (offline) lookups, used to see whether Windows Update's own background
    # service has installed - or superseded - an update while we were working.
    $checker = $session.CreateUpdateSearcher()
    $checker.Online = $false
    function Get-UpdateState($u) {
        try {
            $id = $u.Identity.UpdateID
            if ($checker.Search("UpdateID='$id' and IsInstalled=1").Updates.Count -gt 0) { return 'Installed' }
            if ($checker.Search("UpdateID='$id' and IsInstalled=0").Updates.Count -gt 0) { return 'Pending' }
            return 'Gone'
        } catch { return 'Unknown' }
    }

    # Waits while Windows Update is installing in the background.
    #  - Installer.IsBusy: a Windows Update install is running. Always wait for this.
    #  - TiWorker busy on the CPU: Windows is servicing components (often a background
    #    update finishing). TiWorker also lingers idle for a while, so only CPU use counts.
    #    Waited on for up to $SoftLimit seconds; Enter skips the wait.
    function Get-TiWorkerCpu {
        $t = 0.0
        foreach ($p in @(Get-Process TiWorker -ErrorAction SilentlyContinue)) { try { $t += $p.TotalProcessorTime.TotalSeconds } catch {} }
        $t
    }
    function Wait-WUIdle([int]$SoftLimit = 120) {
        $probe = New-Object -ComObject Microsoft.Update.Installer
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $i = 0; $waited = $false
        $cpu0 = Get-TiWorkerCpu; Start-Sleep -Milliseconds 1000
        while ($true) {
            $busy = $false; try { $busy = $probe.IsBusy } catch {}
            $cpu1 = Get-TiWorkerCpu
            $servicing = ($cpu1 - $cpu0) -gt 0.05   # more than ~5% of a core over the last second or so
            $cpu0 = $cpu1
            if (-not $busy -and -not $servicing) { break }
            if (-not $busy -and $sw.Elapsed.TotalSeconds -ge $SoftLimit) { break }
            try {
                if ([Console]::KeyAvailable -and [Console]::ReadKey($true).Key -eq 'Enter' -and -not $busy) { break }
            } catch {}
            $waited = $true
            $why = if ($busy) { 'Windows Update is installing updates in the background' } else { 'Windows is finishing background servicing - Enter skips' }
            Write-Status ("      {0} waiting: {1}  {2}" -f $spin[$i++ % 4], $why, (Format-Elapsed $sw.Elapsed)) Yellow
            Start-Sleep -Milliseconds 1000
        }
        if ($waited) { Write-Status '' }
    }

    function Invoke-OneInstall($s) {
        $coll = New-Object -ComObject Microsoft.Update.UpdateColl
        [void]$coll.Add($s.Update)
        $inst = $session.CreateUpdateInstaller()
        $inst.Updates = $coll
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $job = $inst.BeginInstall($cb, $cb, $null)
        try {
            $i = 0
            while (-not $job.IsCompleted) {
                $pct = $job.GetProgress().CurrentUpdatePercentComplete
                Write-Status ("      {0} {1} {2,3}%  installing  {3}" -f $spin[$i++ % 4], (Get-Bar $pct), $pct, (Format-Elapsed $sw.Elapsed))
                Start-Sleep -Milliseconds 250
            }
            $r = $inst.EndInstall($job)
        } finally {
            if (-not $job.IsCompleted) { $job.RequestAbort(); Write-Line; Write-Line '  Install abort requested.' Yellow }
        }
        $ur = $r.GetUpdateResult(0)
        # The per-update code is often 0 when the whole request was refused; fall back to the overall one.
        $hr = if ($ur.HResult -ne 0) { $ur.HResult } else { $r.HResult }
        [pscustomobject]@{ Code = $ur.ResultCode; HResult = $hr; Reboot = $ur.RebootRequired; Elapsed = $sw.Elapsed }
    }

    $codeName = @{ 0 = 'not started'; 1 = 'still in progress'; 4 = 'failed'; 5 = 'aborted' }

    if ($toInstall.Count -gt 0) {
        Write-Line
        Write-Line '  INSTALL' Cyan

        $probe = $session.CreateUpdateInstaller()
        if ($probe.RebootRequiredBeforeInstallation) {
            Write-Line '  Windows needs a restart before it can install more updates.' Yellow
            Write-Line '  Restart, then run wu again (downloads are kept).' Yellow
            foreach ($s in $toInstall) { $results[$s.Index] = 'Not installed: restart Windows first' }
            $toInstall = @()
            $rebootNeeded = $true
        }

        $k = 0
        foreach ($s in $toInstall) {
            $k++
            $head = "  [{0}/{1}] {2}" -f $k, $toInstall.Count, $s.Title
            Write-Line (Limit-Text $head ((Get-ConsoleWidth) - 1)) White
            try {
                $attempt = 0
                while ($true) {
                    $attempt++
                    # Windows Update may have installed it in the background while we downloaded.
                    $state = Get-UpdateState $s.Update
                    if ($state -eq 'Installed') {
                        Write-Status ("        {0} 100%  already installed by Windows Update" -f (Get-Bar 100)) Green
                        $results[$s.Index] = 'Installed (by Windows Update)'
                        break
                    }
                    if ($state -eq 'Gone') {
                        Write-Status '        no longer needed (replaced by a newer update)' DarkGray
                        $results[$s.Index] = 'Skipped: replaced by newer update'
                        break
                    }

                    Wait-WUIdle
                    $res = Invoke-OneInstall $s

                    if ($res.Code -eq 2) {
                        if ($res.Reboot) { $rebootNeeded = $true }
                        $msg = if ($res.Reboot) { 'installed - restart required' } else { 'installed' }
                        Write-Status ("        {0} 100%  {1}  ({2})" -f (Get-Bar 100), $msg, (Format-Elapsed $res.Elapsed)) Green
                        $results[$s.Index] = if ($res.Reboot) { 'Installed (restart required)' } else { 'Installed' }
                        break
                    }
                    if ($res.Code -eq 3) {
                        if ($res.Reboot) { $rebootNeeded = $true }
                        Write-Status ("        installed with errors  {0}" -f (Format-HResult $res.HResult)) Yellow
                        $results[$s.Index] = 'Installed with errors: ' + (Format-HResult $res.HResult)
                        break
                    }

                    # Failed / aborted / not started. If Windows Update was busy with this same
                    # update in the background, it is either done now or will be shortly.
                    $state = Get-UpdateState $s.Update
                    if ($state -eq 'Installed') {
                        Write-Status ("        {0} 100%  installed by Windows Update in the background" -f (Get-Bar 100)) Green
                        $results[$s.Index] = 'Installed (by Windows Update)'
                        break
                    }
                    if ($attempt -lt 2) {
                        Write-Status ("        Windows refused the install ({0}) - waiting for background updates, then retrying..." -f $codeName[[int]$res.Code]) Yellow
                        Write-Line
                        Start-Sleep 5
                        continue
                    }
                    $why = Format-HResult $res.HResult
                    if ($res.HResult -eq 0) { $why = "no error code given - Windows Update may still be busy; try again in a few minutes" }
                    Write-Status ("        install {0}  {1}" -f $codeName[[int]$res.Code].ToUpper(), $why) Red
                    $results[$s.Index] = 'Install failed: ' + (Format-HResult $res.HResult)
                    break
                }
            } catch [System.Management.Automation.PipelineStoppedException] {
                throw
            } catch {
                Write-Status ("        install FAILED  {0}" -f $_.Exception.Message) Red
                $results[$s.Index] = 'Install failed: ' + $_.Exception.Message
            }
            Write-Line
        }
    }

    # ------------------------------------------------------------ summary
    Write-Line
    Write-Line '  SUMMARY' Cyan
    foreach ($s in $selected) {
        $st = $results[$s.Index]
        $c = if ($st -like 'Installed*errors*') { 'Yellow' } elseif ($st -like 'Installed*') { 'Green' } elseif ($st -like 'Skipped*') { 'DarkGray' } else { 'Red' }
        Write-Line ('  {0,-34}' -f (Limit-Text $st 34)) $c -NoNewline
        Write-Line (Limit-Text $s.Title ((Get-ConsoleWidth) - 38))
    }

    try { if ((New-Object -ComObject Microsoft.Update.SystemInfo).RebootRequired) { $rebootNeeded = $true } } catch {}
    Write-Line
    if ($rebootNeeded) {
        Write-Line '  A restart is required to finish installing updates.' Yellow
        if ($AutoReboot) {
            Write-Line '  Restarting in 15 seconds (Ctrl+C to cancel)...' Yellow
            Start-Sleep 15
            Restart-Computer -Force
        } elseif (-not $Install) {
            $a = Read-Host '  Restart now? [y/N]'
            if ($a -match '^(y|yes)$') { Restart-Computer -Force }
        }
    } else {
        Write-Line '  Done. No restart needed.' Green
    }
    Write-Line
    }   # end Invoke-WindowsUpdatePart

    # ================================================================ WINGET
    # winget exit codes, shared by option 2 (upgrades) and option 9 (install PDFcraft).
    $wgText = @{
        '8A15002B' = 'no applicable upgrade for this system'
        '8A150014' = 'package not found'
        '8A150101' = 'the app is in use - close it and retry'
        '8A150109' = 'restart needed to finish'
        '8A150010' = 'no installer for this PC''s architecture (e.g. ARM64) - update this app another way'
    }
    function Format-WingetCode([int]$code) {
        $hex = '{0:X8}' -f $code
        if ($wgText.ContainsKey($hex)) { "0x$hex ($($wgText[$hex]))" } else { "0x$hex" }
    }

    function Invoke-WingetPart {
        Write-Line '  WINGET APP UPGRADES' White
        Write-Line
        $wg = Get-Command winget.exe -ErrorAction SilentlyContinue
        if (-not $wg) {
            Write-Line '  winget was not found. Install "App Installer" from the Microsoft Store, then try again.' Red
            Write-Line
            return
        }

        # Runs winget with its output captured to a file, showing a spinner meanwhile.
        function Invoke-WingetCapture([string[]]$WgArgs, [string]$Message) {
            $out = Join-Path $env:TEMP ('wu-winget-{0}.txt' -f [guid]::NewGuid().ToString('N'))
            $err = "$out.err"
            $p = Start-Process -FilePath $wg.Source -ArgumentList $WgArgs -NoNewWindow -PassThru `
                    -RedirectStandardOutput $out -RedirectStandardError $err
            $null = $p.Handle   # makes ExitCode available afterwards in Windows PowerShell
            $sw = [Diagnostics.Stopwatch]::StartNew(); $i = 0
            while (-not $p.HasExited) {
                Write-Status ("  {0} {1}  {2}" -f $spin[$i++ % 4], $Message, (Format-Elapsed $sw.Elapsed))
                Start-Sleep -Milliseconds 150
            }
            $p.WaitForExit()
            $text = if (Test-Path $out) { [string](Get-Content -Raw -Encoding UTF8 $out) } else { '' }
            Remove-Item $out, $err -ErrorAction SilentlyContinue
            # winget redraws its spinner with carriage returns; keep what each line ends with.
            $lines = @($text -split "`r?`n" | ForEach-Object { ($_ -split "`r")[-1] -replace "$([char]27)\[[0-9;?]*[A-Za-z]", '' })
            [pscustomobject]@{ ExitCode = $p.ExitCode; Elapsed = $sw.Elapsed; Lines = $lines }
        }

        # Parses winget's fixed-width tables (header line, then a line of dashes, then rows).
        # The first table is normal upgrades; later ones are packages that need explicit targeting.
        function ConvertFrom-WingetTables([string[]]$Lines) {
            $found = New-Object System.Collections.Generic.List[object]
            $tableNo = 0
            for ($i = 0; $i -lt $Lines.Count - 1; $i++) {
                if ($Lines[$i + 1] -notmatch '^-{10,}\s*$') { continue }
                $starts = @([regex]::Matches($Lines[$i], '\S+') | ForEach-Object { $_.Index })
                if ($starts.Count -lt 4) { continue }
                $j = $i + 2
                for (; $j -lt $Lines.Count; $j++) {
                    $line = $Lines[$j]
                    if ($line.Length -le $starts[3] -or $line -match '^\s') { break }
                    $cells = for ($c = 0; $c -lt $starts.Count; $c++) {
                        $a = $starts[$c]
                        $b = if ($c + 1 -lt $starts.Count) { $starts[$c + 1] } else { $line.Length }
                        $b = [Math]::Min($b, $line.Length)
                        if ($a -ge $b) { '' } else { $line.Substring($a, $b - $a).Trim() }
                    }
                    if (-not $cells[1] -or $cells[1] -match '\s') { break }   # Id never has spaces
                    $found.Add([pscustomobject]@{
                        Group     = if ($tableNo -eq 0) { 'Upgrades' } else { 'Explicit' }
                        Name      = $cells[0]
                        Id        = $cells[1]
                        Version   = $cells[2]
                        Available = $cells[3]
                        Source    = if ($cells.Count -gt 4) { $cells[4] } else { '' }
                    })
                }
                $tableNo++
                $i = $j
            }
            $found
        }

        $scan = Invoke-WingetCapture @('upgrade', '--accept-source-agreements') 'Checking winget for app upgrades...'
        Write-Status ("  Checked winget in {0}" -f (Format-Elapsed $scan.Elapsed)) DarkGray
        Write-Line

        $apps = @(ConvertFrom-WingetTables $scan.Lines)
        for ($n = 0; $n -lt $apps.Count; $n++) { $apps[$n] | Add-Member -NotePropertyName Index -NotePropertyValue ($n + 1) }

        if ($apps.Count -eq 0) {
            $msg = ($scan.Lines | Where-Object { $_.Trim() } | Select-Object -Last 1)
            Write-Line
            if ($scan.ExitCode -ne 0 -and $msg) { Write-Line "  winget: $msg" Yellow }
            else { Write-Line '  All apps are up to date.' Green }
            Write-Line
            return
        }

        function Show-AppList {
            $w = Get-ConsoleWidth
            $nameW = [Math]::Max(16, [Math]::Min(40, [int](($w - 40) * 0.5)))
            $idW   = [Math]::Max(14, [Math]::Min(32, $w - $nameW - 44))
            foreach ($g in 'Upgrades', 'Explicit') {
                $rows = @($apps | Where-Object Group -eq $g)
                if (-not $rows) { continue }
                Write-Line
                if ($g -eq 'Upgrades') { Write-Line ("  APP UPGRADES ({0})" -f $rows.Count) Green }
                else { Write-Line ("  NEED EXPLICIT UPGRADE ({0})  pinned, or the installer manages its own updates" -f $rows.Count) Yellow }
                Write-Line ('  ' + ('-' * ($w - 4))) DarkGray
                foreach ($r in $rows) {
                    Write-Line ('  {0,3}  ' -f $r.Index) White -NoNewline
                    Write-Line (("{0,-$nameW}" -f (Limit-Text $r.Name $nameW)) + '  ') -NoNewline
                    Write-Line (("{0,-$idW}" -f (Limit-Text $r.Id $idW)) + '  ') DarkCyan -NoNewline
                    Write-Line (Limit-Text $r.Version 16) DarkGray -NoNewline
                    Write-Line ' -> ' DarkGray -NoNewline
                    Write-Line (Limit-Text $r.Available 16) Green
                }
            }
        }
        Show-AppList
        Write-Line

        if ($ListOnly) { return }

        function Resolve-AppSelection([string]$text) {
            $sel = New-Object System.Collections.Generic.HashSet[int]
            foreach ($tok in ($text -split '[,\s]+' | Where-Object { $_ })) {
                switch -Regex ($tok.ToLower()) {
                    '^(u|up)$'      { $apps | Where-Object Group -eq 'Upgrades' | ForEach-Object { [void]$sel.Add($_.Index) }; continue }
                    '^(a|all)$'     { $apps | ForEach-Object { [void]$sel.Add($_.Index) }; continue }
                    '^(\d+)-(\d+)$' { [int]$matches[1]..[int]$matches[2] | ForEach-Object { [void]$sel.Add($_) }; continue }
                    '^\d+$'         { [void]$sel.Add([int]$tok); continue }
                    default         { throw "Didn't understand '$tok'" }
                }
            }
            @($sel | Where-Object { $_ -ge 1 -and $_ -le $apps.Count } | Sort-Object | ForEach-Object { $apps[$_ - 1] })
        }

        $chosen = @()
        if ($Install) {
            $chosen = @(Resolve-AppSelection 'u')
        } else {
            $hasUp = [bool]($apps | Where-Object Group -eq 'Upgrades')
            while ($true) {
                Write-Line '  Choose apps:  ' White -NoNewline
                Write-Line 'u' Green -NoNewline; Write-Line '=all upgrades  ' -NoNewline
                if ($apps | Where-Object Group -eq 'Explicit') { Write-Line 'a' Yellow -NoNewline; Write-Line '=everything  ' -NoNewline }
                Write-Line '1,3,5-7' White -NoNewline; Write-Line '=numbers  ' -NoNewline
                Write-Line 'l=list again  q=quit' DarkGray
                $default = if ($hasUp) { 'u' } else { 'q' }
                $answer = Read-Host "  Selection [$default]"
                if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $default }
                $answer = $answer.Trim()
                if ($answer -match '^(q|quit|exit)$') { Write-Line '  Nothing upgraded.' DarkGray; Write-Line; return }
                if ($answer -match '^(l|list)$') { Show-AppList; Write-Line; continue }
                try { $chosen = @(Resolve-AppSelection $answer) } catch { Write-Line "  $($_.Exception.Message)" Red; continue }
                if ($chosen.Count -eq 0) { Write-Line '  Nothing selected.' Yellow; continue }
                break
            }
        }
        if ($chosen.Count -eq 0) { Write-Line '  Nothing to upgrade.' Yellow; return }

        Write-Line
        Write-Line ("  Upgrading {0} app(s). winget shows the download progress for each one." -f $chosen.Count) White
        Write-Line '  Close any app being upgraded if you can - installers fail on apps in use.' DarkGray

        $appResults = @{}
        $restart = $false
        $k = 0
        foreach ($s in $chosen) {
            $k++
            Write-Line
            Write-Line ("  [{0}/{1}] " -f $k, $chosen.Count) White -NoNewline
            Write-Line $s.Name White -NoNewline
            Write-Line ("  {0} -> {1}" -f $s.Version, $s.Available) DarkGray
            $wgArgs = @('upgrade', '--id', $s.Id, '--exact', '--silent',
                        '--accept-package-agreements', '--accept-source-agreements')
            if ($s.Source) { $wgArgs += @('--source', $s.Source) }
            $sw = [Diagnostics.Stopwatch]::StartNew()
            try {
                # Runs in this console so winget's own progress bar shows live.
                $p = Start-Process -FilePath $wg.Source -ArgumentList $wgArgs -NoNewWindow -PassThru
                $null = $p.Handle
                $p.WaitForExit()
                $code = [int]$p.ExitCode
            } catch {
                $code = -1
            }
            $hex = '{0:X8}' -f $code
            if ($code -eq 0) {
                Write-Line ("        upgraded  ({0})" -f (Format-Elapsed $sw.Elapsed)) Green
                $appResults[$s.Index] = 'Upgraded'
            } elseif ($hex -eq '8A150109') {
                Write-Line '        upgraded - restart needed to finish' Green
                $appResults[$s.Index] = 'Upgraded (restart required)'
                $restart = $true
            } else {
                Write-Line ("        upgrade FAILED  {0}" -f (Format-WingetCode $code)) Red
                $appResults[$s.Index] = 'Failed: ' + (Format-WingetCode $code)
            }
        }

        Write-Line
        Write-Line '  SUMMARY' Cyan
        foreach ($s in $chosen) {
            $st = $appResults[$s.Index]
            $c = if ($st -like 'Upgraded*') { 'Green' } else { 'Red' }
            Write-Line ('  {0,-34}' -f (Limit-Text $st 34)) $c -NoNewline
            Write-Line (Limit-Text ("{0}  {1}" -f $s.Name, $s.Available) ((Get-ConsoleWidth) - 38))
        }
        Write-Line
        if ($restart) { Write-Line '  Restart Windows to finish some upgrades.' Yellow }
        else { Write-Line '  Done.' Green }
        Write-Line
    }   # end Invoke-WingetPart

    # ================================================================ WINDOWS POWERSHELL 5.1
    # Starts Windows PowerShell 5.1 in this window and waits for it. PowerShell 7 puts its own
    # module folders in PSModulePath, and a 5.1 child inheriting that can't load its built-in
    # modules (e.g. "Get-FileHash is not recognized"). So the child gets the module path a
    # fresh Windows PowerShell would have.
    function Start-WindowsPowerShell([string[]]$ArgumentList) {
        $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $saved = $env:PSModulePath
        try {
            $env:PSModulePath = (@(
                [Environment]::GetEnvironmentVariable('PSModulePath', 'User'),
                [Environment]::GetEnvironmentVariable('PSModulePath', 'Machine')
            ) | Where-Object { $_ }) -join ';'
            $p = Start-Process -FilePath $ps51 -ArgumentList $ArgumentList -NoNewWindow -PassThru
            $null = $p.Handle   # makes ExitCode available afterwards in Windows PowerShell
        } finally {
            $env:PSModulePath = $saved
        }
        $p.WaitForExit()
        $p
    }

    # ================================================================ MICROSOFT STORE
    # Uses the Store's own update API (Windows.ApplicationModel.Store.Preview.InstallControl).
    # PowerShell 7 can't call Windows Runtime APIs, so this part always runs in Windows
    # PowerShell 5.1 (built into Windows) in this same console window.
    function Invoke-StorePart {
        $body = @'
$ErrorActionPreference = 'Stop'
Write-Line '  MICROSOFT STORE APP UPDATES' White
Write-Line
try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $AIM  = [Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallManager, Windows.ApplicationModel.Store.Preview, ContentType = WindowsRuntime]
    $Item = [Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallItem, Windows.ApplicationModel.Store.Preview, ContentType = WindowsRuntime]
    $Opt  = [Windows.ApplicationModel.Store.Preview.InstallControl.AppUpdateOptions, Windows.ApplicationModel.Store.Preview, ContentType = WindowsRuntime]
    $PM   = [Windows.Management.Deployment.PackageManager, Windows.Management.Deployment, ContentType = WindowsRuntime]
    $aim  = $AIM::new()
    $pm   = $PM::new()
} catch {
    Write-Line '  The Microsoft Store update service is not available on this PC.' Red
    Write-Line
    exit 1
}

$asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
function Wait-Op($op, [Type]$type, [string]$msg) {
    $task = $asTask.MakeGenericMethod($type).Invoke($null, @($op))
    $sw = [Diagnostics.Stopwatch]::StartNew(); $i = 0
    while ($true) {
        # Wait() throws a generic "One or more errors occurred" when the Store reports an
        # error; the real error is unwrapped below.
        $finished = $false
        try { $finished = $task.Wait(150) } catch { $finished = $true }
        if ($finished) { break }
        if ($msg) { Write-Status ("  {0} {1}  {2}" -f $spin[$i++ % 4], $msg, (Format-Elapsed $sw.Elapsed)) }
    }
    if ($task.IsFaulted) {
        $ex = $task.Exception
        while ($ex -is [AggregateException] -and $ex.InnerException) { $ex = $ex.InnerException }
        throw $ex
    }
    if ($task.IsCanceled) { throw (New-Object OperationCanceledException 'The Store cancelled the request') }
    $task.Result
}

$storeText = @{
    '80073D02' = 'the app is open - close it and try again'
    '80073CF3' = 'a component it depends on could not be updated'
    '80073CF9' = 'the install failed'
    '80070005' = 'access denied'
    '803F8001' = 'not available for this Microsoft account'
    '80072EE7' = 'no internet connection'
    '80072EFD' = 'cannot reach the Microsoft Store'
}
function Format-StoreCode([int]$hr) {
    $hex = '{0:X8}' -f $hr
    if ($storeText.ContainsKey($hex)) { "0x$hex ($($storeText[$hex]))" } else { "0x$hex" }
}
function Format-StoreError($ex) {
    $hr = 0; try { $hr = [int]$ex.HResult } catch {}
    if ($hr -lt 0) {
        $hex = '{0:X8}' -f $hr
        if ($storeText.ContainsKey($hex)) { return Format-StoreCode $hr }
        $msg = ([string]$ex.Message -split "`r?`n")[0].Trim()
        if ($msg -and $msg -notmatch 'Exception from HRESULT') { return "0x$hex $msg" }
        return "0x$hex"
    }
    [string]$ex.Message
}
function Get-PackageInfo([string]$pfn) {
    $pkg = $null
    try { $pkg = @($pm.FindPackagesForUser('', $pfn)) | Select-Object -First 1 } catch {}
    $name = $null; try { $name = $pkg.DisplayName } catch {}
    if (-not $name) { $name = ($pfn -split '_')[0] }
    $ver = ''
    if ($pkg) { $v = $pkg.Id.Version; $ver = '{0}.{1}.{2}.{3}' -f $v.Major, $v.Minor, $v.Build, $v.Revision }
    [pscustomobject]@{ Name = $name; Version = $ver }
}

# --- search without installing anything
$opt = $Opt::new()
$opt.AutomaticallyDownloadAndInstallUpdateIfFound = $false
$listType = [System.Collections.Generic.IReadOnlyList``1].MakeGenericType($Item)
$sw = [Diagnostics.Stopwatch]::StartNew()
try {
    $found = Wait-Op ($aim.SearchForAllUpdatesAsync('', '', $opt)) $listType 'Checking the Microsoft Store for app updates...'
} catch {
    Write-Status ''
    Write-Line ("  Store check failed: {0}" -f $_.Exception.Message) Red
    Write-Line
    exit 1
}
Write-Status ("  Checked the Microsoft Store in {0}" -f (Format-Elapsed $sw.Elapsed)) DarkGray
Write-Line

$apps = New-Object System.Collections.Generic.List[object]
foreach ($it in @($found)) {
    if (-not $it) { continue }
    $info = Get-PackageInfo $it.PackageFamilyName
    $apps.Add([pscustomobject]@{
        Index = $apps.Count + 1; Name = $info.Name; Version = $info.Version
        Pfn = $it.PackageFamilyName; ProductId = $it.ProductId
    })
}
if ($apps.Count -eq 0) {
    Write-Line
    Write-Line '  All Microsoft Store apps are up to date.' Green
    Write-Line
    exit 0
}

function Show-StoreList {
    $w = Get-ConsoleWidth
    $nameW = [Math]::Max(20, [Math]::Min(48, $w - 44))
    Write-Line
    Write-Line ("  STORE UPDATES ({0})" -f $apps.Count) Green
    Write-Line ('  ' + ('-' * ($w - 4))) DarkGray
    foreach ($a in $apps) {
        Write-Line ('  {0,3}  ' -f $a.Index) White -NoNewline
        Write-Line (("{0,-$nameW}" -f (Limit-Text $a.Name $nameW)) + '  ') -NoNewline
        Write-Line ('{0,-18}' -f (Limit-Text $a.Version 18)) DarkGray -NoNewline
        Write-Line $a.ProductId DarkCyan
    }
}
Show-StoreList
Write-Line

if ($ListOnly) { exit 0 }

function Resolve-StoreSelection([string]$text) {
    $sel = New-Object System.Collections.Generic.HashSet[int]
    foreach ($tok in ($text -split '[,\s]+' | Where-Object { $_ })) {
        if ($tok -match '^(a|all)$') { $apps | ForEach-Object { [void]$sel.Add($_.Index) } }
        elseif ($tok -match '^(\d+)-(\d+)$') { [int]$matches[1]..[int]$matches[2] | ForEach-Object { [void]$sel.Add($_) } }
        elseif ($tok -match '^\d+$') { [void]$sel.Add([int]$tok) }
        else { throw "Didn't understand '$tok'" }
    }
    @($sel | Where-Object { $_ -ge 1 -and $_ -le $apps.Count } | Sort-Object | ForEach-Object { $apps[$_ - 1] })
}

$chosen = @()
if ($All) {
    $chosen = @($apps)
} else {
    while ($true) {
        Write-Line '  Choose apps:  ' White -NoNewline
        Write-Line 'a' Green -NoNewline; Write-Line '=all  ' -NoNewline
        Write-Line '1,3,5-7' White -NoNewline; Write-Line '=numbers  ' -NoNewline
        Write-Line 'l=list again  q=quit' DarkGray
        $answer = Read-Host '  Selection [a]'
        if ([string]::IsNullOrWhiteSpace($answer)) { $answer = 'a' }
        $answer = $answer.Trim()
        if ($answer -match '^(q|quit|exit)$') { Write-Line '  Nothing updated.' DarkGray; Write-Line; exit 0 }
        if ($answer -match '^(l|list)$') { Show-StoreList; Write-Line; continue }
        try { $chosen = @(Resolve-StoreSelection $answer) } catch { Write-Line "  $($_.Exception.Message)" Red; continue }
        if ($chosen.Count -eq 0) { Write-Line '  Nothing selected.' Yellow; continue }
        break
    }
}

Write-Line
Write-Line ("  Updating {0} Store app(s)." -f $chosen.Count) White
Write-Line '  Ctrl+C stops waiting (the Store may carry on in the background).' DarkGray

$stateText = @{
    Pending = 'queued'; ReadyToDownload = 'queued'; Starting = 'starting'; AcquiringLicense = 'getting licence'
    Downloading = 'downloading'; RestoringData = 'restoring data'; Installing = 'installing'
    Paused = 'paused'; PausedLowBattery = 'paused - low battery'
    PausedWiFiRecommended = 'paused - waiting for Wi-Fi'; PausedWiFiRequired = 'paused - needs Wi-Fi'
}
$results = @{}
$terminalSkipped = $false
# Used when the first kind of update request fails: asks the Store by product ID instead.
$optAuto = $Opt::new()
$optAuto.AutomaticallyDownloadAndInstallUpdateIfFound = $true
$k = 0
foreach ($s in $chosen) {
    $k++
    Write-Line
    Write-Line ("  [{0}/{1}] " -f $k, $chosen.Count) White -NoNewline
    Write-Line $s.Name White -NoNewline
    if ($s.Version) { Write-Line ("  {0}" -f $s.Version) DarkGray } else { Write-Line }
    $sw = [Diagnostics.Stopwatch]::StartNew()

    # Windows Terminal can't be replaced while it's running - and this menu runs inside it.
    if ($s.Pfn -like 'Microsoft.WindowsTerminal*' -and (Get-Process WindowsTerminal -ErrorAction SilentlyContinue)) {
        Write-Status '        skipped for now - Windows Terminal is open (this menu is running in it)' Yellow; Write-Line
        $results[$s.Index] = 'Later: when Terminal closes'
        $terminalSkipped = $true
        $terminalPfn = $s.Pfn
        continue
    }

    try {
        $it = $null; $firstError = $null
        try {
            $it = Wait-Op ($aim.UpdateAppByPackageFamilyNameAsync($s.Pfn)) $Item 'contacting the Store...'
        } catch { $firstError = $_.Exception }
        if ($firstError) {
            try {
                $it = Wait-Op ($aim.SearchForUpdatesAsync($s.ProductId, '', '', '', $optAuto)) $Item 'asking the Store again...'
            } catch {}
            if (-not $it) { throw $firstError }
        }
        if (-not $it) {
            Write-Status '        no update offered any more - already up to date' DarkGray; Write-Line
            $results[$s.Index] = 'Skipped: already up to date'
            continue
        }
        $i = 0; $final = $null; $queuedSince = $null; $nudged = $false
        while ($true) {
            $st = $it.GetCurrentStatus()
            $state = [string]$st.InstallState
            if ($state -in 'Completed', 'Canceled', 'Error') { $final = $st; break }
            # Nudge an item that sits in the queue for a long time.
            if ($state -in 'Pending', 'ReadyToDownload') {
                if (-not $queuedSince) { $queuedSince = $sw.Elapsed.TotalSeconds }
                if (-not $nudged -and ($sw.Elapsed.TotalSeconds - $queuedSince) -gt 30) {
                    try { $aim.MoveToFrontOfDownloadQueue($s.ProductId, '') } catch {}
                    $nudged = $true
                }
            } else { $queuedSince = $null }
            $pct = [double]$st.PercentComplete
            $label = if ($stateText.ContainsKey($state)) { $stateText[$state] } else { $state }
            $detail = ''
            if ($state -eq 'Downloading' -and $st.DownloadSizeInBytes -gt 0) {
                $detail = '  {0} / {1}' -f (Format-Size $st.BytesDownloaded), (Format-Size $st.DownloadSizeInBytes)
            }
            Write-Status ("      {0} {1} {2,3:N0}%  {3}{4}  {5}" -f $spin[$i++ % 4], (Get-Bar $pct), $pct, $label, $detail, (Format-Elapsed $sw.Elapsed))
            Start-Sleep -Milliseconds 300
        }
        if ([string]$final.InstallState -eq 'Completed') {
            $after = (Get-PackageInfo $s.Pfn).Version
            $verNote = if ($after -and $after -ne $s.Version) { "$($s.Version) -> $after" } else { '' }
            Write-Status ("        {0} 100%  updated  {1}  ({2})" -f (Get-Bar 100), $verNote, (Format-Elapsed $sw.Elapsed)) Green
            $results[$s.Index] = 'Updated'
        } else {
            $hr = 0; try { if ($final.ErrorCode) { $hr = $final.ErrorCode.HResult } } catch {}
            $why = if ($hr -ne 0) { Format-StoreCode $hr } else { [string]$final.InstallState }
            Write-Status ("        update FAILED  {0}" -f $why) Red
            $results[$s.Index] = "Failed: $why"
        }
    } catch [System.Management.Automation.PipelineStoppedException] {
        throw
    } catch {
        $why = Format-StoreError $_.Exception
        Write-Status ("        update FAILED  {0}" -f $why) Red
        $results[$s.Index] = 'Failed: ' + $why
    }
    Write-Line
}

Write-Line
Write-Line '  SUMMARY' Cyan
foreach ($s in $chosen) {
    $st = $results[$s.Index]
    $c = if ($st -like 'Updated*') { 'Green' } elseif ($st -like 'Later*') { 'Yellow' } elseif ($st -like 'Skipped*') { 'DarkGray' } else { 'Red' }
    Write-Line ('  {0,-34}' -f (Limit-Text $st 34)) $c -NoNewline
    Write-Line (Limit-Text $s.Name ((Get-ConsoleWidth) - 38))
}
$inUse = @($chosen | Where-Object { $results[$_.Index] -like '*80073D02*' })
Write-Line

# --- Windows Terminal: update it after the last Terminal window closes.
# A hidden waiter watches for Terminal to exit, then opens a classic console window
# (conhost, so it isn't handed to Terminal) that runs the update with a progress bar.
if ($terminalSkipped) {
    $waiterBody = {
        $deadline = (Get-Date).AddHours(24)
        while ((Get-Process WindowsTerminal -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 5 }
        if ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 3   # let Terminal finish closing
            $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\conhost.exe') `
                -ArgumentList ('"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" -Pfn {2}' -f $ps, $Updater, $Pfn)
        } else {
            Remove-Item $Updater -ErrorAction SilentlyContinue
        }
        Remove-Item $PSCommandPath -ErrorAction SilentlyContinue
    }
    $updaterBody = {
        $ErrorActionPreference = 'Stop'
        try { $Host.UI.RawUI.WindowTitle = 'Updating Windows Terminal' } catch {}
        Add-Type -AssemblyName System.Runtime.WindowsRuntime
        $AIM  = [Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallManager, Windows.ApplicationModel.Store.Preview, ContentType = WindowsRuntime]
        $Item = [Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallItem, Windows.ApplicationModel.Store.Preview, ContentType = WindowsRuntime]
        $PM   = [Windows.Management.Deployment.PackageManager, Windows.Management.Deployment, ContentType = WindowsRuntime]
        $aim = $AIM::new(); $pm = $PM::new()
        $asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
            $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
        $log = Join-Path $env:TEMP 'wu-terminal-update.log'

        Write-Line
        Write-Line '  UPDATING WINDOWS TERMINAL' Green
        Write-Line ('  ' + ('-' * ((Get-ConsoleWidth) - 4))) DarkGray
        Write-Line '  Started by wu because the last Terminal window closed.' DarkGray
        Write-Line
        $before = (Get-PackageInfo $Pfn).Version
        $ok = $false; $result = ''
        try {
            $it = Wait-Op ($aim.UpdateAppByPackageFamilyNameAsync($Pfn)) $Item 'contacting the Store...'
            if (-not $it) {
                Write-Status '  Windows Terminal is already up to date.' Green; Write-Line
                $ok = $true; $result = 'already up to date'
            } else {
                $sw = [Diagnostics.Stopwatch]::StartNew(); $i = 0
                while ($true) {
                    $st = $it.GetCurrentStatus()
                    $state = [string]$st.InstallState
                    if ($state -in 'Completed', 'Canceled', 'Error') { break }
                    $pct = [double]$st.PercentComplete
                    Write-Status ("  {0} {1} {2,3:N0}%  {3}  {4}" -f $spin[$i++ % 4], (Get-Bar $pct), $pct, $state.ToLower(), (Format-Elapsed $sw.Elapsed))
                    Start-Sleep -Milliseconds 300
                }
                if ($state -eq 'Completed') {
                    $after = (Get-PackageInfo $Pfn).Version
                    Write-Status ("  {0} 100%  updated  {1} -> {2}" -f (Get-Bar 100), $before, $after) Green; Write-Line
                    $ok = $true; $result = "updated $before -> $after"
                } else {
                    $hr = 0; try { if ($st.ErrorCode) { $hr = $st.ErrorCode.HResult } } catch {}
                    $why = if ($hr -ne 0) { Format-StoreCode $hr } else { $state }
                    Write-Status ("  update FAILED  {0}" -f $why) Red; Write-Line
                    $result = "failed: $why"
                }
            }
        } catch {
            $why = Format-StoreError $_.Exception
            Write-Status ("  update FAILED  {0}" -f $why) Red; Write-Line
            $result = "failed: $why"
        }
        try { Add-Content -Path $log -Value ('{0:yyyy-MM-dd HH:mm}  {1}' -f (Get-Date), $result) } catch {}
        Write-Line
        if ($ok) {
            Write-Line '  You can open Windows Terminal again. This window closes in 10 seconds.' DarkGray
            Start-Sleep -Seconds 10
        } else {
            Write-Line '  You can also update it from the Microsoft Store: Downloads > Get updates.' Yellow
            Read-Host '  Press Enter to close' | Out-Null
        }
        Remove-Item $PSCommandPath -ErrorAction SilentlyContinue
    }

    try {
        $waiterFile  = Join-Path $env:TEMP 'wu-terminal-waiter.ps1'
        $updaterFile = Join-Path $env:TEMP 'wu-terminal-updater.ps1'
        $utf8 = New-Object System.Text.UTF8Encoding $true
        $fnText = foreach ($fn in 'Write-Line', 'Get-ConsoleWidth', 'Format-Size', 'Format-Elapsed', 'Limit-Text', 'Write-Status',
                                  'Get-Bar', 'Wait-Op', 'Format-StoreCode', 'Format-StoreError', 'Get-PackageInfo') {
            "function $fn {`n$((Get-Item "function:$fn").Definition)`n}"
        }
        $tableText = '$storeText = @{' + (($storeText.GetEnumerator() | ForEach-Object { "'{0}' = '{1}'" -f $_.Key, ($_.Value -replace "'", "''") }) -join '; ') + '}'
        [IO.File]::WriteAllText($updaterFile, ("param([string]`$Pfn)`n" +
            "`$FULL = [string][char]0x2588; `$LIGHT = [string][char]0x2591; `$spin = '|', '/', '-', '\'`n" +
            $tableText + "`n" + ($fnText -join "`n") + "`n" + $updaterBody.ToString()), $utf8)
        [IO.File]::WriteAllText($waiterFile, ("param([string]`$Updater, [string]`$Pfn)`n" + $waiterBody.ToString()), $utf8)

        # Only one waiter at a time.
        $running = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
                     Where-Object { $_.CommandLine -like '*wu-terminal-waiter.ps1*' })
        if ($running.Count -eq 0) {
            $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\conhost.exe') -WindowStyle Hidden `
                -ArgumentList ('"{0}" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}" -Updater "{2}" -Pfn {3}' -f $ps, $waiterFile, $updaterFile, $terminalPfn)
        }
        Write-Line '  Windows Terminal will update itself after you close every Terminal window:' Yellow
        Write-Line '  a small window opens, shows the update progress, then closes on its own.' Yellow
    } catch {
        Write-Line '  To update Windows Terminal: close every Terminal window, then open the Microsoft Store,' Yellow
        Write-Line '  go to Downloads (or Library) and choose Get updates.' Yellow
    }
}
if ($inUse.Count -gt 0) {
    Write-Line ("  Close {0}, then run this option again." -f (($inUse | ForEach-Object { $_.Name }) -join ', ')) Yellow
}
Write-Line '  Done.' Green
Write-Line
'@
        # Give the child script the same display helpers this script uses.
        $helpers = foreach ($f in 'Write-Line', 'Get-ConsoleWidth', 'Format-Size', 'Format-Elapsed', 'Limit-Text', 'Write-Status', 'Get-Bar') {
            "function $f {`n$((Get-Item "function:$f").Definition)`n}"
        }
        $text = "param([switch]`$ListOnly, [switch]`$All)`n" +
                "`$FULL = [string][char]0x2588; `$LIGHT = [string][char]0x2591; `$spin = '|', '/', '-', '\'`n" +
                ($helpers -join "`n") + "`n" + $body
        $tmp = Join-Path $env:TEMP 'wu-store.ps1'
        [IO.File]::WriteAllText($tmp, $text, (New-Object System.Text.UTF8Encoding $true))

        $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$tmp`"")
        if ($ListOnly) { $psArgs += '-ListOnly' }
        if ($Install)  { $psArgs += '-All' }
        $null = Start-WindowsPowerShell $psArgs
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }   # end Invoke-StorePart

    # ================================================================ STORE + WINGET FOR LTSC / SERVER
    # LTSC and Windows Server come without the Microsoft Store and winget.
    # winget: Microsoft's release files from github.com/microsoft/winget-cli (App Installer bundle,
    #   its dependencies and licence, checked against the SHA256 hashes published with them),
    #   provisioned for all users with Add-AppxProvisionedPackage, then registered for you.
    # Store: Windows' own "wsreset -i", which downloads and installs the Store in the background.
    # The Appx commands are most reliable in Windows PowerShell 5.1, so this runs there.
    function Invoke-AppInstallerPart {
        $body = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
Write-Line '  INSTALL MICROSOFT STORE AND WINGET' Green
Write-Line ('  ' + ('-' * ((Get-ConsoleWidth) - 4))) DarkGray

$os = Get-CimInstance Win32_OperatingSystem
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$cpu = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
$arch = switch ($cpu) { 'ARM64' { 'arm64' } 'x86' { 'x86' } default { 'x64' } }
$isServer = $os.ProductType -ne 1
$isLtsc = [string]$cv.EditionID -match 'EnterpriseS|IoTEnterpriseS'
Write-Line ("  {0}  build {1}  {2}" -f $os.Caption, $cv.CurrentBuildNumber, $arch) DarkGray
if (-not $isServer -and -not $isLtsc) {
    Write-Line '  This is meant for Windows LTSC and Windows Server. This edition normally comes with' Yellow
    Write-Line '  the Store and winget, so it only installs whichever one is missing.' Yellow
}
Write-Line

$wgExe = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
function Get-WingetVersion {
    if (-not (Test-Path $wgExe)) { return $null }
    try { $v = [string](& $wgExe --version 2>$null | Select-Object -First 1) } catch { return $null }
    if ($v -match 'v?(\d+\.\d+(\.\d+)?)') { [version]$Matches[1] } else { $null }
}
function Get-StoreVersion {
    $p = Get-AppxPackage -Name Microsoft.WindowsStore -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
    if ($p) { [string]$p.Version } else { $null }
}

Write-Status '  Checking what is installed...'
$storeVer = Get-StoreVersion
$wgVer = Get-WingetVersion
$rel = $null
try { $rel = Invoke-RestMethod 'https://api.github.com/repos/microsoft/winget-cli/releases/latest' -UseBasicParsing -UserAgent 'wu' }
catch { }
$latest = $null
if ($rel -and $rel.tag_name -match '(\d+\.\d+(\.\d+)?)') { $latest = [version]$Matches[1] }
Write-Status ''
Write-Host "`r" -NoNewline

$needWinget = -not $wgVer -or ($latest -and $wgVer -lt $latest)
$needStore  = -not $storeVer
Write-Line ('  {0,-17}' -f 'Microsoft Store') White -NoNewline
if ($storeVer) { Write-Line "installed ($storeVer)" Green } else { Write-Line 'not installed' Yellow }
Write-Line ('  {0,-17}' -f 'winget') White -NoNewline
if (-not $wgVer) { Write-Line 'not installed' Yellow }
elseif ($needWinget) { Write-Line ("v{0}, v{1} is available" -f $wgVer, $latest) Yellow }
else { Write-Line ("v{0} (latest)" -f $wgVer) Green }
Write-Line
if (-not $needWinget -and -not $needStore) { Write-Line '  Nothing to do: both are installed.' Green; Write-Line; exit 0 }
if ($needWinget -and -not $rel) {
    Write-Line "  Couldn't reach GitHub to get winget. Check the internet connection and try again." Red
    if (-not $needStore) { Write-Line; exit 1 }
    $needWinget = $false
}

$todo = @(); if ($needWinget) { $todo += $(if ($wgVer) { 'update winget' } else { 'install winget' }) }; if ($needStore) { $todo += 'install the Microsoft Store' }
$q = $todo -join ' and '
$prompt = "  {0}{1}? [Y/n]" -f $q.Substring(0, 1).ToUpper(), $q.Substring(1)
$ans = Read-Host $prompt
$ans = if ($ans) { "$ans".Trim() } else { '' }
Write-Line
if ($ans -match '^n') { Write-Line '  Nothing changed.' Gray; Write-Line; exit 0 }

$results = @()

# Downloads a file with a live progress bar.
function Save-File([string]$Url, [string]$Path) {
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.UserAgent = 'wu'
    $resp = $req.GetResponse()
    $total = [double]$resp.ContentLength
    $in = $resp.GetResponseStream()
    $out = [IO.File]::Create($Path)
    $buf = New-Object byte[] 262144
    $done = [double]0
    $sw = [Diagnostics.Stopwatch]::StartNew(); $last = -1000
    try {
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $out.Write($buf, 0, $n); $done += $n
            if ($sw.ElapsedMilliseconds - $last -ge 200) {
                $last = $sw.ElapsedMilliseconds
                $pct = if ($total -gt 0) { $done / $total * 100 } else { 0 }
                $speed = $done / [Math]::Max([double]0.5, $sw.Elapsed.TotalSeconds)
                Write-Status ("        {0} {1,3:N0}%  {2} / {3}  {4}/s" -f (Get-Bar $pct), $pct, (Format-Size $done), (Format-Size $total), (Format-Size $speed)) Green
            }
        }
    } finally { $out.Dispose(); $in.Dispose(); $resp.Close() }
    Write-Status ("        {0} 100%  {1}  downloaded in {2}" -f (Get-Bar 100), (Format-Size $done), (Format-Elapsed $sw.Elapsed)) Green
    Write-Line
}

# ---------------------------------------------------------------- winget
if ($needWinget) {
    Write-Line ("  WINGET {0}" -f $rel.tag_name) Cyan
    $work = Join-Path $env:TEMP 'wu-winget'
    try {
        if (Test-Path $work) { [IO.Directory]::Delete($work, $true) }
        New-Item -ItemType Directory $work | Out-Null
        $asset = @{}
        foreach ($a in $rel.assets) { $asset[$a.name] = $a.browser_download_url }
        $bundleName = 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
        $depsName = 'DesktopAppInstaller_Dependencies.zip'
        $licName = @($rel.assets | Where-Object { $_.name -like '*License1.xml' })[0].name
        foreach ($n in $bundleName, $depsName, $licName) { if (-not $n -or -not $asset[$n]) { throw "the winget release is missing a file ($n)" } }

        $files = @(
            @{ Name = $licName;    Label = 'Licence' }
            @{ Name = $depsName;   Label = 'Dependencies (VCLibs, Windows App Runtime)' }
            @{ Name = $bundleName; Label = 'App Installer (winget)' }
        )
        $i = 0
        foreach ($f in $files) {
            $i++
            Write-Line ("  [{0}/{1}] {2}" -f $i, $files.Count, $f.Label) White
            $f.Path = Join-Path $work $f.Name
            Save-File $asset[$f.Name] $f.Path
            # Check the download against the SHA256 hash Microsoft publishes next to it.
            $hashName = [IO.Path]::GetFileNameWithoutExtension($f.Name) + '.txt'
            if ($asset[$hashName]) {
                $wc = New-Object Net.WebClient; $wc.Headers['User-Agent'] = 'wu'
                try { $want = ([string]$wc.DownloadString($asset[$hashName])).Trim() } finally { $wc.Dispose() }
                $got = (Get-FileHash $f.Path -Algorithm SHA256).Hash
                if ($want -notmatch '^[0-9A-Fa-f]{64}$') { throw "couldn't read the published hash for $($f.Name)" }
                if ($got -ne $want) { throw "$($f.Name) failed its SHA256 check, so it wasn't installed" }
                Write-Line '        SHA256 matches the published hash' DarkGray
            }
        }

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $work $depsName), (Join-Path $work 'deps'))
        $deps = @(Get-ChildItem (Join-Path $work "deps\$arch") -Filter *.appx | ForEach-Object FullName)
        if (-not $deps) { throw "the dependencies download has nothing for $arch" }
        $bundle = Join-Path $work $bundleName
        $lic = Join-Path $work $licName

        Write-Line
        Write-Line '  Installing for all users (provisioning) - this can take a minute or two...' White
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $null = Add-AppxProvisionedPackage -Online -PackagePath $bundle -DependencyPackagePath $deps -LicensePath $lic
        Write-Line ("        done ({0})" -f (Format-Elapsed $sw.Elapsed)) Green
        Write-Line '  Registering for you...' White
        $sw.Restart()
        try {
            Add-AppxPackage -Path $bundle -DependencyPath $deps -ForceApplicationShutdown
            Write-Line ("        done ({0})" -f (Format-Elapsed $sw.Elapsed)) Green
        } catch {
            # 0x80073D06: an equal or newer version is already registered, which is fine.
            if ($_.Exception.HResult -ne -2147009274 -and "$($_.Exception.Message)" -notmatch '0x80073D06') { throw }
            Write-Line '        already registered' Green
        }

        # winget runs from %LOCALAPPDATA%\Microsoft\WindowsApps; make sure that's on your PATH.
        $appsDir = Split-Path $wgExe
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if (-not (($userPath -split ';') -contains $appsDir) -and -not (($userPath -split ';') -contains '%USERPROFILE%\AppData\Local\Microsoft\WindowsApps')) {
            [Environment]::SetEnvironmentVariable('Path', (($userPath.TrimEnd(';'), $appsDir) -join ';').TrimStart(';'), 'User')
            Write-Line '        added winget to your PATH (new windows will find it)' DarkGray
        }

        $sw.Restart(); $nowVer = $null
        while (-not ($nowVer = Get-WingetVersion) -and $sw.Elapsed.TotalSeconds -lt 30) { Start-Sleep -Milliseconds 500 }
        if ($nowVer) { $results += [pscustomobject]@{ Ok = $true; Text = "winget v$nowVer is ready" } }
        else { $results += [pscustomobject]@{ Ok = $false; Text = 'winget was installed but does not run yet: sign out and back in, then try winget again' } }
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match '0x80073CF3|0x80073D19') { $msg += ' (a newer version of one of its parts is already installed, or the package needs a newer Windows build)' }
        $results += [pscustomobject]@{ Ok = $false; Text = "winget: $msg" }
        Write-Line ("        FAILED  {0}" -f $msg) Red
    } finally {
        if (Test-Path $work) { try { [IO.Directory]::Delete($work, $true) } catch { } }
    }
    Write-Line
}

# ---------------------------------------------------------------- Microsoft Store
if ($needStore) {
    Write-Line '  MICROSOFT STORE' Cyan
    $wsreset = Join-Path $env:SystemRoot 'System32\WSReset.exe'
    if (-not (Test-Path $wsreset)) {
        $results += [pscustomobject]@{ Ok = $false; Text = "Microsoft Store: this edition doesn't include WSReset, so Windows can't install the Store here" }
        Write-Line "  This edition doesn't include WSReset, so Windows can't install the Store here." Red
    } else {
        Write-Line '  Asking Windows to install the Store (wsreset -i). It downloads in the background;' White
        Write-Line '  Windows may show a notification while it does.' White
        Start-Process $wsreset -ArgumentList '-i' -WindowStyle Hidden
        $sw = [Diagnostics.Stopwatch]::StartNew(); $k = 0; $ver = $null
        while (-not ($ver = Get-StoreVersion) -and $sw.Elapsed.TotalMinutes -lt 10) {
            for ($t = 0; $t -lt 20; $t++) {
                Write-Status ("  {0} Waiting for the Store to install  {1}  (up to 10 minutes)" -f $spin[$k++ % 4], (Format-Elapsed $sw.Elapsed))
                Start-Sleep -Milliseconds 250
            }
        }
        Write-Status ''
        Write-Host "`r" -NoNewline
        if ($ver) {
            Write-Line ("  Microsoft Store {0} installed ({1})" -f $ver, (Format-Elapsed $sw.Elapsed)) Green
            $results += [pscustomobject]@{ Ok = $true; Text = "Microsoft Store $ver is installed" }
        } else {
            Write-Line "  The Store didn't appear within 10 minutes." Red
            $results += [pscustomobject]@{ Ok = $false; Text = "Microsoft Store wasn't installed. Install the latest Windows updates (option 1), restart, and run this again. Some Server versions don't support the Store; winget works without it" }
        }
    }
    Write-Line
}

Write-Line '  SUMMARY' Cyan
foreach ($r in $results) {
    if ($r.Ok) { Write-Line ("  OK      {0}" -f $r.Text) Green } else { Write-Line ("  FAILED  {0}" -f $r.Text) Red }
}
Write-Line
if (@($results | Where-Object { -not $_.Ok }).Count) { exit 1 }
'@
        $helpers = foreach ($f in 'Write-Line', 'Get-ConsoleWidth', 'Format-Size', 'Format-Elapsed', 'Limit-Text', 'Write-Status', 'Get-Bar') {
            "function $f {`n$((Get-Item "function:$f").Definition)`n}"
        }
        $text = "`$FULL = [string][char]0x2588; `$LIGHT = [string][char]0x2591; `$spin = '|', '/', '-', '\'`n" +
                ($helpers -join "`n") + "`n" + $body
        $tmp = Join-Path $env:TEMP 'wu-appinstaller.ps1'
        [IO.File]::WriteAllText($tmp, $text, (New-Object System.Text.UTF8Encoding $true))
        $null = Start-WindowsPowerShell @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$tmp`"")
        Remove-Item $tmp -ErrorAction SilentlyContinue
        # winget may be new: let this window find it straight away.
        $apps = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
        if ((Test-Path (Join-Path $apps 'winget.exe')) -and -not (($env:Path -split ';') -contains $apps)) { $env:Path = $env:Path.TrimEnd(';') + ';' + $apps }
    }   # end Invoke-AppInstallerPart

    # ================================================================ SHARED BITS FOR 6-8
    function Write-Heading([string]$Text) {
        Write-Line ("  {0}" -f $Text) Green
        Write-Line ('  ' + ('-' * ((Get-ConsoleWidth) - 4))) DarkGray
    }
    function Get-FreeSpace { try { [double]([IO.DriveInfo]::new($env:SystemDrive).AvailableFreeSpace) } catch { 0 } }

    # Runs a Windows tool (DISM, SFC) in this window so its own progress shows live.
    function Invoke-NativeTool([string]$Exe, [string[]]$ToolArgs) {
        $p = Start-Process -FilePath $Exe -ArgumentList $ToolArgs -NoNewWindow -PassThru
        $null = $p.Handle
        $p.WaitForExit()
        [int]$p.ExitCode
    }

    $dismText = @{
        '800F081F' = 'repair files not found - Windows Update could not supply them'
        '800F0906' = 'could not download repair files - check the internet connection'
        '800F0907' = 'a group policy blocks downloading repair files'
        '800F0950' = 'repair source not available'
        '80070005' = 'access denied - run as administrator'
        '80070057' = 'invalid parameter'
        '800F082F' = 'a restart is pending - restart Windows and try again'
    }
    function Format-DismCode([int]$code) {
        $hex = '{0:X8}' -f $code
        if ($dismText.ContainsKey($hex)) { "0x$hex ($($dismText[$hex]))" } else { "0x$hex" }
    }

    # ================================================================ 6. REPAIR WINDOWS
    function Invoke-RepairPart {
        Write-Heading 'REPAIR WINDOWS'
        Write-Line '  Step 1  DISM checks the Windows component store and downloads fresh copies of anything damaged.'
        Write-Line '  Step 2  SFC checks every protected system file and repairs it from that store.'
        Write-Line '  Together they usually take 10-30 minutes. You can keep using the PC meanwhile.' DarkGray
        Write-Line
        $a = Read-Host '  Start the repair? [Y/n]'
        if ($a -match '^\s*(n|no|q)') { Write-Line '  Repair not started.' DarkGray; Write-Line; return }

        $sys = Join-Path $env:SystemRoot 'System32'
        Write-Line
        Write-Line '  [1/2] DISM /Online /Cleanup-Image /RestoreHealth' White
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $dism = Invoke-NativeTool (Join-Path $sys 'dism.exe') @('/Online', '/Cleanup-Image', '/RestoreHealth')
        Write-Line
        if ($dism -eq 0) {
            Write-Line ("        DISM finished: the component store is healthy  ({0})" -f (Format-Elapsed $sw.Elapsed)) Green
        } else {
            Write-Line ("        DISM FAILED  {0}" -f (Format-DismCode $dism)) Red
            Write-Line '        SFC will still run, but it may not be able to repair everything.' Yellow
        }

        Write-Line
        Write-Line '  [2/2] sfc /scannow' White
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $sfc = Invoke-NativeTool (Join-Path $sys 'sfc.exe') @('/scannow')
        Write-Line
        if ($sfc -eq 0) {
            Write-Line ("        SFC finished  ({0}) - its result is shown just above" -f (Format-Elapsed $sw.Elapsed)) Green
        } else {
            Write-Line ("        SFC finished with exit code {0} - its result is shown just above" -f $sfc) Yellow
        }

        Write-Line
        Write-Heading 'SUMMARY'
        $c = if ($dism -eq 0) { 'Green' } else { 'Red' }
        Write-Line ('  {0,-12}' -f 'DISM') -NoNewline
        Write-Line $(if ($dism -eq 0) { 'healthy' } else { 'failed: ' + (Format-DismCode $dism) }) $c
        Write-Line ('  {0,-12}' -f 'SFC') -NoNewline
        Write-Line $(if ($sfc -eq 0) { 'finished - see its message above' } else { "exit code $sfc - see its message above" }) $(if ($sfc -eq 0) { 'Green' } else { 'Yellow' })
        Write-Line
        Write-Line '  If SFC says it repaired files, restart Windows to finish.' DarkGray
        Write-Line '  Details: C:\Windows\Logs\DISM\dism.log and C:\Windows\Logs\CBS\CBS.log' DarkGray
        Write-Line
    }

    # ================================================================ 7. CLEAN UP DISK SPACE
    function Invoke-CleanupPart {
        Write-Heading 'CLEAN UP DISK SPACE'

        # Top-level items in $Path, optionally only those untouched for $Hours. Links are skipped
        # so nothing outside the folder is ever measured or deleted.
        function Get-CleanTargets([string]$Path, [int]$Hours) {
            $exists = $false
            try { $exists = Test-Path -LiteralPath $Path -ErrorAction Stop } catch {}
            if (-not $exists) { return @() }
            $cut = (Get-Date).AddHours(-$Hours)
            @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | Where-Object {
                -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -and ($Hours -le 0 -or $_.LastWriteTime -lt $cut)
            })
        }
        function Measure-Targets($targets) {
            $sum = 0.0
            foreach ($t in $targets) {
                if ($t.PSIsContainer) {
                    $m = Get-ChildItem -LiteralPath $t.FullName -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum
                    if ($m.Sum) { $sum += $m.Sum }
                } else { $sum += $t.Length }
            }
            $sum
        }
        function Remove-Targets($targets) {
            foreach ($t in $targets) {
                # .NET deletes links inside folders without following them. Files in use are skipped.
                try {
                    if ($t.PSIsContainer) { [IO.Directory]::Delete($t.FullName, $true) }
                    else { [IO.File]::Delete($t.FullName) }
                } catch {}
            }
        }

        $doCache = Join-Path $env:SystemRoot 'ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache'
        $jobs = @(
            [pscustomobject]@{ Key = 'usertemp'; Name = 'Your temporary files (older than 1 day)';   Path = $env:TEMP;                                              Hours = 24; Safe = $true }
            [pscustomobject]@{ Key = 'wintemp';  Name = 'Windows temporary files (older than 1 day)'; Path = (Join-Path $env:SystemRoot 'Temp');                    Hours = 24; Safe = $true }
            [pscustomobject]@{ Key = 'wucache';  Name = 'Windows Update download cache';             Path = (Join-Path $env:SystemRoot 'SoftwareDistribution\Download'); Hours = 0; Safe = $true }
            [pscustomobject]@{ Key = 'docache';  Name = 'Delivery Optimization cache';               Path = $doCache;                                               Hours = 0;  Safe = $true }
            [pscustomobject]@{ Key = 'winsxs';   Name = 'Old update components (DISM cleanup)';      Path = $null;                                                  Hours = 0;  Safe = $false }
        )
        $i = 0
        foreach ($j in $jobs) {
            $i++
            $j | Add-Member -NotePropertyName Index -NotePropertyValue $i
            if ($j.Path) {
                Write-Status ("  Measuring: {0}..." -f $j.Name) Cyan
                $size = 0.0
                try { $size = Measure-Targets (Get-CleanTargets $j.Path $j.Hours) } catch {}
                $j | Add-Member -NotePropertyName Size -NotePropertyValue $size
            } else {
                $j | Add-Member -NotePropertyName Size -NotePropertyValue -1
            }
        }
        Write-Status ''
        Write-Host "`r" -NoNewline

        function Show-CleanList {
            foreach ($j in $jobs) {
                Write-Line ('  {0,3}  ' -f $j.Index) White -NoNewline
                Write-Line ('{0,-46}' -f $j.Name) -NoNewline
                if ($j.Size -lt 0) { Write-Line '   varies' DarkGray }
                else { Write-Line ('{0,9}' -f $(if ($j.Size -gt 0) { Format-Size $j.Size } else { 'empty' })) Cyan }
            }
            Write-Line
            Write-Line '  5 makes older Windows updates permanent: they can no longer be uninstalled. It can take 10+ minutes.' DarkGray
        }
        Show-CleanList
        Write-Line
        Write-Line ("  Free space on {0} now: {1}" -f $env:SystemDrive, (Format-Size (Get-FreeSpace))) DarkGray
        Write-Line

        $chosen = @()
        while ($true) {
            Write-Line '  Choose:  ' White -NoNewline
            Write-Line 's' Green -NoNewline; Write-Line '=safe items 1-4  ' -NoNewline
            Write-Line 'a' Yellow -NoNewline; Write-Line '=all  ' -NoNewline
            Write-Line '1,3,5-7' White -NoNewline; Write-Line '=numbers  ' -NoNewline
            Write-Line 'q=quit' DarkGray
            $answer = Read-Host '  Selection [s]'
            if ([string]::IsNullOrWhiteSpace($answer)) { $answer = 's' }
            $answer = $answer.Trim().ToLower()
            if ($answer -match '^(q|quit|exit)$') { Write-Line '  Nothing cleaned.' DarkGray; Write-Line; return }
            $set = New-Object System.Collections.Generic.HashSet[int]
            $bad = $null
            foreach ($tok in ($answer -split '[,\s]+' | Where-Object { $_ })) {
                if ($tok -eq 's') { $jobs | Where-Object Safe | ForEach-Object { [void]$set.Add($_.Index) } }
                elseif ($tok -match '^(a|all)$') { $jobs | ForEach-Object { [void]$set.Add($_.Index) } }
                elseif ($tok -match '^(\d+)-(\d+)$') { [int]$matches[1]..[int]$matches[2] | ForEach-Object { [void]$set.Add($_) } }
                elseif ($tok -match '^\d+$') { [void]$set.Add([int]$tok) }
                else { $bad = $tok }
            }
            if ($bad) { Write-Line "  Didn't understand '$bad'" Red; continue }
            $chosen = @($set | Where-Object { $_ -ge 1 -and $_ -le $jobs.Count } | Sort-Object | ForEach-Object { $jobs[$_ - 1] })
            if ($chosen.Count -eq 0) { Write-Line '  Nothing selected.' Yellow; continue }
            break
        }

        # Sizes are doubles: a cache can easily be more than 2 GB, which overflows Int32.
        function Measure-Folder($j) {
            try { [double](Measure-Targets (Get-CleanTargets $j.Path $j.Hours)) } catch { 0.0 }
        }
        function Format-Freed([double]$bytes) { if ($bytes -gt 0) { Format-Size $bytes } else { 'nothing' } }

        $done = @{}
        $total = 0.0
        $k = 0
        foreach ($j in $chosen) {
            $k++
            Write-Line
            Write-Line ("  [{0}/{1}] {2}" -f $k, $chosen.Count, $j.Name) White
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $note = ''
            # Folder items: freed = what the folder held before minus what's left (files in use).
            # DISM: no folder to measure, so use the change in free space instead.
            $sizeBefore = if ($j.Path) { Measure-Folder $j } else { 0.0 }
            $freeBefore = Get-FreeSpace
            try {
                switch ($j.Key) {
                    'wucache' {
                        $busy = $false
                        try { $busy = (New-Object -ComObject Microsoft.Update.Installer).IsBusy } catch {}
                        if ($busy) { $note = 'skipped - Windows Update is installing right now'; break }
                        Write-Status '      stopping Windows Update services...' Yellow
                        try {
                            Stop-Service -Name wuauserv, bits -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
                            Write-Status '      deleting the download cache...' Yellow
                            Remove-Targets (Get-CleanTargets $j.Path 0)
                        } finally {
                            Write-Status '      restarting Windows Update services...' Yellow
                            Start-Service -Name bits, wuauserv -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
                        }
                    }
                    'docache' {
                        Write-Status '      clearing the Delivery Optimization cache...' Yellow
                        # Silenced: the cmdlet prints its own "Deleting..." messages.
                        $cmd = '"$ProgressPreference = ''SilentlyContinue''; try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop *> $null; exit 0 } catch { exit 1 }"'
                        $p = Start-WindowsPowerShell @('-NoProfile', '-Command', $cmd)
                        if ($p.ExitCode -ne 0) { $note = 'Windows reported a problem clearing it' }
                    }
                    'winsxs' {
                        Write-Status ''
                        Write-Line
                        $code = Invoke-NativeTool (Join-Path $env:SystemRoot 'System32\dism.exe') @('/Online', '/Cleanup-Image', '/StartComponentCleanup')
                        Write-Line
                        if ($code -ne 0) { $note = 'DISM failed: ' + (Format-DismCode $code) }
                    }
                    default {
                        Write-Status '      deleting...' Yellow
                        Remove-Targets (Get-CleanTargets $j.Path $j.Hours)
                    }
                }
            } catch {
                $note = $_.Exception.Message
            }
            $freed = 0.0
            if ($j.Path -and $sizeBefore -gt 0) {
                $freed = [Math]::Max([double]0, $sizeBefore - (Measure-Folder $j))
            } else {
                $freed = [Math]::Max([double]0, (Get-FreeSpace) - $freeBefore)
            }
            if ($note -like 'skipped*') {
                Write-Status ("        {0}" -f $note) DarkGray
                $done[$j.Index] = 'Skipped: Windows Update busy'
            } elseif ($note) {
                Write-Status ("        {0}" -f $note) Red
                $done[$j.Index] = 'Problem: ' + $note
            } else {
                $total += $freed
                Write-Status ("        freed {0}  ({1})" -f (Format-Freed $freed), (Format-Elapsed $sw.Elapsed)) Green
                $done[$j.Index] = 'Freed ' + (Format-Freed $freed)
            }
            Write-Line
        }

        Write-Line
        Write-Heading 'SUMMARY'
        foreach ($j in $chosen) {
            $st = $done[$j.Index]
            $c = if ($st -like 'Freed*') { 'Green' } elseif ($st -like 'Skipped*') { 'DarkGray' } else { 'Red' }
            Write-Line ('  {0,-30}' -f (Limit-Text $st 30)) $c -NoNewline
            Write-Line $j.Name
        }
        Write-Line
        Write-Line ("  Freed {0} in total. Free space on {1} is now {2}." -f (Format-Freed $total), $env:SystemDrive, (Format-Size (Get-FreeSpace))) Green
        Write-Line '  Files that were in use were left alone.' DarkGray
        Write-Line
    }

    # ================================================================ 8. UPDATE HISTORY
    function Invoke-HistoryPart {
        $days = 30
        $since = (Get-Date).AddDays(-$days)
        $inv = [Globalization.CultureInfo]::InvariantCulture   # "Sep", not "Sept", so columns line up

        # --- Windows Update
        Write-Heading 'WINDOWS UPDATES'
        try {
            $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
            $count = $searcher.GetTotalHistoryCount()
            $entries = if ($count -gt 0) { @($searcher.QueryHistory(0, [Math]::Min(200, $count))) } else { @() }
            $shown = 0; $defShown = $false; $defHidden = 0
            foreach ($h in $entries) {
                if (-not $h.Title) { continue }
                # Defender definitions arrive several times a day: show the newest, count the rest
                # (failed ones are always shown).
                if ($h.Title -like 'Security Intelligence Update*' -and [int]$h.ResultCode -eq 2) {
                    if ($defShown) { $defHidden++; continue }
                    $defShown = $true
                }
                $when = ([datetime]$h.Date).ToLocalTime()
                $op = if ($h.Operation -eq 2) { 'Removed' } else { 'Installed' }
                switch ([int]$h.ResultCode) {
                    2 { $res = $op;           $c = 'Green' }
                    3 { $res = 'With errors'; $c = 'Yellow' }
                    4 { $res = 'FAILED';      $c = 'Red' }
                    5 { $res = 'Cancelled';   $c = 'Yellow' }
                    default { $res = 'In progress'; $c = 'DarkGray' }
                }
                Write-Line ('  ' + $when.ToString('dd MMM yyyy HH:mm', $inv) + '  ') DarkGray -NoNewline
                Write-Line ('{0,-12}' -f $res) $c -NoNewline
                Write-Line (Limit-Text $h.Title ((Get-ConsoleWidth) - 34))
                if ([int]$h.ResultCode -in 3, 4 -and $h.HResult -ne 0) {
                    Write-Line ('{0,33}{1}' -f '', (Format-HResult $h.HResult)) Red
                }
                $shown++
                if ($shown -ge 25) { break }
            }
            if ($shown -eq 0) { Write-Line '  No Windows Update history.' DarkGray }
            if ($defHidden -gt 0) { Write-Line ("  + {0} earlier Defender definition updates, all installed" -f $defHidden) DarkGray }
        } catch {
            Write-Line ("  Couldn't read Windows Update history: {0}" -f $_.Exception.Message) Red
        }

        # --- Desktop apps (winget and other installers record an install date here)
        Write-Line
        Write-Heading ("APPS INSTALLED OR UPDATED (last {0} days)" -f $days)
        $keys = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
        $apps = foreach ($k in $keys) {
            Get-ItemProperty -Path $k -ErrorAction SilentlyContinue | Where-Object {
                $_.DisplayName -and $_.InstallDate -match '^\d{8}$' -and $_.SystemComponent -ne 1
            } | ForEach-Object {
                $d = [datetime]::MinValue
                if ([datetime]::TryParseExact($_.InstallDate, 'yyyyMMdd', $null, 'None', [ref]$d) -and $d -ge $since.Date) {
                    [pscustomobject]@{ Date = $d; Name = $_.DisplayName; Version = $_.DisplayVersion }
                }
            }
        }
        $apps = @($apps | Sort-Object Date, Name -Descending -Unique | Sort-Object Date -Descending | Select-Object -First 30)
        if ($apps.Count -eq 0) { Write-Line '  None.' DarkGray }
        foreach ($a in $apps) {
            Write-Line ('  ' + $a.Date.ToString('dd MMM yyyy', $inv) + '        ') DarkGray -NoNewline
            Write-Line (Limit-Text $a.Name 50) -NoNewline
            if ($a.Version) { Write-Line ("  {0}" -f $a.Version) DarkGray } else { Write-Line }
        }

        # --- Microsoft Store apps (each version installs into its own folder)
        Write-Line
        Write-Heading ("STORE APPS INSTALLED OR UPDATED (last {0} days)" -f $days)
        try {
            $store = @(Get-AppxPackage -ErrorAction Stop | Where-Object {
                -not $_.IsFramework -and "$($_.SignatureKind)" -eq 'Store' -and $_.InstallLocation
            } | ForEach-Object {
                $d = $null; try { $d = (Get-Item -LiteralPath $_.InstallLocation -ErrorAction Stop).CreationTime } catch {}
                if ($d -and $d -ge $since) { [pscustomobject]@{ Date = $d; Name = $_.Name; Version = "$($_.Version)" } }
            } | Sort-Object Date -Descending | Select-Object -First 30)
            if ($store.Count -eq 0) { Write-Line '  None.' DarkGray }
            foreach ($s in $store) {
                Write-Line ('  ' + $s.Date.ToString('dd MMM yyyy HH:mm', $inv) + '  ') DarkGray -NoNewline
                Write-Line (Limit-Text $s.Name 50) -NoNewline
                Write-Line ("  {0}" -f $s.Version) DarkGray
            }
        } catch {
            Write-Line ("  Couldn't read Store apps: {0}" -f $_.Exception.Message) Red
        }
        Write-Line
        Write-Line '  winget keeps no history of its own; its upgrades appear under apps above.' DarkGray
        Write-Line
    }

    # ================================================================ 9. WINGET APP INSTALLS
    # Installs one app with winget, showing winget's own live progress. If the app is
    # already there, winget upgrades it when a newer version exists.
    function Invoke-WingetInstall([string]$Title, [string]$Id) {
        Write-Heading $Title.ToUpper()
        Write-Line ("  Running: winget install -e --id {0}" -f $Id) DarkGray
        Write-Line
        $wg = Get-Command winget.exe -ErrorAction SilentlyContinue
        if (-not $wg) {
            Write-Line '  winget was not found. Install "App Installer" from the Microsoft Store, then try again.' Red
            Write-Line
            return
        }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $p = Start-Process -FilePath $wg.Source -NoNewWindow -PassThru -ArgumentList @(
            'install', '-e', '--id', $Id, '--source', 'winget',
            '--accept-package-agreements', '--accept-source-agreements')
        $null = $p.Handle
        $p.WaitForExit()
        $code = [int]$p.ExitCode
        $hex = '{0:X8}' -f $code
        Write-Line
        if ($code -eq 0) {
            Write-Line ("  {0} finished  ({1})" -f $Title, (Format-Elapsed $sw.Elapsed)) Green
        } elseif ($hex -eq '8A15002B') {
            Write-Line '  Already installed, and no newer version is available.' Green
        } elseif ($hex -eq '8A150109') {
            Write-Line ("  {0} finished - restart Windows to complete it." -f $Title) Yellow
        } else {
            Write-Line ("  {0} FAILED  {1}" -f $Title, (Format-WingetCode $code)) Red
        }
        Write-Line
    }

    # ================================================================ EXTRAS
    # Runs a one-line installer (irm ... | iex) in its own Windows PowerShell 5.1 process
    # in this window, so it can't disturb the menu, then comes back to the menu.
    function Invoke-External([string]$Title, [string]$Command) {
        Write-Line ("  {0}" -f $Title.ToUpper()) Green
        Write-Line ("  Running: {0}" -f $Command) DarkGray
        Write-Line
        try {
            $p = Start-WindowsPowerShell @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', "`"$Command`"")
            Write-Line
            if ($p.ExitCode -eq 0) { Write-Line "  $Title finished." Green }
            else { Write-Line ("  {0} finished with exit code {1}." -f $Title, $p.ExitCode) Yellow }
        } catch {
            Write-Line ("  Couldn't run {0}: {1}" -f $Title, $_.Exception.Message) Red
        }
        Write-Line
    }

    # Sets the default color scheme for every Windows Terminal profile (profiles.defaults.colorScheme),
    # the same as Settings > Color schemes > Set as default. Terminal picks the change up live.
    # CGA's colors, copied from Windows Terminal's defaults.json.
    $cgaScheme = [ordered]@{
        name = 'CGA'; foreground = '#AAAAAA'; background = '#000000'; cursorColor = '#00AA00'; selectionBackground = '#FFFFFF'
        black = '#000000'; red = '#AA0000'; green = '#00AA00'; yellow = '#AA5500'; blue = '#0000AA'; purple = '#AA00AA'; cyan = '#00AAAA'; white = '#AAAAAA'
        brightBlack = '#555555'; brightRed = '#FF5555'; brightGreen = '#55FF55'; brightYellow = '#FFFF55'; brightBlue = '#5555FF'; brightPurple = '#FF55FF'; brightCyan = '#55FFFF'; brightWhite = '#FFFFFF'
    }
    function Set-TerminalColorScheme([string]$Scheme, $Colors) {
        $paths = @(
            "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
            "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json"
            "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
        ) | Where-Object { Test-Path -LiteralPath $_ }
        if (-not $paths) {
            Write-Line ("  Color scheme: no Windows Terminal settings found yet; open Terminal once, then run this again.") Yellow
            return
        }
        foreach ($path in $paths) {
            try {
                $raw = [IO.File]::ReadAllText($path)
                try { $json = $raw | ConvertFrom-Json -ErrorAction Stop }
                catch {
                    # Terminal allows // comment lines; drop whole-line comments and retry.
                    $json = (($raw -split "`r?`n") | Where-Object { $_ -notmatch '^\s*//' }) -join "`n" | ConvertFrom-Json -ErrorAction Stop
                }
                if (-not $json.PSObject.Properties['profiles'] -or $null -eq $json.profiles) {
                    $json | Add-Member -NotePropertyName profiles -NotePropertyValue ([pscustomobject]@{}) -Force
                }
                if ($json.profiles -is [array]) {
                    $json.profiles = [pscustomobject]@{ defaults = [pscustomobject]@{}; list = $json.profiles }
                }
                if (-not $json.profiles.PSObject.Properties['defaults'] -or $null -eq $json.profiles.defaults) {
                    $json.profiles | Add-Member -NotePropertyName defaults -NotePropertyValue ([pscustomobject]@{}) -Force
                }
                $d = $json.profiles.defaults
                # Older Terminal versions (a clean Windows 11 install) don't have every built-in scheme,
                # so add the scheme's colors unless settings.json already defines one with that name.
                $schemes = @()
                if ($json.PSObject.Properties['schemes'] -and $null -ne $json.schemes) { $schemes = @($json.schemes) }
                $needDef = $Colors -and -not ($schemes | Where-Object { $_.PSObject.Properties['name'] -and $_.name -eq $Scheme })
                if (-not $needDef -and $d.PSObject.Properties['colorScheme'] -and $d.colorScheme -eq $Scheme) {
                    Write-Line ("  Color scheme: already {0}." -f $Scheme) Green
                    continue
                }
                if ($needDef) { $json | Add-Member -NotePropertyName schemes -NotePropertyValue (@($schemes) + [pscustomobject]$Colors) -Force }
                $d | Add-Member -NotePropertyName colorScheme -NotePropertyValue $Scheme -Force
                [IO.File]::WriteAllText($path, ($json | ConvertTo-Json -Depth 64), (New-Object Text.UTF8Encoding $false))
                Write-Line ("  Color scheme: set to {0}." -f $Scheme) Green
            } catch {
                Write-Line ("  Color scheme: couldn't update {0}: {1}" -f $path, $_.Exception.Message) Red
            }
        }
        Write-Line
    }

    # ================================================================ MENU
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    Write-Line
    if ($os) { Write-Line ("  {0}  build {1}" -f $os.Caption, $os.BuildNumber) DarkGray; Write-Line }

    # Options given on the command line skip the menu.
    if ($Winget) { Invoke-WingetPart; return }
    if ($Store)  { Invoke-StorePart; return }
    if ($WindowsUpdate -or $ListOnly -or $Install -or $AutoReboot) { Invoke-WindowsUpdatePart; return }

    $menu = @(
        'Windows Update CLI'
        'Winget Update CLI'
        'Store Update CLI'
        'OhMyPosh Terminal Setup and Theme'
        'Chris Titus Windows Utility'
        'Repair Windows'
        'Clean Up Disk Space'
        'Update History'
        'Install PDFcraft'
        'Install Store and Winget (LTSC/Server)'
    )
    while ($true) {
        $w = Get-ConsoleWidth
        Write-Line '  WINDOWS CLI MENU' Green
        Write-Line ('  ' + ('-' * ($w - 4))) DarkGray
        for ($m = 0; $m -lt $menu.Count; $m++) {
            Write-Line ('  {0,3}  ' -f ($m + 1)) White -NoNewline
            Write-Line $menu[$m] Gray
        }
        Write-Line
        Write-Line ('  {0,3}  ' -f 'q') White -NoNewline
        Write-Line 'Quit' Gray
        Write-Line
        $choice = ([string](Read-Host '  Selection [1]')).Trim()
        Write-Line
        if ($choice -match '^(q|quit|exit)$') { return }
        elseif ($choice -match '^1?$') { Invoke-WindowsUpdatePart }
        elseif ($choice -eq '2') { Invoke-WingetPart }
        elseif ($choice -eq '3') { Invoke-StorePart }
        elseif ($choice -eq '4') {
            Invoke-External 'OhMyPosh Terminal Setup and Theme' 'irm https://raw.githubusercontent.com/andrewpayne68/windows-terminal-ohmyposh/main/install.ps1 | iex'
            Set-TerminalColorScheme 'CGA' $cgaScheme
        }
        elseif ($choice -eq '5') { Invoke-External 'Chris Titus Windows Utility' 'irm christitus.com/win | iex' }
        elseif ($choice -eq '6') { Invoke-RepairPart }
        elseif ($choice -eq '7') { Invoke-CleanupPart }
        elseif ($choice -eq '8') { Invoke-HistoryPart }
        elseif ($choice -eq '9') { Invoke-WingetInstall 'Install PDFcraft' 'ArtCraft.PdfCraft' }
        elseif ($choice -eq '10') { Invoke-AppInstallerPart }
        else { Write-Line '  Please enter a number from 1 to 10, or q.' Yellow; Write-Line; continue }
        Write-Line ('  ' + ('=' * ((Get-ConsoleWidth) - 4))) DarkGray
        Write-Line
    }
}

Invoke-WUCli @args
