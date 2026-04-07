#Requires -Version 5.1
<#
.SYNOPSIS
    Ebonhold HD Patcher - PowerShell edition.
    Patches a local Ebonhold installation using only built-in PowerShell / .NET methods.
    No external EXE tools are required.
.NOTES
    ZIP  : System.IO.Compression.ZipFile  (built-in .NET)
    RAR  : Windows Shell.Application COM  (built-in Windows, no 7z/WinRAR EXE needed)
    HTTP : System.Net.HttpWebRequest      (built-in .NET)
    GUI  : System.Windows.Forms          (built-in Windows PowerShell)
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression.FileSystem

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

# ── Constants ─────────────────────────────────────────────────────────────────
$AppVersion    = '1.0.0'
$WindowTitle   = 'Ebonhold HD Patcher'
$AppStorage    = 'EH-Patcher'
$SearchTarget  = 'ebonhold'
$DefaultLang   = 'en'
$BugReportsUrl = 'https://github.com/SypherRed/eh-patcher/issues'
$LaaFlag       = [uint16]0x0020
$DlTimeout     = 30000   # ms per HTTP call
$Languages     = @(
    @{ Label = 'English';  Code = 'en' },
    @{ Label = 'Deutsch';  Code = 'de' },
    @{ Label = 'Espanol';  Code = 'es' },
    @{ Label = 'Italiano'; Code = 'it' }
)
$SkipDirs = @('$recycle.bin','system volume information','windows','appdata',
              'programdata','temp','tmp','.git','__pycache__')

# ── Paths ─────────────────────────────────────────────────────────────────────
$Script:ScriptFile = $MyInvocation.MyCommand.Definition
$Script:AppDir     = Split-Path $Script:ScriptFile -Parent
$baseLocal = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA }
             elseif ($env:APPDATA)  { $env:APPDATA }
             else                   { $Script:AppDir }

$Script:UserDataDir = Join-Path $baseLocal $AppStorage
$legacyDir = Join-Path $baseLocal 'EH Patcher'
if ((-not (Test-Path $Script:UserDataDir)) -and (Test-Path $legacyDir)) {
    try { Move-Item $legacyDir $Script:UserDataDir -ErrorAction Stop } catch {}
}

$Script:ConfigPath = $null
foreach ($c in @((Join-Path $Script:UserDataDir 'patches.json'),
                  (Join-Path $Script:AppDir      'patches.json'))) {
    if (Test-Path $c) { $Script:ConfigPath = $c; break }
}

$Script:TransPath    = Join-Path $Script:AppDir     'translations.json'
$Script:SettingsPath = Join-Path $Script:UserDataDir 'settings.json'
$Script:StatePath    = Join-Path $Script:UserDataDir 'patch_state.json'
$Script:LogPath      = Join-Path $Script:UserDataDir 'patcher.log'
$Script:PatchData    = Join-Path $Script:UserDataDir '.patcher-data'
$Script:BackupsDir   = Join-Path $Script:PatchData 'backups'
$Script:CacheDir     = Join-Path $Script:PatchData 'downloads'
$Script:IcoPath      = Join-Path $Script:AppDir 'icon.ico'
$Script:PngPath      = @(
    (Join-Path $Script:AppDir 'icon-app.png'),
    (Join-Path $Script:AppDir 'icon.png')
) | Where-Object { Test-Path $_ } | Select-Object -First 1

# ── JSON helpers ──────────────────────────────────────────────────────────────
function Read-AppJson([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    try {
        $t = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
        return ConvertFrom-Json $t
    } catch { return $null }
}

function Write-AppJson([string]$Path, [object]$Data) {
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, (ConvertTo-Json $Data -Depth 10),
        [System.Text.Encoding]::UTF8)
}

# ── Error log ─────────────────────────────────────────────────────────────────
function Write-AppLog([string]$Event, [string]$Msg, [hashtable]$Ctx = @{}) {
    $dir = Split-Path $Script:LogPath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $ts   = [System.DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')
    $safe = $Msg -replace 'https?://\S+', '[redacted-url]'
    $sb   = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("[$ts] $Event")
    [void]$sb.AppendLine("message=$safe")
    foreach ($k in $Ctx.Keys) {
        [void]$sb.AppendLine("${k}=$([string]$Ctx[$k] -replace 'https?://\S+','[redacted-url]')")
    }
    [void]$sb.AppendLine('')
    [System.IO.File]::AppendAllText($Script:LogPath, $sb.ToString(),
        [System.Text.Encoding]::UTF8)
}

# ── Translations ──────────────────────────────────────────────────────────────
$Script:Translations = Read-AppJson $Script:TransPath
$Script:Lang = $DefaultLang

function T([string]$Key, [hashtable]$P = @{}) {
    $map = $null
    if ($Script:Translations) {
        $names = $Script:Translations.PSObject.Properties.Name
        if ($names -contains $Script:Lang) { $map = $Script:Translations.($Script:Lang) }
        elseif ($names -contains 'en')     { $map = $Script:Translations.en }
    }
    $tpl = if ($map -and ($map.PSObject.Properties.Name -contains $Key)) {
        [string]$map.$Key
    } else { $Key }
    foreach ($k in $P.Keys) {
        $tpl = $tpl -replace [regex]::Escape("{$k}"), [string]$P[$k]
    }
    return $tpl
}

function Localize($Value, [string]$Fallback = '') {
    if ($null -eq $Value) { return $Fallback }
    if ($Value -is [string]) { return if ($Value) { $Value } else { $Fallback } }
    if ($Value -is [hashtable]) {
        if ($Value.ContainsKey($Script:Lang) -and $Value[$Script:Lang]) { return [string]$Value[$Script:Lang] }
        if ($Value.ContainsKey('en') -and $Value['en'])                 { return [string]$Value['en'] }
        $first = $Value.GetEnumerator() | Select-Object -First 1
        return if ($first -and $first.Value) { [string]$first.Value } else { $Fallback }
    }
    # PSCustomObject fallback
    $names = $Value.PSObject.Properties.Name
    if ($names -contains $Script:Lang) { $v = $Value.($Script:Lang); if ($v) { return [string]$v } }
    if ($names -contains 'en')         { $v = $Value.en;             if ($v) { return [string]$v } }
    $first = $Value.PSObject.Properties | Select-Object -First 1
    return if ($first -and $first.Value) { [string]$first.Value } else { $Fallback }
}

# ── Utilities ─────────────────────────────────────────────────────────────────
function Get-FileSha256([string]$Path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs  = [System.IO.File]::OpenRead($Path)
    try { return [BitConverter]::ToString($sha.ComputeHash($fs)).Replace('-', '').ToLower() }
    finally { $fs.Dispose(); $sha.Dispose() }
}

function Get-UrlDigest([string]$Url) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString(
            $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Url))
        ).Replace('-', '').ToLower()).Substring(0, 16)
    } finally { $sha.Dispose() }
}

function Format-Size([long]$B) {
    if ($B -lt 1KB) { return "$B B" }
    if ($B -lt 1MB) { return ('{0:F1} KB' -f ($B / 1KB)) }
    if ($B -lt 1GB) { return ('{0:F1} MB' -f ($B / 1MB)) }
    return ('{0:F1} GB' -f ($B / 1GB))
}

function Normalize-RelPath([string]$P) {
    return $P.Replace('/', '\').Trim('\', ' ').Trim()
}

function Get-VersionKey([string]$V) {
    return @(($V.TrimStart('v', 'V') -split '[.\-]') | ForEach-Object {
        if ($_ -match '^\d+$') { [int]$_ } else { $_.ToLower() }
    })
}

function Test-NewerVersion([string]$Candidate, [string]$Current) {
    $a = @(Get-VersionKey $Candidate)
    $b = @(Get-VersionKey $Current)
    for ($i = 0; $i -lt [Math]::Max($a.Count, $b.Count); $i++) {
        $av = if ($i -lt $a.Count) { $a[$i] } else { 0 }
        $bv = if ($i -lt $b.Count) { $b[$i] } else { 0 }
        if ($av -is [int] -and $bv -is [int]) {
            if ($av -gt $bv) { return $true }
            if ($av -lt $bv) { return $false }
        } else {
            $sc = [string]::Compare([string]$av, [string]$bv, $true)
            if ($sc -ne 0) { return $sc -gt 0 }
        }
    }
    return $false
}

# ── HTTP helpers ──────────────────────────────────────────────────────────────
function Test-Url([string]$Url) {
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method = 'HEAD'; $req.UserAgent = 'eh-patcher/1.0'; $req.Timeout = $DlTimeout
        $resp = $req.GetResponse()
        $code = [int]$resp.StatusCode
        $resp.Close()
        return ($code -ge 200 -and $code -lt 400)
    } catch [System.Net.WebException] {
        if ($_.Exception.Response) {
            $c = [int]$_.Exception.Response.StatusCode
            if ($c -in 403, 405) {
                try {
                    $r2 = [System.Net.HttpWebRequest]::Create($Url)
                    $r2.UserAgent = 'eh-patcher/1.0'; $r2.Timeout = $DlTimeout
                    $r2.AddRange(0, 0)
                    $rsp2 = $r2.GetResponse()
                    $c2   = [int]$rsp2.StatusCode
                    $rsp2.Close()
                    return ($c2 -ge 200 -and $c2 -lt 400)
                } catch { return $false }
            }
        }
        return $false
    } catch { return $false }
}

function Resolve-DownloadUrl([string]$Url) {
    $uri = [System.Uri]$Url
    if ($uri.Host -match 'mediafire\.com' -and $uri.PathAndQuery -match '/file/') {
        $req  = [System.Net.HttpWebRequest]::Create($Url)
        $req.UserAgent = 'eh-patcher/1.0'; $req.Timeout = $DlTimeout
        $resp = $req.GetResponse()
        $ct   = $resp.ContentType
        if ($ct -notmatch 'text/html') {
            $final = $resp.ResponseUri.AbsoluteUri; $resp.Close()
            return if ($final) { $final } else { $Url }
        }
        $html = (New-Object System.IO.StreamReader($resp.GetResponseStream())).ReadToEnd()
        $resp.Close()
        foreach ($pat in @(
            'href="(https://download[^"]+)"',
            'id="downloadButton"[^>]*href="([^"]+)"',
            'aria-label="Download file"[^>]*href="([^"]+)"')) {
            if ($html -match $pat) {
                return [System.Web.HttpUtility]::HtmlDecode($Matches[1])
            }
        }
        throw 'Could not resolve MediaFire download link.'
    }
    return $Url
}

