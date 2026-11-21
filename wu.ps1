<#
    wu.ps1 - a no-nonsense Windows Update CLI

    Quick start (paste into an admin or normal PowerShell / Terminal):
        irm https://andrewpayne68.github.io/wu | iex

    With options:
        & ([scriptblock]::Create((irm https://andrewpayne68.github.io/wu))) -ListOnly
        & ([scriptblock]::Create((irm https://andrewpayne68.github.io/wu))) -Install Recommended -AutoReboot

    Options:
        -ListOnly                 Just list available updates, install nothing.
        -Install <set[,set]>      Non-interactive: Recommended, Optional, Drivers or All.
        -AutoReboot               Reboot automatically if an update needs it.
        -NoMicrosoftUpdate        Only use Windows Update (skip Office / other MS products).

    Works with Windows PowerShell 5.1 and PowerShell 7+. Uses the built-in
    Windows Update Agent COM API - nothing extra is installed.
#>

function Invoke-WUCli {
    [CmdletBinding()]
    param(
        [switch]$ListOnly,
        # Recommended, Optional, Drivers or All. Checked below rather than with ValidateSet,
        # because the elevated relaunch passes "Recommended,Drivers" as a single string.
        [string[]]$Install,
        [switch]$AutoReboot,
        [switch]$NoMicrosoftUpdate
    )

    $ErrorActionPreference = 'Stop'
    if ($Install) {
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
            $wtArgs = @('new-tab', '--title', '"Windows Update"', "`"$exe`"") + $argList
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

    # ------------------------------------------------------------ banner
    Write-Line
    Write-Line '  Windows Update CLI' White
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($os) { Write-Line ("  {0}  build {1}" -f $os.Caption, $os.BuildNumber) DarkGray }
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
        $titleW = [Math]::Max(20, $w - 52)
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
            Write-Line '                   h <numbers>=hide   l=list again   q=quit' DarkGray
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
    Write-Line ("  Installing {0} update(s), up to {1} to download." -f $selected.Count, (Format-Size $totalSize)) White
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
                Write-Status ("        {0} 100%  {1}  downloaded in {2}" -f (Get-Bar 100), (Format-Size $s.Size), (Format-Elapsed $sw.Elapsed)) Green
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
    if ($toInstall.Count -gt 0) {
        Write-Line
        Write-Line '  INSTALL' Cyan
        $k = 0
        foreach ($s in $toInstall) {
            $k++
            $head = "  [{0}/{1}] {2}" -f $k, $toInstall.Count, $s.Title
            Write-Line (Limit-Text $head ((Get-ConsoleWidth) - 1)) White
            $coll = New-Object -ComObject Microsoft.Update.UpdateColl
            [void]$coll.Add($s.Update)
            $inst = $session.CreateUpdateInstaller()
            $inst.Updates = $coll
            $sw = [Diagnostics.Stopwatch]::StartNew()
            try {
                while ($inst.IsBusy) { Write-Status '      waiting for another installer to finish...' Yellow; Start-Sleep 2 }
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
                if ($ur.RebootRequired) { $rebootNeeded = $true }
                switch ($ur.ResultCode) {
                    2 {
                        $msg = if ($ur.RebootRequired) { 'installed - restart required' } else { 'installed' }
                        Write-Status ("        {0} 100%  {1}  ({2})" -f (Get-Bar 100), $msg, (Format-Elapsed $sw.Elapsed)) Green
                        $results[$s.Index] = if ($ur.RebootRequired) { 'Installed (restart required)' } else { 'Installed' }
                    }
                    3 {
                        Write-Status ("        installed with errors  {0}" -f (Format-HResult $ur.HResult)) Yellow
                        $results[$s.Index] = 'Installed with errors: ' + (Format-HResult $ur.HResult)
                    }
                    default {
                        Write-Status ("        install FAILED  {0}" -f (Format-HResult $ur.HResult)) Red
                        $results[$s.Index] = 'Install failed: ' + (Format-HResult $ur.HResult)
                    }
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
        $c = if ($st -like 'Installed*errors*') { 'Yellow' } elseif ($st -like 'Installed*') { 'Green' } else { 'Red' }
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
}

Invoke-WUCli @args
