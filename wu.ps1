<#
    wu.ps1 - a no-nonsense update CLI for Windows Update and winget

    Quick start (paste into an admin or normal PowerShell / Terminal):
        irm https://andrewpayne68.github.io/wu | iex
    A menu then offers 1) Windows Update  2) Winget app upgrades.

    With options (skip the menu):
        & ([scriptblock]::Create((irm https://andrewpayne68.github.io/wu))) -ListOnly
        & ([scriptblock]::Create((irm https://andrewpayne68.github.io/wu))) -Install Recommended -AutoReboot
        & ([scriptblock]::Create((irm https://andrewpayne68.github.io/wu))) -Winget
        & ([scriptblock]::Create((irm https://andrewpayne68.github.io/wu))) -Winget -Install All

    Options:
        -WindowsUpdate            Go straight to Windows Update.
        -Winget                   Go straight to winget app upgrades.
        -ListOnly                 Just list available updates, install nothing.
        -Install <set[,set]>      Non-interactive. Windows Update: Recommended, Optional, Drivers or All.
                                  With -Winget, any value upgrades all apps.
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
        [switch]$Winget
    )

    $ErrorActionPreference = 'Stop'
    if ($Install -and -not $Winget) {
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
        $Pct = [Math]::Min(100, [Math]::Max(0, $Pct))
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
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$tmp`"")
        if ($Install)           { $argList += '-Install'; $argList += ($Install -join ',') }
        if ($AutoReboot)        { $argList += '-AutoReboot' }
        if ($NoMicrosoftUpdate) { $argList += '-NoMicrosoftUpdate' }
        if ($WindowsUpdate)     { $argList += '-WindowsUpdate' }
        if ($Winget)            { $argList += '-Winget' }
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
            $wtArgs = @('new-tab', '--title', '"Update CLI"', "`"$exe`"") + $argList
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
        $selected = Resolve-Selection (($Install | ForEach-Object { $map[$_] }) -join ' ')
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
            try { $selected = Resolve-Selection $answer } catch { Write-Line "  $($_.Exception.Message)" Red; continue }
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
    function Invoke-WingetPart {
        Write-Line '  WINGET APP UPGRADES' White
        Write-Line
        $wg = Get-Command winget.exe -ErrorAction SilentlyContinue
        if (-not $wg) {
            Write-Line '  winget was not found. Install "App Installer" from the Microsoft Store, then try again.' Red
            Write-Line
            return
        }

        $wgText = @{
            '8A15002B' = 'no applicable upgrade for this system'
            '8A150014' = 'package not found'
            '8A150101' = 'the app is in use - close it and retry'
            '8A150109' = 'restart needed to finish'
        }
        function Format-WingetCode([int]$code) {
            $hex = '{0:X8}' -f $code
            if ($wgText.ContainsKey($hex)) { "0x$hex ($($wgText[$hex]))" } else { "0x$hex" }
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
            $chosen = Resolve-AppSelection 'u'
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
                try { $chosen = Resolve-AppSelection $answer } catch { Write-Line "  $($_.Exception.Message)" Red; continue }
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

    # ================================================================ MENU
    Write-Line
    Write-Line '  Update CLI' White
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($os) { Write-Line ("  {0}  build {1}" -f $os.Caption, $os.BuildNumber) DarkGray }
    Write-Line

    # Options given on the command line skip the menu.
    if ($Winget) { Invoke-WingetPart; return }
    if ($WindowsUpdate -or $ListOnly -or $Install -or $AutoReboot) { Invoke-WindowsUpdatePart; return }

    while ($true) {
        Write-Line '  1  ' White -NoNewline; Write-Line 'Windows Update CLI' Cyan -NoNewline
        Write-Line '    Windows, driver and Microsoft product updates' DarkGray
        Write-Line '  2  ' White -NoNewline; Write-Line 'Winget Update CLI ' Cyan -NoNewline
        Write-Line '    upgrade your installed apps' DarkGray
        Write-Line '  q  ' White -NoNewline; Write-Line 'Quit' Gray
        Write-Line
        $choice = (Read-Host '  Choose [1]').Trim()
        Write-Line
        if ($choice -match '^(q|quit|exit)$') { return }
        elseif ($choice -match '^1?$') { Invoke-WindowsUpdatePart }
        elseif ($choice -eq '2') { Invoke-WingetPart }
        else { Write-Line '  Please enter 1, 2 or q.' Yellow; Write-Line; continue }
        Write-Line ('  ' + ('=' * ((Get-ConsoleWidth) - 4))) DarkGray
        Write-Line
    }
}

Invoke-WUCli @args