function Invoke-Download(
    [string]$Url, [string]$Dest,
    [scriptblock]$OnProgress = $null,
    [scriptblock]$OnStatus   = $null) {

    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.UserAgent = 'eh-patcher/1.0'
    $req.Timeout   = $DlTimeout * 20   # allow longer for actual file downloads
    $resp  = $req.GetResponse()
    $total = $resp.ContentLength
    $src   = $resp.GetResponseStream()
    $destDir = Split-Path $Dest -Parent
    if ($destDir -and -not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }
    $dst  = [System.IO.File]::Create($Dest)
    $buf  = New-Object byte[] 524288
    $done = [long]0
    try {
        while ($true) {
            $n = $src.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $dst.Write($buf, 0, $n); $done += $n
            if ($total -gt 0) {
                if ($OnProgress) { & $OnProgress ($done / $total) }
                if ($OnStatus)   { & $OnStatus $done $total }
            }
        }
        if ($OnProgress) { & $OnProgress 1.0 }
    } finally { $dst.Dispose(); $src.Dispose(); $resp.Close() }
}

function Get-CachePath([string]$Url, [string]$Filename) {
    if (-not (Test-Path $Script:CacheDir)) {
        New-Item -ItemType Directory -Path $Script:CacheDir -Force | Out-Null
    }
    $pref = Join-Path $Script:CacheDir "$(Get-UrlDigest $Url)-$Filename"
    if (Test-Path $pref) { return $pref }
    $leg = Get-ChildItem $Script:CacheDir -Filter "*-$Filename" -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1
    return if ($leg) { $leg.FullName } else { $pref }
}

function Get-UrlFilename([string]$Url, [string]$Fallback) {
    $n = [System.IO.Path]::GetFileName(([System.Uri]$Url).LocalPath)
    return if ($n) { $n } else { "$Fallback.zip" }
}

function Get-GithubRelease([string]$Repo) {
    $req = [System.Net.HttpWebRequest]::Create(
        "https://api.github.com/repos/$Repo/releases/latest")
    $req.UserAgent = 'eh-patcher/1.0'; $req.Timeout = 20000
    $resp = $req.GetResponse()
    $json = (New-Object System.IO.StreamReader($resp.GetResponseStream())).ReadToEnd()
    $resp.Close()
    return ConvertFrom-Json $json
}

# ── Archive extraction — no external EXE ─────────────────────────────────────
function Expand-ArchiveTo([string]$Archive, [string]$Dest, [string]$OutputName = '') {
    if (-not (Test-Path $Dest)) {
        New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    }
    $ext = [System.IO.Path]::GetExtension($Archive).ToLower()
    switch ($ext) {
        '.zip' {
            [System.IO.Compression.ZipFile]::ExtractToDirectory($Archive, $Dest)
        }
        '.rar' {
            # Windows Shell.Application — registered on every Windows machine; no 7z/WinRAR EXE needed
            $shell   = New-Object -ComObject Shell.Application
            $archive = $shell.NameSpace($Archive)
            $folder  = $shell.NameSpace($Dest)
            if ($null -eq $archive) { throw "Cannot open RAR archive: $Archive" }
            $items = $archive.Items()
            $folder.CopyHere($items, 0x14)  # 0x4 = no UI dialog | 0x10 = yes to all prompts
            # CopyHere is asynchronous — poll until all items appear in destination
            $deadline = [System.DateTime]::Now.AddMinutes(10)
            while (([System.DateTime]::Now -lt $deadline) -and
                   ($folder.Items().Count -lt $items.Count)) {
                [System.Threading.Thread]::Sleep(300)
            }
        }
        default {
            # Non-archive single file: stage as-is
            $name = if ($OutputName) { $OutputName } else {
                [System.IO.Path]::GetFileName($Archive)
            }
            Copy-Item $Archive (Join-Path $Dest $name) -Force
        }
    }
}

# ── Large Address Aware ───────────────────────────────────────────────────────
function Test-Laa([string]$Path) {
    $fs = [System.IO.File]::OpenRead($Path)
    $br = [System.IO.BinaryReader]::new($fs)
    try {
        if ($br.ReadUInt16() -ne 0x5A4D) {
            throw (T 'exe_not_pe' @{ path = [System.IO.Path]::GetFileName($Path) })
        }
        [void]$fs.Seek(0x3C, 'Begin')
        $pe = $br.ReadUInt32()
        [void]$fs.Seek($pe, 'Begin')
        if ($br.ReadUInt32() -ne 0x00004550) {
            throw (T 'exe_not_pe' @{ path = [System.IO.Path]::GetFileName($Path) })
        }
        [void]$fs.Seek($pe + 22, 'Begin')
        return [bool]($br.ReadUInt16() -band $LaaFlag)
    } finally { $br.Dispose() }
}

function Set-Laa([string]$Path) {
    $fs = [System.IO.FileStream]::new($Path, 'Open', 'ReadWrite')
    $br = [System.IO.BinaryReader]::new($fs)
    $bw = [System.IO.BinaryWriter]::new($fs)
    try {
        if ($br.ReadUInt16() -ne 0x5A4D) {
            throw (T 'exe_not_pe' @{ path = [System.IO.Path]::GetFileName($Path) })
        }
        [void]$fs.Seek(0x3C, 'Begin')
        $pe = $br.ReadUInt32()
        [void]$fs.Seek($pe, 'Begin')
        if ($br.ReadUInt32() -ne 0x00004550) {
            throw (T 'exe_not_pe' @{ path = [System.IO.Path]::GetFileName($Path) })
        }
        $off   = $pe + 22
        [void]$fs.Seek($off, 'Begin')
        $chars = $br.ReadUInt16()
        if ($chars -band $LaaFlag) { return }
        [void]$fs.Seek($off, 'Begin')
        $bw.Write([uint16]($chars -bor $LaaFlag))
    } finally { $bw.Flush(); $fs.Dispose() }
}

# ── State management ──────────────────────────────────────────────────────────
$Script:InstallRecords = [System.Collections.Generic.List[object]]::new()

function Load-State {
    $raw = Read-AppJson $Script:StatePath
    $Script:InstallRecords = [System.Collections.Generic.List[object]]::new()
    if ($raw -and $raw.installs) {
        foreach ($r in $raw.installs) { $Script:InstallRecords.Add($r) }
    }
    # Migrate legacy hashed backup paths
    $changed = $false
    foreach ($rec in $Script:InstallRecords) {
        foreach ($entry in $rec.files) {
            $bRel = $entry.backup_path
            $rPath = $entry.relative_path
            if (-not $bRel -or -not $rPath) { continue }
            $bAbs = Join-Path $Script:PatchData $bRel
            $expName = [System.IO.Path]::GetFileName($rPath)
            if (Test-Path $bAbs) {
                if ($bAbs -match '^[0-9a-f]{16}-') {
                    $newPath = Join-Path (Split-Path $bAbs -Parent) $expName
                    if (-not (Test-Path $newPath)) {
                        try { [System.IO.File]::Move($bAbs, $newPath); $changed = $true } catch {}
                    }
                }
            }
        }
    }
    if ($changed) { Save-State }
}

function Save-State {
    Write-AppJson $Script:StatePath @{ installs = @($Script:InstallRecords) }
}

function Find-Record([string]$PatchId, [string]$TargetRoot) {
    $norm = $TargetRoot.ToLower()
    return $Script:InstallRecords |
        Where-Object {
            $_.patch_id -eq $PatchId -and
            ([string]$_.target_root).ToLower() -eq $norm
        } | Select-Object -First 1
}

function Remove-Record([string]$PatchId, [string]$TargetRoot) {
    $norm = $TargetRoot.ToLower()
    $keep = @($Script:InstallRecords | Where-Object {
        -not ($_.patch_id -eq $PatchId -and
              ([string]$_.target_root).ToLower() -eq $norm)
    })
    $Script:InstallRecords = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $keep) { $Script:InstallRecords.Add($r) }
}

function Upsert-Record([object]$Rec) {
    Remove-Record $Rec.patch_id $Rec.target_root
    $Script:InstallRecords.Add($Rec)
    Save-State
}

function New-InstallId([string]$PatchId) {
    return "$PatchId-$($Script:InstallRecords.Count + 1)"
}

# ── Config loading ────────────────────────────────────────────────────────────
$Script:Groups     = @()
$Script:Standalone = @()
$Script:CurrentVer = $AppVersion
$Script:UpdateRepo = ''
$Script:UpdateAsset = ''

function Parse-LocalizedText($Value) {
    if ($null -eq $Value) { return @{} }
    if ($Value -is [string]) {
        $s = $Value.Trim()
        return if ($s) { @{ en = $s } } else { @{} }
    }
    $d = @{}
    foreach ($p in $Value.PSObject.Properties) {
        $s = [string]$p.Value
        if ($s.Trim()) { $d[$p.Name] = $s }
    }
    return $d
}

function Parse-NoticeKind($patch) {
    $n = if ($patch.PSObject.Properties.Name -contains 'notice') { $patch.notice } else { $null }
    if ($n -is [string] -and $n) { return 'info' }
    if ($n -and ($n.PSObject.Properties.Name -contains 'type')) {
        $k = ([string]$n.type).Trim().ToLower()
        return if ($k) { $k } else { 'info' }
    }
    if ($patch.PSObject.Properties.Name -contains 'info' -and $patch.info) { return 'info' }
    return $null
}

function Parse-NoticeText($patch) {
    $n = if ($patch.PSObject.Properties.Name -contains 'notice') { $patch.notice } else { $null }
    if ($n -is [string]) { return Parse-LocalizedText $n }
    if ($n -and ($n.PSObject.Properties.Name -contains 'text')) { return Parse-LocalizedText $n.text }
    if ($patch.PSObject.Properties.Name -contains 'info') { return Parse-LocalizedText $patch.info }
    return @{}
}

function Parse-Patch($raw) {
    $type = ([string]$(if ($raw.PSObject.Properties.Name -contains 'patch_type') { $raw.patch_type } else { '' })).Trim().ToLower()
    if (-not $type) { $type = 'archive' }

    $targetExe = if ($raw.PSObject.Properties.Name -contains 'target_executable') {
        Normalize-RelPath ([string]$raw.target_executable)
    } else { '' }

    $sources = @()
    if ($raw.PSObject.Properties.Name -contains 'sources') {
        $i = 0
        foreach ($s in $raw.sources) {
            $sources += @{ label = if ($s.label) { [string]$s.label } else { "Mirror $($i+1)" }; url = [string]$s.url }
            $i++
        }
    }

    $pname = Parse-LocalizedText (if ($raw.PSObject.Properties.Name -contains 'name') { $raw.name } else { $raw.id })
    $pid   = [string]$raw.id

    if ($type -in 'large_address_aware', 'laa') {
        if (-not $targetExe) { throw (T 'cfg_exe' @{ name = Localize $pname $pid }) }
    } elseif (-not $sources) {
        throw (T 'cfg_src' @{ name = Localize $pname $pid })
    }

    $subDirs = if ($raw.PSObject.Properties.Name -contains 'target_subdirectories') {
        $arr = @($raw.target_subdirectories | ForEach-Object {
            $t = Normalize-RelPath ([string]$_); if ($t) { $t }
        })
        if ($arr) { $arr } else { @('') }
    } elseif ($raw.PSObject.Properties.Name -contains 'target_subdirectory') {
        @(Normalize-RelPath ([string]$raw.target_subdirectory))
    } else { @('') }

    $expFiles = if ($raw.PSObject.Properties.Name -contains 'expected_files') {
        @($raw.expected_files | ForEach-Object {
            $t = Normalize-RelPath ([string]$_); if ($t) { $t }
        })
    } else { @() }

    $selects = if ($raw.PSObject.Properties.Name -contains 'selects') {
        $v = $raw.selects
        if ($v -is [string]) { @($v) } else { @($v | ForEach-Object { [string]$_ }) }
    } else { @() }

    return @{
        id          = $pid
        name        = $pname
        description = Parse-LocalizedText (if ($raw.PSObject.Properties.Name -contains 'description') { $raw.description } else { '' })
        noticeKind  = Parse-NoticeKind $raw
        noticeText  = Parse-NoticeText $raw
        patchType   = $type
        subDirs     = $subDirs
        expFiles    = $expFiles
        requires    = if ($raw.PSObject.Properties.Name -contains 'requires') { [string]$raw.requires } else { $null }
        selects     = $selects
        targetExe   = $targetExe
        sources     = $sources
    }
}

function Load-Config {
    if (-not $Script:ConfigPath -or -not (Test-Path $Script:ConfigPath)) {
        throw (T 'cfg_missing' @{ name = 'patches.json' })
    }
    $raw = Read-AppJson $Script:ConfigPath
    if (-not $raw) { throw (T 'cfg_missing' @{ name = 'patches.json' }) }

    if ($raw.PSObject.Properties.Name -contains 'app_update') {
        $upd = $raw.app_update
        $v   = [string]$upd.current_version
        $Script:CurrentVer  = if ($v) { $v } else { $AppVersion }
        $Script:UpdateRepo  = [string]$upd.github_repo
        $Script:UpdateAsset = [string]$upd.asset_name
    }

    $groups = @(); $standalone = @()
    foreach ($entry in $raw.patches) {
        if ($entry.PSObject.Properties.Name -contains 'items') {
            $items = @($entry.items | ForEach-Object { Parse-Patch $_ })
            if (-not $items) {
                throw (T 'cfg_group_empty' @{
                    name = Localize (Parse-LocalizedText $entry.name) ([string]$entry.id)
                })
            }
            $groups += @(@{
                id          = [string]$entry.id
                name        = Parse-LocalizedText $entry.name
                description = Parse-LocalizedText (
                    if ($entry.PSObject.Properties.Name -contains 'description') { $entry.description } else { '' })
                items       = $items
            })
        } else {
            $standalone += @(Parse-Patch $entry)
        }
    }
    if (-not $groups -and -not $standalone) { throw (T 'cfg_patches') }
    $Script:Groups     = $groups
    $Script:Standalone = $standalone
}

# ── Drive / path search ───────────────────────────────────────────────────────
function Find-GameFolder([string]$Root, [scriptblock]$StatusCb = $null) {
    $found   = [System.Collections.Generic.List[string]]::new()
    $stack   = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($Root)
    $visited = 0
    while ($stack.Count -and $found.Count -lt 5) {
        $dir = $stack.Pop()
        if (-not (Test-Path $dir -PathType Container)) { continue }
        $visited++
        if ($StatusCb -and ($visited -eq 1 -or $visited % 150 -eq 0)) {
            & $StatusCb $Root $dir
        }
        if ([System.IO.Path]::GetFileName($dir).ToLower() -eq $SearchTarget) {
            $found.Add($dir); continue
        }
        try {
            foreach ($sub in [System.IO.Directory]::GetDirectories($dir)) {
                $name = [System.IO.Path]::GetFileName($sub).ToLower()
                if ($name -notin $SkipDirs) { $stack.Push($sub) }
            }
        } catch {}
    }
    return @($found)
}

# ── Patch-active detection ────────────────────────────────────────────────────
function Test-PatchActive([hashtable]$Patch, [string]$TargetRoot) {
    if ($Patch.patchType -in 'large_address_aware', 'laa') {
        if (-not $Patch.targetExe) { return $false }
        $exe = Join-Path $TargetRoot $Patch.targetExe
        if (-not (Test-Path $exe -PathType Leaf)) { return $false }
        try { return Test-Laa $exe } catch { return $false }
    }
    if ($Patch.expFiles.Count -gt 0) {
        return -not ($Patch.expFiles | Where-Object { -not (Test-Path (Join-Path $TargetRoot $_)) })
    }
    $rec = Find-Record $Patch.id $TargetRoot
    if (-not $rec) { return $false }
    return -not ($rec.files | Where-Object { -not (Test-Path (Join-Path $TargetRoot $_.relative_path)) })
}

# ── Install ───────────────────────────────────────────────────────────────────
function Install-LaaPatch([hashtable]$Patch, [string]$TargetRoot) {
    $exe = Join-Path $TargetRoot $Patch.targetExe
    if (-not (Test-Path $exe)) {
        throw (T 'exe_missing' @{ name = Localize $Patch.name $Patch.id; path = $Patch.targetExe })
    }
    if (-not (Test-Path $exe -PathType Leaf)) {
        throw (T 'exe_invalid' @{ path = $Patch.targetExe })
    }
    $old = Find-Record $Patch.id $TargetRoot
    $oldBackups = @{}
    if ($old) { foreach ($f in $old.files) { $oldBackups[$f.relative_path] = $f.backup_path } }

    $instId  = New-InstallId $Patch.id
    $relPath = $Patch.targetExe.Replace('/', '\')
    $bPath   = $oldBackups[$relPath]
    if (-not $bPath) {
        $bFile = Join-Path $Script:BackupsDir "$instId\$relPath"
        $bDir  = Split-Path $bFile -Parent
        if (-not (Test-Path $bDir)) { New-Item -ItemType Directory -Path $bDir -Force | Out-Null }
        Copy-Item $exe $bFile -Force
        $bPath = "$instId\$relPath"
    }
    Set-Laa $exe
    return @{
        patch_id    = $Patch.id
        target_root = $TargetRoot
        install_id  = $instId
        patch_type  = 'large_address_aware'
        files       = @(@{ relative_path = $relPath; backup_path = $bPath; sha256 = (Get-FileSha256 $exe) })
    }
}

function Install-ArchivePatch(
    [hashtable]$Patch,
    [string]$TargetRoot,
    [string]$TempDir,
    [int]$I, [int]$N,
    [scriptblock]$StatusCb,
    [scriptblock]$ProgressCb) {

    $label = Localize $Patch.name $Patch.id
    & $StatusCb (T 'check' @{ i = $I; n = $N; name = $label })
    & $ProgressCb 5

    # Resolve a working source
    $source = $null
    foreach ($src in $Patch.sources) {
        & $StatusCb (T 'check_source' @{ name = $label })
        try {
            $resolved = Resolve-DownloadUrl $src.url
            if (Test-Url $resolved) {
                $source = @{ label = $src.label; url = $resolved; cacheKey = $src.url }
                break
            }
        } catch {
            Write-AppLog 'source_resolve' $_.Exception.Message @{
                patch_id = $Patch.id; source_label = $src.label
            }
        }
    }
    if (-not $source) { throw (T 'no_source' @{ name = $label }) }

    $filename  = Get-UrlFilename $source.url $Patch.id
    $cachePath = Get-CachePath $source.cacheKey $filename
    $stageDir  = Join-Path $TempDir "$($Patch.id)-stage"
    if (Test-Path $stageDir) { Remove-Item $stageDir -Recurse -Force }
    New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

    $usedCache = (Test-Path $cachePath) -and ([System.IO.FileInfo]$cachePath).Length -gt 0
    if ($usedCache) {
        & $StatusCb (T 'using_cached_patch' @{ i = $I; n = $N; name = $label })
        & $ProgressCb 78
    } else {
        & $StatusCb (T 'download' @{ i = $I; n = $N; name = $label })
        Invoke-Download $source.url $cachePath `
            -OnProgress { param($f) & $ProgressCb (8 + $f * 70) } `
            -OnStatus   { param($d, $t)
                & $StatusCb "$(T 'download' @{i=$I;n=$N;name=$label}) ($(Format-Size $d) / $(Format-Size $t))"
            }
    }

    & $StatusCb (T 'extract_archive' @{ i = $I; n = $N; name = $label })
    & $ProgressCb 82
    try {
        Expand-ArchiveTo $cachePath $stageDir $filename
    } catch {
        if (-not $usedCache) {
            try { Remove-Item $cachePath -Force } catch {}
            throw
        }
        # Cached file may be corrupt — delete and re-download
        if (Test-Path $stageDir) { Remove-Item $stageDir -Recurse -Force }
        New-Item -ItemType Directory -Path $stageDir -Force | Out-Null
        try { Remove-Item $cachePath -Force } catch {}
        & $StatusCb (T 'download' @{ i = $I; n = $N; name = $label })
        Invoke-Download $source.url $cachePath `
            -OnProgress { param($f) & $ProgressCb (8 + $f * 70) } `
            -OnStatus   { param($d, $t)
                & $StatusCb "$(T 'download' @{i=$I;n=$N;name=$label}) ($(Format-Size $d) / $(Format-Size $t))"
            }
        Expand-ArchiveTo $cachePath $stageDir $filename
    }

    & $StatusCb (T 'apply_status' @{ i = $I; n = $N; name = $label })
    & $ProgressCb 92
    return Apply-StagedPatch $Patch $stageDir $TargetRoot
}

function Apply-StagedPatch([hashtable]$Patch, [string]$StageDir, [string]$TargetRoot) {
    $old = Find-Record $Patch.id $TargetRoot
    $oldBackups = @{}
    if ($old) { foreach ($f in $old.files) { $oldBackups[$f.relative_path] = $f.backup_path } }

    $instId = New-InstallId $Patch.id
    $staged = @(Get-ChildItem $StageDir -Recurse -File)
    if (-not $staged) { throw (T 'empty_archive' @{ name = Localize $Patch.name $Patch.id }) }

    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($subDir in $Patch.subDirs) {
        $base = if ($subDir) { Join-Path $TargetRoot $subDir } else { $TargetRoot }
        foreach ($file in $staged) {
            $rel     = $file.FullName.Substring($StageDir.Length).TrimStart('\', '/')
            $dest    = Join-Path $base $rel
            $destDir = Split-Path $dest -Parent
            if (-not (Test-Path $destDir)) {
                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            }
            # Prune any legacy hashed-name artifacts
            $fname   = [System.IO.Path]::GetFileName($dest)
            $pattern = [regex]"^[0-9a-f]{16}-$([regex]::Escape($fname))$"
            Get-ChildItem $destDir -Filter "*-$fname" -ErrorAction SilentlyContinue |
                Where-Object { $pattern.IsMatch($_.Name) } |
                ForEach-Object { try { Remove-Item $_.FullName -Force } catch {} }

            $relToRoot  = $dest.Substring($TargetRoot.Length).TrimStart('\', '/').Replace('/', '\')
            $backupPath = $oldBackups[$relToRoot]
            if ((Test-Path $dest) -and -not $backupPath) {
                $bFile = Join-Path $Script:BackupsDir "$instId\$relToRoot"
                $bDir  = Split-Path $bFile -Parent
                if (-not (Test-Path $bDir)) {
                    New-Item -ItemType Directory -Path $bDir -Force | Out-Null
                }
                Copy-Item $dest $bFile -Force
                $backupPath = "$instId\$relToRoot"
            }
            Copy-Item $file.FullName $dest -Force
            $records.Add(@{
                relative_path = $relToRoot
                backup_path   = $backupPath
                sha256        = (Get-FileSha256 $dest)
            })
        }
    }
    # Deduplicate by relative_path (last wins)
    $deduped = @{}
    foreach ($r in $records) { $deduped[$r.relative_path] = $r }

    return @{
        patch_id    = $Patch.id
        target_root = $TargetRoot
        install_id  = $instId
        patch_type  = $Patch.patchType
        files       = @($deduped.Values)
    }
}

# ── Uninstall ─────────────────────────────────────────────────────────────────
function Uninstall-Patch([string]$PatchId, [string]$TargetRoot) {
    $rec = Find-Record $PatchId $TargetRoot
    if (-not $rec) { return }

    $touchedDirs = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($entry in @($rec.files)) {
        $file = Join-Path $TargetRoot $entry.relative_path
        [void]$touchedDirs.Add((Split-Path $file -Parent))
        $bRel = $entry.backup_path
        $bAbs = if ($bRel) { Join-Path $Script:PatchData $bRel } else { $null }
        if ($bAbs -and (Test-Path $bAbs)) {
            $fDir = Split-Path $file -Parent
            if (-not (Test-Path $fDir)) {
                New-Item -ItemType Directory -Path $fDir -Force | Out-Null
            }
            Copy-Item $bAbs $file -Force
            continue
        }
        if ((Test-Path $file -PathType Leaf) -and
            (Get-FileSha256 $file) -eq $entry.sha256) {
            Remove-Item $file -Force
        }
    }
    foreach ($dir in ($touchedDirs | Sort-Object { ([string]$_).Split('\').Count } -Descending)) {
        $cur = [string]$dir
        while ($cur -ne $TargetRoot -and (Test-Path $cur -PathType Container)) {
            try { [System.IO.Directory]::Delete($cur); $cur = Split-Path $cur -Parent }
            catch { break }
        }
    }
    Remove-Record $PatchId $TargetRoot
    Save-State
}

# ── Self-update ───────────────────────────────────────────────────────────────
function Get-UpdateAsset([object]$Release) {
    $assets = @($Release.assets)
    if (-not $assets) { return $null }
    if ($Script:UpdateAsset) {
        $exact    = $assets | Where-Object { $_.name -ieq $Script:UpdateAsset } | Select-Object -First 1
        if ($exact) { return $exact }
        $norm     = $Script:UpdateAsset -replace '[\s._-]', '' | ForEach-Object { $_.ToLower() }
        $tolerant = $assets | Where-Object {
            ($_.name -replace '[\s._-]', '').ToLower() -eq $norm
        } | Select-Object -First 1
        if ($tolerant) { return $tolerant }
    }
    # Prefer .ps1 assets, fall back to any asset
    $ps1 = $assets | Where-Object { $_.name -imatch '\.ps1$' } | Select-Object -First 1
    return if ($ps1) { $ps1 } else { $assets | Select-Object -First 1 }
}

function Apply-ScriptUpdate([string]$DownloadPath) {
    $batchLines = @(
        '@echo off', 'setlocal',
        ":retry",
        "copy /Y `"$DownloadPath`" `"$Script:ScriptFile`" >nul",
        'if errorlevel 1 ( timeout /t 2 /nobreak >nul & goto retry )',
        "del `"$DownloadPath`" >nul 2>&1",
        "powershell.exe -ExecutionPolicy Bypass -NonInteractive -File `"$Script:ScriptFile`"",
        'del "%~f0" >nul 2>&1'
    )
    $batchPath = [System.IO.Path]::ChangeExtension($DownloadPath, '.cmd')
    [System.IO.File]::WriteAllText($batchPath, ($batchLines -join "`r`n") + "`r`n",
        [System.Text.Encoding]::ASCII)
    Start-Process -FilePath 'cmd.exe' -ArgumentList "/c `"$batchPath`""
    $Script:Form.Close()
}

# ── GUI helpers ───────────────────────────────────────────────────────────────
$Script:PatchChecks   = @{}   # patch_id  -> CheckBox
$Script:GroupChecks   = @{}   # group_id  -> CheckBox
$Script:GroupPanels   = @{}   # group_id  -> Panel (items container)
$Script:GroupExpanded = @{}   # group_id  -> [bool]
$Script:GroupTogBtns  = @{}   # group_id  -> Button
$Script:PatchRequires = @{}   # patch_id  -> string|null
$Script:PatchSelects  = @{}   # patch_id  -> string[]
$Script:PatchDeps     = @{}   # patch_id  -> string[] (who depends on this)
$Script:PatchGroupMap = @{}   # patch_id  -> group_id|null
$Script:AllPatches    = @{}   # patch_id  -> patch hashtable
$Script:AllGroups     = @{}   # group_id  -> group hashtable
$Script:ActiveIds     = [System.Collections.Generic.HashSet[string]]::new()
$Script:IsBusy        = $false
$Script:Settings      = @{}

$Script:ColorDark     = [System.Drawing.Color]::FromArgb(85, 85, 85)
$Script:ColorNotice   = [System.Drawing.Color]::FromArgb(154, 103, 0)

function Set-Busy([bool]$Value) {
    $Script:IsBusy = $Value
    $Script:Form.Cursor = if ($Value) {
        [System.Windows.Forms.Cursors]::WaitCursor
    } else {
        [System.Windows.Forms.Cursors]::Default
    }
    $Script:BtnApply.Enabled     = -not $Value
    $Script:BtnUninstall.Enabled = -not $Value
    $Script:BtnSearch.Enabled    = -not $Value
    $Script:BtnChoose.Enabled    = -not $Value
    $Script:BtnUpdate.Enabled    = -not $Value
    $Script:BtnCache.Enabled     = -not $Value
}

function Set-Status([string]$Msg, [int]$Pct = -1) {
    $Script:StatusLabel.Text = $Msg
    if ($Pct -ge 0) { $Script:ProgressBar.Value = [Math]::Min(100, [Math]::Max(0, $Pct)) }
    [System.Windows.Forms.Application]::DoEvents()
}

function Get-TargetRoot {
    $raw = $Script:PathBox.Text.Trim()
    if (-not $raw) { return $null }
    $p = [System.IO.Path]::GetFullPath($raw)
    return if (Test-Path $p -PathType Container) { $p } else { $null }
}

function Set-TargetPath([string]$Path) {
    $Script:PathBox.Text = $Path
    $Script:Settings['last_target_path'] = $Path
    Write-AppJson $Script:SettingsPath $Script:Settings
}

function Get-NoticeBadge([hashtable]$Patch) {
    $kind = $Patch.noticeKind
    if (-not $kind) { return '' }
    $key = switch ($kind) {
        'info'          { 'patch_notice_info' }
        'warning'       { 'patch_notice_warning' }
        'compatibility' { 'patch_notice_compatibility' }
        default         { 'patch_notice_info' }
    }
    return T $key
}

function Get-PatchDisplayName([hashtable]$Patch, [bool]$Active) {
    $n = Localize $Patch.name $Patch.id
    $prefix = if ($Patch.requires) { '+ ' } else { '' }
    $suffix = if ($Active) { ' ✓' } else { '' }
    return "$prefix$n$suffix"
}

# ── Selection logic ───────────────────────────────────────────────────────────
function Select-RequiredChain([string]$PatchId) {
    $cur = $PatchId
    while ($cur -and $Script:PatchChecks.ContainsKey($cur)) {
        $Script:PatchChecks[$cur].Checked = $true
        $cur = $Script:PatchRequires[$cur]
    }
}

function Select-SelectsChain([string]$PatchId) {
    $pending = [System.Collections.Generic.Queue[string]]::new()
    foreach ($s in $Script:PatchSelects[$PatchId]) { $pending.Enqueue($s) }
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    while ($pending.Count) {
        $sid = $pending.Dequeue()
        if (-not $seen.Add($sid)) { continue }
        if (-not $Script:PatchChecks.ContainsKey($sid)) { continue }
        $Script:PatchChecks[$sid].Checked = $true
        Select-RequiredChain $sid
        foreach ($s2 in $Script:PatchSelects[$sid]) { $pending.Enqueue($s2) }
    }
}

function Deselect-Dependents([string]$PatchId) {
    $stack = [System.Collections.Generic.Stack[string]]::new()
    foreach ($d in $Script:PatchDeps[$PatchId]) { $stack.Push($d) }
    while ($stack.Count) {
        $did = $stack.Pop()
        if (-not $Script:PatchChecks.ContainsKey($did)) { continue }
        $Script:PatchChecks[$did].Checked = $false
        foreach ($d2 in $Script:PatchDeps[$did]) { $stack.Push($d2) }
    }
}

function Sync-GroupCheck([string]$GroupId) {
    if (-not $Script:GroupChecks.ContainsKey($GroupId)) { return }
    $grp = $Script:AllGroups[$GroupId]
    $allChecked = -not ($grp.items | Where-Object {
        -not $Script:PatchChecks[$_.id].Checked
    })
    $Script:GroupChecks[$GroupId].Checked = $allChecked
}

# ── Status refresh ────────────────────────────────────────────────────────────
function Refresh-Statuses {
    $target = Get-TargetRoot
    $Script:ActiveIds = [System.Collections.Generic.HashSet[string]]::new()
    $stateChanged = $false

    foreach ($patch in $Script:AllPatches.Values) {
        $active = $false
        if ($target) {
            $active = Test-PatchActive $patch $target
            if ($active) { [void]$Script:ActiveIds.Add($patch.id) }
            $stateChanged = (Sync-DetectedState $patch $target $active) -or $stateChanged
        }
        $cb = $Script:PatchChecks[$patch.id]
        if ($cb) {
            $cb.Text = Get-PatchDisplayName $patch $active
        }
    }
    if ($stateChanged) { Save-State }
}

function Sync-DetectedState([hashtable]$Patch, [string]$TargetRoot, [bool]$Active) {
    $rec = Find-Record $Patch.id $TargetRoot
    if ($Active -and -not $rec) {
        if (-not $Patch.expFiles.Count) { return $false }
        $Script:InstallRecords.Add(@{
            patch_id     = $Patch.id
            target_root  = $TargetRoot
            install_id   = (New-InstallId $Patch.id)
            patch_type   = $Patch.patchType
            detected_only = $true
            files        = @($Patch.expFiles | ForEach-Object {
                @{ relative_path = $_; backup_path = $null; sha256 = $null }
            })
        })
        return $true
    }
    if (-not $Active -and $rec -and $rec.PSObject.Properties.Name -contains 'detected_only' -and $rec.detected_only) {
        Remove-Record $Patch.id $TargetRoot
        return $true
    }
    return $false
}

# ── Build patch row ───────────────────────────────────────────────────────────
function Add-PatchRow([System.Windows.Forms.Control]$Parent, [hashtable]$Patch, [int]$Indent = 0, [string]$GroupId = '') {
    $row = New-Object System.Windows.Forms.Panel
    $row.AutoSize   = $true
    $row.AutoSizeMode = 'GrowAndShrink'
    $row.Padding    = [System.Windows.Forms.Padding]::new(0, 2, 0, 2)
    $row.Dock       = 'Top'

    # Indent spacer / dependency indicator
    if ($Patch.requires) {
        $bar = New-Object System.Windows.Forms.Panel
        $bar.Width      = 2
        $bar.Dock       = 'Left'
        $bar.BackColor  = [System.Drawing.Color]::FromArgb(183, 192, 200)
        $bar.Margin     = [System.Windows.Forms.Padding]::new($Indent, 0, 10, 0)
        $row.Controls.Add($bar)
    } else {
        $spacer = New-Object System.Windows.Forms.Panel
        $spacer.Width = $Indent; $spacer.Dock = 'Left'
        $row.Controls.Add($spacer)
    }

    $content = New-Object System.Windows.Forms.FlowLayoutPanel
    $content.FlowDirection = 'TopDown'
    $content.AutoSize      = $true
    $content.AutoSizeMode  = 'GrowAndShrink'
    $content.WrapContents  = $false
    $content.Dock          = 'Fill'
    $row.Controls.Add($content)

    $cb = New-Object System.Windows.Forms.CheckBox
    $cb.Text      = Get-PatchDisplayName $Patch ($Script:ActiveIds.Contains($Patch.id))
    $cb.AutoSize  = $true
    $cb.Tag       = $Patch.id
    $cb.Font      = $Script:Form.Font
    $Script:PatchChecks[$Patch.id] = $cb
    if ($GroupId) { $Script:PatchGroupMap[$Patch.id] = $GroupId }

    $pid = $Patch.id
    $cb.Add_Click({
        if ($cb.Checked) {
            Select-RequiredChain $pid
            Select-SelectsChain  $pid
        } else {
            Deselect-Dependents  $pid
        }
        if ($GroupId) { Sync-GroupCheck $GroupId }
    })
    $content.Controls.Add($cb)

    $desc = Localize $Patch.description ''
    if (-not $desc) { $desc = T 'nodesc' }
    $descLabel = New-Object System.Windows.Forms.Label
    $descLabel.Text      = $desc
    $descLabel.ForeColor = $Script:ColorDark
    $descLabel.AutoSize  = $false
    $descLabel.Height    = 0
    $descLabel.Padding   = [System.Windows.Forms.Padding]::new(24, 2, 0, 0)
    $descLabel.Tag       = "desc:$($Patch.id)"
    $content.Controls.Add($descLabel)

    if ($Patch.noticeKind) {
        $badge  = Get-NoticeBadge $Patch
        $ntext  = Localize $Patch.noticeText ''
        $notice = New-Object System.Windows.Forms.Label
        $notice.Text      = if ($ntext) { "${badge}: $ntext" } else { '' }
        $notice.ForeColor = $Script:ColorNotice
        $notice.AutoSize  = $false
        $notice.Height    = 0
        $notice.Padding   = [System.Windows.Forms.Padding]::new(24, 0, 0, 0)
        $notice.Tag       = "notice:$($Patch.id)"
        $content.Controls.Add($notice)
    }

    $Parent.Controls.Add($row)
    return $row
}

# ── Build group section ───────────────────────────────────────────────────────
function Add-GroupSection([System.Windows.Forms.Control]$Parent, [hashtable]$Group) {
    $Script:AllGroups[$Group.id]     = $Group
    $Script:GroupExpanded[$Group.id] = $true

    $wrapper = New-Object System.Windows.Forms.Panel
    $wrapper.AutoSize     = $true
    $wrapper.AutoSizeMode = 'GrowAndShrink'
    $wrapper.Dock         = 'Top'
    $wrapper.Padding      = [System.Windows.Forms.Padding]::new(0, 4, 0, 6)

    # Header row
    $header = New-Object System.Windows.Forms.FlowLayoutPanel
    $header.FlowDirection  = 'LeftToRight'
    $header.AutoSize       = $true
    $header.AutoSizeMode   = 'GrowAndShrink'
    $header.WrapContents   = $false
    $header.Dock           = 'Top'

    $toggleBtn = New-Object System.Windows.Forms.Button
    $toggleBtn.Text      = '-'
    $toggleBtn.Width     = 26
    $toggleBtn.Height    = 22
    $toggleBtn.FlatStyle = 'Flat'
    $toggleBtn.Tag       = $Group.id
    $Script:GroupTogBtns[$Group.id] = $toggleBtn
    $header.Controls.Add($toggleBtn)

    $gcb = New-Object System.Windows.Forms.CheckBox
    $gcb.Text     = Localize $Group.name $Group.id
    $gcb.AutoSize = $true
    $gcb.Font     = New-Object System.Drawing.Font($Script:Form.Font.FontFamily, $Script:Form.Font.Size, [System.Drawing.FontStyle]::Bold)
    $gcb.Tag      = $Group.id
    $Script:GroupChecks[$Group.id] = $gcb
    $gid = $Group.id

    $gcb.Add_Click({
        $val = $gcb.Checked
        foreach ($item in $Script:AllGroups[$gid].items) {
            $Script:PatchChecks[$item.id].Checked = $val
        }
    })
    $header.Controls.Add($gcb)
    $wrapper.Controls.Add($header)

    # Group description
    $gdesc = Localize $Group.description ''
    if ($gdesc) {
        $dl = New-Object System.Windows.Forms.Label
        $dl.Text      = $gdesc
        $dl.ForeColor = $Script:ColorDark
        $dl.AutoSize  = $false
        $dl.Height    = 0
        $dl.Padding   = [System.Windows.Forms.Padding]::new(28, 2, 0, 6)
        $dl.Dock      = 'Top'
        $dl.Tag       = "gdesc:$($Group.id)"
        $wrapper.Controls.Add($dl)
    }

    # Items container
    $itemsPanel = New-Object System.Windows.Forms.Panel
    $itemsPanel.AutoSize     = $true
    $itemsPanel.AutoSizeMode = 'GrowAndShrink'
    $itemsPanel.Dock         = 'Top'
    $Script:GroupPanels[$Group.id] = $itemsPanel

    $toggleBtn.Add_Click({
        $expanded = -not $Script:GroupExpanded[$gid]
        $Script:GroupExpanded[$gid] = $expanded
        $Script:GroupPanels[$gid].Visible = $expanded
        $Script:GroupTogBtns[$gid].Text   = if ($expanded) { '-' } else { '+' }
    })

    foreach ($patch in $Group.items) {
        $depth  = 0
        $cur    = $patch.requires
        while ($cur) { $depth++; $cur = $Script:PatchRequires[$cur] }
        $indent = 56 + ($depth * 24)
        Add-PatchRow $itemsPanel $patch $indent $Group.id | Out-Null
    }
    $wrapper.Controls.Add($itemsPanel)
    $Parent.Controls.Add($wrapper)

    # Separator
    $sep = New-Object System.Windows.Forms.Panel
    $sep.Height    = 1
    $sep.Dock      = 'Top'
    $sep.BackColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
    $Parent.Controls.Add($sep)
}

# ── Language refresh ──────────────────────────────────────────────────────────
function Refresh-Language {
    $Script:Form.Text                   = $WindowTitle
    $Script:VersionLabel.Text           = T 'version_label' @{ version = $Script:CurrentVer }
    $Script:BtnUpdate.Text              = T 'check_updates'
    $Script:BtnCache.Text               = T 'clear_cache'
    $Script:BtnInfo.Text                = T 'info_button'
    $Script:BtnRefresh.Text             = T 'refresh_list'
    $Script:LangLabel.Text              = T 'lang'
    $Script:GroupBoxTarget.Text         = T 'target'
    $Script:BtnChoose.Text              = T 'choose'
    $Script:BtnSearch.Text              = T 'search'
    $Script:NoteLabel.Text              = T 'note'
    $Script:GroupBoxPatches.Text        = T 'patches'
    $Script:HintLabel.Text              = T 'patch_hint'
    $Script:BtnApply.Text               = T 'apply'
    $Script:BtnUninstall.Text           = T 'uninstall'

    # Update group headers and patch checkboxes
    foreach ($gid in $Script:AllGroups.Keys) {
        $grp = $Script:AllGroups[$gid]
        if ($Script:GroupChecks.ContainsKey($gid)) {
            $Script:GroupChecks[$gid].Text = Localize $grp.name $gid
        }
    }

    # Resize desc labels now that text may have changed width/wrapping
    Refresh-Statuses
    Resize-Labels
}

function Resize-Labels {
    $availWidth = $Script:ScrollPanel.ClientSize.Width - 40
    foreach ($ctrl in $Script:InnerPanel.Controls) {
        Resize-ControlLabels $ctrl $availWidth
    }
}

function Resize-ControlLabels([System.Windows.Forms.Control]$Root, [int]$Width) {
    foreach ($child in $Root.Controls) {
        if ($child.Tag -is [string] -and ($child.Tag -match '^(desc|notice|gdesc):')) {
            $child.Width  = $Width
            $child.Height = if ($child.Text) {
                [int]($child.CreateGraphics().MeasureString($child.Text,
                    $child.Font, $Width).Height) + 6
            } else { 0 }
        } else {
            Resize-ControlLabels $child $Width
        }
    }
}

# ── Main operations ───────────────────────────────────────────────────────────
function Start-Search([bool]$ShowDialogs) {
    if ($Script:IsBusy) { return }
    Set-Busy $true
    Set-Status (T 'searching') 0

    $matches = @()
    foreach ($drive in [System.IO.DriveInfo]::GetDrives() |
                        Where-Object { $_.DriveType -in 'Fixed', 'Removable', 'Network' }) {
        if ($matches.Count) { break }
        $root = $drive.RootDirectory.FullName
        Set-Status (T 'search_in' @{ root = $root }) 0
        try {
            $matches += Find-GameFolder $root -StatusCb {
                param($r, $cur)
                Set-Status (T 'search_at' @{ root = $r; current = $cur }) -1
            }
        } catch {}
    }

    Set-Busy $false
    if (-not $matches) {
        Set-Status (T 'none') 0
        if ($ShowDialogs) {
            [System.Windows.Forms.MessageBox]::Show(
                $Script:Form, (T 'none_m'), (T 'none_t'),
                'OK', 'Information') | Out-Null
        }
    } elseif ($matches.Count -eq 1) {
        Set-TargetPath $matches[0]
        Set-Status (T 'found' @{ path = $matches[0] }) 0
        Refresh-Statuses
    } else {
        Set-TargetPath $matches[0]
        Set-Status (T 'multi' @{ path = $matches[0] }) 0
        if ($ShowDialogs) {
            [System.Windows.Forms.MessageBox]::Show(
                $Script:Form,
                (T 'multi_m' @{ matches = ($matches[0..9] -join "`n") }),
                (T 'multi_t'), 'OK', 'Information') | Out-Null
        }
        Refresh-Statuses
    }
}

function Start-Install {
    if ($Script:IsBusy) { return }
    $target = Get-TargetRoot
    if (-not $target) {
        [System.Windows.Forms.MessageBox]::Show(
            $Script:Form, (T 'no_target'), (T 'no_target_t'),
            'OK', 'Warning') | Out-Null
        return
    }
    $selected = @($Script:AllPatches.Values | Where-Object {
        $Script:PatchChecks[$_.id].Checked
    })
    if (-not $selected) {
        [System.Windows.Forms.MessageBox]::Show(
            $Script:Form, (T 'no_sel'), (T 'no_sel_t'),
            'OK', 'Warning') | Out-Null
        return
    }
    $candidates = @($selected | Where-Object { -not $Script:ActiveIds.Contains($_.id) })
    # Always include uninstalled LAA patches
    $laaNotActive = @($Script:AllPatches.Values | Where-Object {
        $_.patchType -in 'large_address_aware','laa' -and
        -not $Script:ActiveIds.Contains($_.id)
    })
    $seenIds = @($candidates | ForEach-Object { $_.id })
    $seen = [System.Collections.Generic.HashSet[string]]::new(
        [System.Collections.Generic.IEnumerable[string]][string[]]$seenIds)
    foreach ($lp in $laaNotActive) {
        if ($seen.Add($lp.id)) { $candidates += $lp }
    }
    if (-not $candidates) {
        [System.Windows.Forms.MessageBox]::Show(
            $Script:Form, (T 'already_installed_m'), (T 'already_installed_t'),
            'OK', 'Information') | Out-Null
        return
    }

    Set-Busy $true
    Set-Status (T 'installing') 0
    $n = $candidates.Count
    $tmpDir = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "eh-patcher-$(Get-Random)")
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

    $failures  = [System.Collections.Generic.List[string]]::new()
    $deferred  = [System.Collections.Generic.List[object]]::new()

    try {
        for ($i = 0; $i -lt $n; $i++) {
            $patch = $candidates[$i]
            $pct0  = [int](($i / $n) * 100)
            $pct1  = [int]((($i + 1) / $n) * 100)
            $Script:ProgressBar.Value = $pct0
            if ($patch.patchType -in 'large_address_aware', 'laa') {
                Set-Status (T 'apply_status' @{ i=($i+1); n=$n; name=Localize $patch.name $patch.id }) $pct0
                try {
                    $rec = Install-LaaPatch $patch $target
                    Upsert-Record $rec
                } catch {
                    $failures.Add("$(Localize $patch.name $patch.id): $_")
                    Write-AppLog 'laa_install' $_.Exception.Message @{ patch_id = $patch.id }
                }
                $Script:ProgressBar.Value = $pct1
            } else {
                try {
                    $rec = Install-ArchivePatch $patch $target $tmpDir ($i+1) $n `
                        -StatusCb   { param($m) Set-Status $m -1 } `
                        -ProgressCb { param($p) $Script:ProgressBar.Value = [Math]::Min(100,[int]($pct0 + ($pct1-$pct0)*$p/100)) }
                    Upsert-Record $rec
                    $Script:ProgressBar.Value = $pct1
                } catch {
                    $deferred.Add($patch)
                    Set-Status (T 'retry_later' @{ i=($i+1); n=$n; name=Localize $patch.name $patch.id }) $pct1
                }
            }
        }

        if ($deferred.Count) {
            $rn = $deferred.Count
            for ($ri = 0; $ri -lt $rn; $ri++) {
                $patch = $deferred[$ri]
                $rpct0 = [int](($ri / $rn) * 100)
                $rpct1 = [int]((($ri + 1) / $rn) * 100)
                Set-Status (T 'retry_now' @{ i=($ri+1); n=$rn; name=Localize $patch.name $patch.id }) $rpct0
                try {
                    $rec = Install-ArchivePatch $patch $target $tmpDir ($ri+1) $rn `
                        -StatusCb   { param($m) Set-Status $m -1 } `
                        -ProgressCb { param($p) $Script:ProgressBar.Value = [Math]::Min(100,[int]($rpct0 + ($rpct1-$rpct0)*$p/100)) }
                    Upsert-Record $rec
                } catch {
                    $failures.Add("$(Localize $patch.name $patch.id): $_")
                    Write-AppLog 'patch_install_retry' $_.Exception.Message @{ patch_id = $patch.id }
                }
            }
        }

        if ($failures.Count) {
            throw [System.Exception]::new(
                "Some patches could not be applied:`n`n" + ($failures -join "`n"))
        }

        $Script:ProgressBar.Value = 100
        Set-Status (T 'done') 100
        Refresh-Statuses
        [System.Windows.Forms.MessageBox]::Show(
            $Script:Form, (T 'done'), (T 'done_t'),
            'OK', 'Information') | Out-Null
    } catch {
        Write-AppLog 'patch_install' $_.Exception.Message
        Set-Status (T 'err') 0
        Refresh-Statuses
        [System.Windows.Forms.MessageBox]::Show(
            $Script:Form, $_.Exception.Message, (T 'err_t'),
            'OK', 'Error') | Out-Null
    } finally {
        Set-Busy $false
        $Script:ProgressBar.Value = 0
        if (Test-Path $tmpDir) {
            Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Start-Uninstall {
    if ($Script:IsBusy) { return }
    $target = Get-TargetRoot
    if (-not $target) {
        [System.Windows.Forms.MessageBox]::Show(
            $Script:Form, (T 'no_target'), (T 'no_target_t'),
            'OK', 'Warning') | Out-Null
        return
    }
    $selected = @($Script:AllPatches.Values | Where-Object {
        $Script:PatchChecks[$_.id].Checked -and $Script:ActiveIds.Contains($_.id)
    })
    if (-not $selected) {
        [System.Windows.Forms.MessageBox]::Show(
            $Script:Form, (T 'no_active_sel'), (T 'no_active_sel_t'),
            'OK', 'Warning') | Out-Null
        return
    }
    Set-Busy $true
    Set-Status (T 'uninstalling') 0
    $n = $selected.Count
    try {
        for ($i = 0; $i -lt $n; $i++) {
            $patch = $selected[$i]
            $pct   = [int](($i / $n) * 100)
            Set-Status (T 'uninstall_status' @{ i=($i+1); n=$n; name=Localize $patch.name $patch.id }) $pct
            try {
                Uninstall-Patch $patch.id $target
            } catch {
                Write-AppLog 'patch_uninstall' $_.Exception.Message @{ patch_id = $patch.id }
            }
        }
        $Script:ProgressBar.Value = 100
        Set-Status (T 'uninstall_done') 100
        Refresh-Statuses
        [System.Windows.Forms.MessageBox]::Show(
            $Script:Form, (T 'uninstall_done'), (T 'done_t'),
            'OK', 'Information') | Out-Null
    } catch {
        Write-AppLog 'patch_uninstall' $_.Exception.Message
        Set-Status (T 'err') 0
        Refresh-Statuses
        [System.Windows.Forms.MessageBox]::Show(
            $Script:Form, $_.Exception.Message, (T 'err_t'),
            'OK', 'Error') | Out-Null
    } finally {
        Set-Busy $false
        $Script:ProgressBar.Value = 0
    }
}

function Start-UpdateCheck([bool]$Silent = $false) {
    if ($Script:IsBusy) { return }
    if (-not $Script:UpdateRepo) {
        if (-not $Silent) {
            [System.Windows.Forms.MessageBox]::Show(
                $Script:Form, (T 'updates_not_configured'), (T 'updates_t'),
                'OK', 'Warning') | Out-Null
        }
        return
    }
    Set-Busy $true
    Set-Status (T 'updates_checking') 0
    try {
        $release = Get-GithubRelease $Script:UpdateRepo
        $latest  = $release.tag_name.TrimStart('v', 'V')
        if (-not (Test-NewerVersion $latest $Script:CurrentVer)) {
            Set-Status (T 'ready') 0
            if (-not $Silent) {
                [System.Windows.Forms.MessageBox]::Show(
                    $Script:Form,
                    (T 'updates_current' @{ version = $Script:CurrentVer }),
                    (T 'updates_t'), 'OK', 'Information') | Out-Null
            }
        } else {
            $msg = T 'updates_available' @{ current = $Script:CurrentVer; latest = $latest }
            $ans = [System.Windows.Forms.MessageBox]::Show(
                $Script:Form, $msg, (T 'updates_t'),
                'YesNo', 'Question')
            if ($ans -eq 'Yes') {
                $asset = Get-UpdateAsset $release
                if (-not $asset) {
                    [System.Windows.Forms.MessageBox]::Show(
                        $Script:Form,
                        (T 'updates_asset_missing' @{
                            asset   = $Script:UpdateAsset
                            release = $release.tag_name }),
                        (T 'updates_t'), 'OK', 'Error') | Out-Null
                } else {
                    Set-Status (T 'updates_downloading') 0
                    $dlUrl   = $asset.browser_download_url
                    $dlDest  = Join-Path ([System.IO.Path]::GetTempPath()) "eh-patcher-updates\$($asset.name)"
                    $dlDir   = Split-Path $dlDest -Parent
                    if (-not (Test-Path $dlDir)) {
                        New-Item -ItemType Directory -Path $dlDir -Force | Out-Null
                    }
                    Invoke-Download $dlUrl $dlDest `
                        -OnProgress { param($f)
                            $Script:ProgressBar.Value = [int]($f * 100)
                            [System.Windows.Forms.Application]::DoEvents()
                        } `
                        -OnStatus { param($d, $t)
                            Set-Status "$(T 'updates_downloading') ($(Format-Size $d) / $(Format-Size $t))" -1
                        }
                    Apply-ScriptUpdate $dlDest
                    return   # Apply-ScriptUpdate may close the form
                }
            }
            Set-Status (T 'ready') 0
        }
    } catch {
        Write-AppLog 'update_check' $_.Exception.Message @{ repo = $Script:UpdateRepo }
        if (-not $Silent) {
            [System.Windows.Forms.MessageBox]::Show(
                $Script:Form, $_.Exception.Message, (T 'updates_t'),
                'OK', 'Error') | Out-Null
        }
        Set-Status (T 'ready') 0
    } finally {
        Set-Busy $false
        $Script:ProgressBar.Value = 0
    }
}

function Clear-DownloadCache {
    if ($Script:IsBusy) { return }
    $choice = [System.Windows.Forms.MessageBox]::Show(
        $Script:Form, (T 'cache_prompt'), (T 'cache_t'),
        'YesNoCancel', 'Question')
    if ($choice -eq 'Cancel') { return }

    if (-not (Test-Path $Script:CacheDir)) {
        New-Item -ItemType Directory -Path $Script:CacheDir -Force | Out-Null
    }
    $files   = @(Get-ChildItem $Script:CacheDir -File -ErrorAction SilentlyContinue)
    $removed = 0

    if ($choice -eq 'Yes') {
        # Keep newest per basename, remove duplicates
        $grouped = @{}
        foreach ($f in $files) {
            $key = if ($f.Name -match '^[0-9a-f]{16}-(.+)$') { $Matches[1] } else { $f.Name }
            if (-not $grouped.ContainsKey($key)) { $grouped[$key] = @() }
            $grouped[$key] += $f
        }
        foreach ($g in $grouped.Values) {
            if ($g.Count -le 1) { continue }
            $keep = $g | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            foreach ($f in $g) {
                if ($f.FullName -ne $keep.FullName) {
                    try { Remove-Item $f.FullName -Force; $removed++ } catch {}
                }
            }
        }
        [System.Windows.Forms.MessageBox]::Show(
            $Script:Form,
            (T 'cache_cleared_keep_latest' @{ count = $removed }),
            (T 'cache_t'), 'OK', 'Information') | Out-Null
    } else {
        foreach ($f in $files) {
            try { Remove-Item $f.FullName -Force; $removed++ } catch {}
        }
        [System.Windows.Forms.MessageBox]::Show(
            $Script:Form,
            (T 'cache_cleared_all' @{ count = $removed }),
            (T 'cache_t'), 'OK', 'Information') | Out-Null
    }
    Set-Status (T 'ready') 0
}

function Show-InfoWindow {
    $win = New-Object System.Windows.Forms.Form
    $win.Text            = T 'info_title'
    $win.Size            = New-Object System.Drawing.Size(380, 240)
    $win.FormBorderStyle = 'FixedDialog'
    $win.MaximizeBox     = $false
    $win.MinimizeBox     = $false
    $win.StartPosition   = 'CenterParent'
    if ($Script:PngPath -and (Test-Path $Script:PngPath)) {
        try { $win.Icon = [System.Drawing.Icon]::FromHandle(
            ([System.Drawing.Bitmap]::new($Script:PngPath)).GetHicon()) } catch {}
    }

    $p = New-Object System.Windows.Forms.FlowLayoutPanel
    $p.FlowDirection = 'TopDown'
    $p.Dock          = 'Fill'
    $p.Padding       = [System.Windows.Forms.Padding]::new(12)
    $p.AutoSize      = $true

    $mkLbl = { param([string]$t, [bool]$bold = $false, [string]$fg = '')
        $l = New-Object System.Windows.Forms.Label
        $l.Text     = $t
        $l.AutoSize = $true
        if ($bold) { $l.Font = New-Object System.Drawing.Font($win.Font.FontFamily, $win.Font.Size, [System.Drawing.FontStyle]::Bold) }
        if ($fg)   { $l.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($fg) }
        $l
    }

    $p.Controls.Add((& $mkLbl (T 'info_title') $true))
    $p.Controls.Add((& $mkLbl (T 'info_version' @{ version = $Script:CurrentVer }) $false '#6a6a6a'))
    $p.Controls.Add((& $mkLbl (T 'info_author')  $false '#6a6a6a'))
    $p.Controls.Add((& $mkLbl (T 'info_sources')))
    $p.Controls.Add((& $mkLbl (T 'info_bugs')))

    $btnIssues = New-Object System.Windows.Forms.Button
    $btnIssues.Text     = T 'info_open_issues'
    $btnIssues.AutoSize = $true
    $btnIssues.Add_Click({ Start-Process $BugReportsUrl })
    $p.Controls.Add($btnIssues)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text        = T 'close'
    $btnClose.AutoSize    = $true
    $btnClose.DialogResult = 'OK'
    $p.Controls.Add($btnClose)
    $win.AcceptButton = $btnClose

    $win.Controls.Add($p)
    $win.ShowDialog($Script:Form) | Out-Null
}

# ── Build main window ─────────────────────────────────────────────────────────
function Build-UI {
    $Script:Form              = New-Object System.Windows.Forms.Form
    $Script:Form.Text         = $WindowTitle
    $Script:Form.Size         = New-Object System.Drawing.Size(980, 700)
    $Script:Form.MinimumSize  = New-Object System.Drawing.Size(900, 580)
    $Script:Form.StartPosition = 'CenterScreen'
    $Script:Form.Font         = New-Object System.Drawing.Font('Segoe UI', 9)

    if ($Script:IcoPath -and (Test-Path $Script:IcoPath)) {
        try { $Script:Form.Icon = New-Object System.Drawing.Icon($Script:IcoPath) } catch {}
    }

    $outer = New-Object System.Windows.Forms.TableLayoutPanel
    $outer.Dock        = 'Fill'
    $outer.ColumnCount = 1
    $outer.RowCount    = 6
    $outer.Padding     = [System.Windows.Forms.Padding]::new(18)
    $outer.RowStyles.Add([System.Windows.Forms.RowStyle]::new('AutoSize')) | Out-Null  # header
    $outer.RowStyles.Add([System.Windows.Forms.RowStyle]::new('AutoSize')) | Out-Null  # target
    $outer.RowStyles.Add([System.Windows.Forms.RowStyle]::new('Percent', 100)) | Out-Null  # patches
    $outer.RowStyles.Add([System.Windows.Forms.RowStyle]::new('AutoSize')) | Out-Null  # actions
    $outer.RowStyles.Add([System.Windows.Forms.RowStyle]::new('AutoSize')) | Out-Null  # progress
    $outer.RowStyles.Add([System.Windows.Forms.RowStyle]::new('AutoSize')) | Out-Null  # status

    # ── Header ────────────────────────────────────────────────────────────────
    $hdr = New-Object System.Windows.Forms.TableLayoutPanel
    $hdr.Dock        = 'Fill'
    $hdr.ColumnCount = 7
    $hdr.RowCount    = 2
    $hdr.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Percent', 100)) | Out-Null
    for ($ci = 1; $ci -le 6; $ci++) {
        $hdr.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('AutoSize')) | Out-Null
    }

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text     = $WindowTitle
    $titleLabel.Font     = New-Object System.Drawing.Font('Segoe UI', 18, [System.Drawing.FontStyle]::Bold)
    $titleLabel.AutoSize = $true
    $hdr.Controls.Add($titleLabel, 0, 0)

    $Script:VersionLabel           = New-Object System.Windows.Forms.Label
    $Script:VersionLabel.ForeColor = [System.Drawing.Color]::FromArgb(106, 106, 106)
    $Script:VersionLabel.AutoSize  = $true
    $hdr.Controls.Add($Script:VersionLabel, 0, 1)

    $Script:BtnUpdate = New-Object System.Windows.Forms.Button
    $Script:BtnUpdate.AutoSize  = $true
    $Script:BtnUpdate.Add_Click({ Start-UpdateCheck $false })
    $hdr.Controls.Add($Script:BtnUpdate, 1, 0)

    $Script:BtnCache = New-Object System.Windows.Forms.Button
    $Script:BtnCache.AutoSize  = $true
    $Script:BtnCache.Add_Click({ Clear-DownloadCache })
    $hdr.Controls.Add($Script:BtnCache, 2, 0)

    $Script:BtnInfo = New-Object System.Windows.Forms.Button
    $Script:BtnInfo.AutoSize  = $true
    $Script:BtnInfo.Add_Click({ Show-InfoWindow })
    $hdr.Controls.Add($Script:BtnInfo, 3, 0)

    $Script:BtnRefresh = New-Object System.Windows.Forms.Button
    $Script:BtnRefresh.AutoSize  = $true
    $Script:BtnRefresh.Add_Click({
        if (-not $Script:IsBusy) { Refresh-Statuses; Set-Status (T 'ready') 0 }
    })
    $hdr.Controls.Add($Script:BtnRefresh, 4, 0)

    $Script:LangLabel = New-Object System.Windows.Forms.Label
    $Script:LangLabel.AutoSize    = $true
    $Script:LangLabel.TextAlign   = 'MiddleRight'
    $hdr.Controls.Add($Script:LangLabel, 5, 0)

    $Script:LangCombo = New-Object System.Windows.Forms.ComboBox
    $Script:LangCombo.DropDownStyle = 'DropDownList'
    $Script:LangCombo.Width = 110
    foreach ($lng in $Languages) { [void]$Script:LangCombo.Items.Add($lng.Label) }
    $Script:LangCombo.SelectedItem = 'English'
    $Script:LangCombo.Add_SelectedIndexChanged({
        $code = ($Languages | Where-Object { $_.Label -eq $Script:LangCombo.SelectedItem }).Code
        if ($code) { $Script:Lang = $code }
        Refresh-Language
    })
    $hdr.Controls.Add($Script:LangCombo, 6, 0)
    $outer.Controls.Add($hdr, 0, 0)

    # ── Target folder ─────────────────────────────────────────────────────────
    $Script:GroupBoxTarget           = New-Object System.Windows.Forms.GroupBox
    $Script:GroupBoxTarget.Dock      = 'Fill'
    $Script:GroupBoxTarget.AutoSize  = $true
    $Script:GroupBoxTarget.Padding   = [System.Windows.Forms.Padding]::new(8)

    $tfl = New-Object System.Windows.Forms.TableLayoutPanel
    $tfl.Dock        = 'Fill'
    $tfl.ColumnCount = 3
    $tfl.RowCount    = 2
    $tfl.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('Percent', 100)) | Out-Null
    $tfl.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('AutoSize')) | Out-Null
    $tfl.ColumnStyles.Add([System.Windows.Forms.ColumnStyle]::new('AutoSize')) | Out-Null

    $Script:PathBox           = New-Object System.Windows.Forms.TextBox
    $Script:PathBox.Dock      = 'Fill'
    $Script:PathBox.Add_TextChanged({
        if (-not $Script:IsBusy) {
            $t = $Script:PathBox.Text.Trim()
            if ($t) {
                $Script:Settings['last_target_path'] = $t
                Write-AppJson $Script:SettingsPath $Script:Settings
            }
            Refresh-Statuses
        }
    })
    $tfl.Controls.Add($Script:PathBox, 0, 0)

    $Script:BtnChoose = New-Object System.Windows.Forms.Button
    $Script:BtnChoose.AutoSize = $true
    $Script:BtnChoose.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = T 'choose_title'
        if ($dlg.ShowDialog($Script:Form) -eq 'OK') {
            Set-TargetPath $dlg.SelectedPath
            Refresh-Statuses
        }
    })
    $tfl.Controls.Add($Script:BtnChoose, 1, 0)

    $Script:BtnSearch = New-Object System.Windows.Forms.Button
    $Script:BtnSearch.AutoSize = $true
    $Script:BtnSearch.Add_Click({ Start-Search $true })
    $tfl.Controls.Add($Script:BtnSearch, 2, 0)

    $Script:NoteLabel           = New-Object System.Windows.Forms.Label
    $Script:NoteLabel.ForeColor = $Script:ColorDark
    $Script:NoteLabel.AutoSize  = $true
    $tfl.Controls.Add($Script:NoteLabel, 0, 1)
    $tfl.SetColumnSpan($Script:NoteLabel, 3)

    $Script:GroupBoxTarget.Controls.Add($tfl)
    $outer.Controls.Add($Script:GroupBoxTarget, 0, 1)

    # ── Patch list ────────────────────────────────────────────────────────────
    $Script:GroupBoxPatches          = New-Object System.Windows.Forms.GroupBox
    $Script:GroupBoxPatches.Dock     = 'Fill'
    $Script:GroupBoxPatches.Padding  = [System.Windows.Forms.Padding]::new(8)

    $pfl = New-Object System.Windows.Forms.TableLayoutPanel
    $pfl.Dock        = 'Fill'
    $pfl.ColumnCount = 1
    $pfl.RowCount    = 2
    $pfl.RowStyles.Add([System.Windows.Forms.RowStyle]::new('AutoSize')) | Out-Null
    $pfl.RowStyles.Add([System.Windows.Forms.RowStyle]::new('Percent', 100)) | Out-Null

    $Script:HintLabel           = New-Object System.Windows.Forms.Label
    $Script:HintLabel.ForeColor = $Script:ColorDark
    $Script:HintLabel.AutoSize  = $true
    $pfl.Controls.Add($Script:HintLabel, 0, 0)

    $Script:ScrollPanel             = New-Object System.Windows.Forms.Panel
    $Script:ScrollPanel.Dock        = 'Fill'
    $Script:ScrollPanel.AutoScroll  = $true
    $Script:ScrollPanel.BorderStyle = 'None'

    $Script:InnerPanel             = New-Object System.Windows.Forms.FlowLayoutPanel
    $Script:InnerPanel.FlowDirection = 'TopDown'
    $Script:InnerPanel.AutoSize     = $true
    $Script:InnerPanel.AutoSizeMode = 'GrowAndShrink'
    $Script:InnerPanel.WrapContents = $false
    $Script:InnerPanel.Dock         = 'Top'
    $Script:InnerPanel.Padding      = [System.Windows.Forms.Padding]::new(8)

    $Script:ScrollPanel.Controls.Add($Script:InnerPanel)
    $pfl.Controls.Add($Script:ScrollPanel, 0, 1)
    $Script:GroupBoxPatches.Controls.Add($pfl)
    $outer.Controls.Add($Script:GroupBoxPatches, 0, 2)

    # ── Action buttons ────────────────────────────────────────────────────────
    $actPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $actPanel.FlowDirection = 'RightToLeft'
    $actPanel.Dock          = 'Fill'
    $actPanel.AutoSize      = $true
    $actPanel.Padding       = [System.Windows.Forms.Padding]::new(0, 8, 0, 4)

    $Script:BtnUninstall = New-Object System.Windows.Forms.Button
    $Script:BtnUninstall.AutoSize = $true
    $Script:BtnUninstall.Add_Click({ Start-Uninstall })
    $actPanel.Controls.Add($Script:BtnUninstall)

    $Script:BtnApply = New-Object System.Windows.Forms.Button
    $Script:BtnApply.AutoSize = $true
    $Script:BtnApply.Add_Click({ Start-Install })
    $actPanel.Controls.Add($Script:BtnApply)
    $outer.Controls.Add($actPanel, 0, 3)

    # ── Progress + status ─────────────────────────────────────────────────────
    $Script:ProgressBar       = New-Object System.Windows.Forms.ProgressBar
    $Script:ProgressBar.Dock  = 'Fill'
    $Script:ProgressBar.Value = 0
    $outer.Controls.Add($Script:ProgressBar, 0, 4)

    $Script:StatusLabel           = New-Object System.Windows.Forms.Label
    $Script:StatusLabel.Dock      = 'Fill'
    $Script:StatusLabel.AutoSize  = $true
    $Script:StatusLabel.Padding   = [System.Windows.Forms.Padding]::new(0, 4, 0, 0)
    $outer.Controls.Add($Script:StatusLabel, 0, 5)

    $Script:Form.Controls.Add($outer)

    # ── Mouse-wheel scroll on patch panel ─────────────────────────────────────
    $Script:Form.Add_MouseWheel({
        param($s, $e)
        $pt = $Script:ScrollPanel.PointToClient([System.Windows.Forms.Cursor]::Position)
        if ($Script:ScrollPanel.ClientRectangle.Contains($pt)) {
            $Script:ScrollPanel.AutoScrollPosition = New-Object System.Drawing.Point(
                0, [Math]::Max(0, -$Script:ScrollPanel.AutoScrollPosition.Y - $e.Delta / 3))
        }
    })
    $Script:ScrollPanel.Add_MouseWheel({
        param($s, $e)
        $Script:ScrollPanel.AutoScrollPosition = New-Object System.Drawing.Point(
            0, [Math]::Max(0, -$Script:ScrollPanel.AutoScrollPosition.Y - $e.Delta / 3))
    })

    # ── Resize labels when form resizes ───────────────────────────────────────
    $Script:Form.Add_Resize({ Resize-Labels })

    # ── Populate patch list ───────────────────────────────────────────────────
    foreach ($patch in $Script:AllPatches.Values) {
        $Script:PatchRequires[$patch.id] = $patch.requires
        $Script:PatchSelects[$patch.id]  = $patch.selects
        $Script:PatchDeps[$patch.id]     = @()
    }
    foreach ($patch in $Script:AllPatches.Values) {
        if ($patch.requires) {
            if (-not $Script:PatchDeps.ContainsKey($patch.requires)) {
                $Script:PatchDeps[$patch.requires] = @()
            }
            $Script:PatchDeps[$patch.requires] += $patch.id
        }
    }

    foreach ($group in $Script:Groups) {
        Add-GroupSection $Script:InnerPanel $group
    }
    foreach ($patch in $Script:Standalone) {
        Add-PatchRow $Script:InnerPanel $patch 0 | Out-Null
    }

    Refresh-Language
    Resize-Labels
    Set-Status (T 'ready') 0
}

# ── Entry point ───────────────────────────────────────────────────────────────
try {
    Load-Config
} catch {
    Write-AppLog 'startup' $_.Exception.Message
    [System.Windows.Forms.MessageBox]::Show(
        $null, $_.Exception.Message, 'Startup Error', 'OK', 'Error') | Out-Null
    exit 1
}

# Register all patches in lookup maps
foreach ($group in $Script:Groups) {
    foreach ($patch in $group.items) { $Script:AllPatches[$patch.id] = $patch }
}
foreach ($patch in $Script:Standalone) { $Script:AllPatches[$patch.id] = $patch }

Load-State
$Script:Settings = if (Test-Path $Script:SettingsPath) {
    $s = Read-AppJson $Script:SettingsPath
    if ($s) { @{ last_target_path = [string]$s.last_target_path } } else { @{} }
} else { @{} }

Build-UI

# Restore last path or kick off auto-search
$lastPath = $Script:Settings['last_target_path']
if ($lastPath -and (Test-Path $lastPath -PathType Container)) {
    $Script:PathBox.Text = $lastPath
    Refresh-Statuses
} else {
    $Script:Form.Add_Shown({ Start-Search $false })
}

# Startup update check (silent)
$Script:Form.Add_Shown({
    if ($Script:UpdateRepo) {
        $Script:Form.BeginInvoke([System.Action]{
            Start-UpdateCheck $true
        }) | Out-Null
    }
})

[System.Windows.Forms.Application]::Run($Script:Form)
