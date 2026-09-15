<#
.SYNOPSIS
    Chrome/Chromium Version Manager for Windows
.DESCRIPTION
    Downloads and manages isolated Chrome/Chromium installations by version.
    Data sources:
      - Chrome for Testing (CfT): v113+ official Chrome builds
      - Chromium googlesource tags: ALL Chrome versions from v10+
      - chromium-browser-snapshots (legacy): pre-v113 Chromium builds
#>

param(
    [Parameter(Position = 0)]
    [string]$Command,
    [Parameter(Position = 1)]
    [string]$Sub,
    [Parameter(Position = 2)]
    [string]$Value,
    [Parameter(Position = 3)]
    [string]$Value2,
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$ExtraArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

$ChromeBase   = Join-Path $ScriptDir 'chrome'
$ChromiumBase = Join-Path $ScriptDir 'chromium'
$CacheDir     = Join-Path $ScriptDir '.cache'
$CacheTTL     = 3600
$TagsTTL      = 86400

$CftBase          = 'https://googlechromelabs.github.io/chrome-for-testing'
$CftKnownGood     = "$CftBase/known-good-versions-with-downloads.json"
$CftLatest        = "$CftBase/last-known-good-versions-with-downloads.json"
$ChromiumLegacyBase = 'https://commondatastorage.googleapis.com/chromium-browser-snapshots'
$GooglesourceTags = 'https://chromium.googlesource.com/chromium/src/+refs/tags?format=JSON'

function Write-Info  { param([string]$Msg) Write-Host "[INFO] $Msg" -ForegroundColor Green }
function Write-Warn  { param([string]$Msg) Write-Host "[WARN] $Msg" -ForegroundColor Yellow }
function Write-Err   { param([string]$Msg) Write-Host "[ERROR] $Msg" -ForegroundColor Red }
function Write-Die   { param([string]$Msg) Write-Err $Msg; exit 1 }

function Show-Usage {
    @'

Usage: install-chrome.ps1 <command> [options]

Commands:
  list local [chrome|chromium]      List locally installed versions
  list chrome [N]                   List latest N Chrome for Testing versions (v113+, default: 30)
  list tags [N]                     List latest N Chrome tags from googlesource (v10+, default: 30)
  list chromium [N]                 List latest N Chromium revisions (default: 30)
  search chrome <ver> [N]           Search Chrome by version (e.g. "80", "80.0.3987")
  search chromium <rev> [N]         Search Chromium revisions matching pattern
  download chrome <version>         Download specific Chrome version (auto-selects source)
  download chromium <revision>      Download specific Chromium revision
  remove chrome <version>           Delete a downloaded Chrome version
  remove chromium <revision>        Delete a downloaded Chromium revision
  run chrome <version> [args...]    Run Chrome with isolated user-data dir
  run chromium <revision> [args..]  Run Chromium with isolated user-data dir
  latest chrome                     Download latest stable Chrome (via CfT)
  latest chromium                   Download latest stable Chromium
  help                              Show this help message

Examples:
  install-chrome.ps1 download chrome 80          # auto-resolve to latest in major 80
  install-chrome.ps1 download chrome v80.0.3987  # v prefix auto-stripped
  install-chrome.ps1 search chrome 80.0.3987     # semantic: major=80, build=3987
  install-chrome.ps1 run chrome 130.0.6723.69 -ExtraArgs '--headless'
'@ | Write-Host
    exit 0
}

function Test-Dependencies {
    # All operations use built-in cmdlets (Invoke-WebRequest, Expand-Archive).
    # Nothing external required.
}

# --- Cache helpers ---

function Get-CachedFile {
    param(
        [string]$Url,
        [string]$CacheName,
        [int]$Ttl = $CacheTTL
    )
    if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null }
    $cacheFile = Join-Path $CacheDir $CacheName
    if (Test-Path $cacheFile) {
        $age = (Get-Date) - (Get-Item $cacheFile).LastWriteTime
        if ($age.TotalSeconds -lt $Ttl) {
            return (Get-Content $cacheFile -Raw)
        }
    }
    Write-Info "Fetching $Url ..."
    try {
        Invoke-WebRequest -Uri $Url -OutFile $cacheFile -UseBasicParsing -ErrorAction Stop
    } catch {
        Write-Die "Failed to fetch $Url"
    }
    return (Get-Content $cacheFile -Raw)
}

function Get-FetchTags {
    $cacheFile = Join-Path $CacheDir 'chrome-tags.json'
    if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null }
    if (Test-Path $cacheFile) {
        $age = (Get-Date) - (Get-Item $cacheFile).LastWriteTime
        if ($age.TotalSeconds -lt $TagsTTL) { return }
    }
    Write-Info "Fetching all Chrome version tags from googlesource (this may take ~30s) ..."
    $tmpFile = "$cacheFile.tmp"
    try {
        Invoke-WebRequest -Uri $GooglesourceTags -OutFile $tmpFile -UseBasicParsing -ErrorAction Stop
    } catch {
        Write-Die "Failed to fetch tags"
    }
    $content = Get-Content $tmpFile -Raw
    # Strip leading ")]}'\n" JSON hijacking prefix
    $content = $content.Substring(5)
    Set-Content -Path $cacheFile -Value $content -NoNewline
    Remove-Item $tmpFile -Force
    $obj = $content | ConvertFrom-Json
    $count = ($obj.PSObject.Properties | Measure-Object).Count
    Write-Info "Cached $count version tags"
}

function Get-StripV {
    param([string]$Ver)
    if ($Ver -match '^[vV]') { $Ver = $Ver.Substring(1) }
    return $Ver
}

function Get-VersionKey {
    param([string]$Ver)
    $parts = $Ver -split '\.'
    $key = ($parts | ForEach-Object { $n = 0; [int]::TryParse($_, [ref]$n) | Out-Null; $n.ToString('D5') }) -join '.'
    return $key
}

function Test-VersionMatch {
    param(
        [string]$Tag,
        [string[]]$Parts
    )
    $tparts = $Tag -split '\.'
    if ($Parts.Count -gt $tparts.Count) { return $false }
    for ($i = 0; $i -lt $Parts.Count; $i++) {
        if (-not [string]::IsNullOrEmpty($Parts[$i]) -and $tparts[$i] -ne $Parts[$i]) {
            return $false
        }
    }
    return $true
}

# --- Version resolution ---

function Resolve-Version {
    param([string]$Ver)
    $Ver = Get-StripV $Ver
    $dots = ($Ver -split '\.').Count - 1
    if ($dots -ge 3) { return $Ver }

    Get-FetchTags
    $cacheFile = Join-Path $CacheDir 'chrome-tags.json'
    $tags = @(((Get-Content -Path $cacheFile -Raw) | ConvertFrom-Json).PSObject.Properties.Name)

    $parts = ($Ver -split '\.')
    $matched = $tags | Where-Object { Test-VersionMatch -Tag $_ -Parts $parts } |
        Sort-Object { Get-VersionKey $_ } | Select-Object -Last 1

    return $matched
}

# --- Local listing ---

function Show-Local {
    param([string]$Type = 'chrome')

    $bases = @{
        'chrome'   = $ChromeBase
        'chromium' = $ChromiumBase
    }

    if ($Type -eq 'all') {
        $found = $false
        foreach ($t in @('chrome', 'chromium')) {
            Show-Local -Type $t
        }
        return
    }

    if (-not $bases.ContainsKey($Type)) { Write-Die "Usage: list local chrome|chromium|all" }
    $base = $bases[$Type]

    if (-not (Test-Path $base) -or -not (Get-ChildItem $base -Directory -ErrorAction SilentlyContinue)) {
        Write-Warn "No local $Type versions installed"
        return
    }

    Write-Host "`nLocal $Type installations:" -ForegroundColor Cyan
    Write-Host ('-' * 45) -ForegroundColor Cyan
    $i = 1
    foreach ($dir in Get-ChildItem $base -Directory) {
        $files = @(Get-ChildItem $dir.FullName -Recurse -File -ErrorAction SilentlyContinue)
        $size = '0.0 MB'
        if ($files.Count -gt 0) {
            $sum = ($files | Measure-Object -Property Length -Sum).Sum
            if ($sum) { $size = '{0:N1} MB' -f ($sum / 1MB) }
        }
        Write-Host ("  {0}. {1}  ({2})" -f $i, $dir.Name, $size)
        $i++
    }
}

# --- Listing ---

function Show-ChromeVersions {
    param([int]$Count = 30)
    Write-Info "Fetching Chrome for Testing versions ..."
    $data = Get-CachedFile -Url $CftKnownGood -CacheName 'cft-versions.json' | ConvertFrom-Json
    $versions = @($data.versions | ForEach-Object { $_.version })
    $total = $versions.Count
    $selected = @($versions | Sort-Object { Get-VersionKey $_ } | Select-Object -Last $Count)
    $selected = @($selected[($selected.Count - 1)..0])
    Write-Host "`nChrome for Testing versions (latest $Count of $total):" -ForegroundColor Cyan
    Write-Host ('-' * 55) -ForegroundColor Cyan
    $i = 1
    foreach ($v in $selected) {
        Write-Host ("  {0}. {1}" -f $i, $v)
        $i++
    }
}

function Show-Tags {
    param([int]$Count = 30)
    Get-FetchTags
    $cacheFile = Join-Path $CacheDir 'chrome-tags.json'
    $allTags = @(((Get-Content -Path $cacheFile -Raw) | ConvertFrom-Json).PSObject.Properties.Name)
    $total = $allTags.Count
    $tags = @($allTags | Sort-Object { Get-VersionKey $_ } | Select-Object -Last $Count)
    $tags = @($tags[($tags.Count - 1)..0])
    Write-Host "`nAll Chrome version tags (latest $Count of $total total):" -ForegroundColor Cyan
    Write-Host ('-' * 55) -ForegroundColor Cyan
    $i = 1
    foreach ($t in $tags) {
        Write-Host ("  {0}. {1}" -f $i, $t)
        $i++
    }
}

function Show-ChromiumRevisions {
    param([int]$Count = 30)
    Write-Info "Fetching Chromium revisions (via Chrome for Testing data) ..."
    $data = Get-CachedFile -Url $CftKnownGood -CacheName 'cft-versions.json' | ConvertFrom-Json
    $items = @($data.versions | ForEach-Object { [PSCustomObject]@{ Version = $_.version; Revision = $_.revision } })
    $selected = @($items | Sort-Object { Get-VersionKey $_.Version } | Select-Object -Last $Count)
    Write-Host "`nChromium revisions (latest $Count):" -ForegroundColor Cyan
    Write-Host ('-' * 45) -ForegroundColor Cyan
    $i = 1
    foreach ($item in $selected[($selected.Count - 1)..0]) {
        Write-Host ("  {0}. v{1}  ->  revision {2}" -f $i, $item.Version, $item.Revision)
        $i++
    }
}

# --- Search ---

function Search-Chrome {
    param(
        [string]$Query,
        [int]$Count = 10
    )
    $Query = Get-StripV $Query
    if ([string]::IsNullOrEmpty($Query)) { Write-Die "Usage: search chrome <version> [N]" }
    Get-FetchTags
    $cacheFile = Join-Path $CacheDir 'chrome-tags.json'
    $allTags = @(((Get-Content -Path $cacheFile -Raw) | ConvertFrom-Json).PSObject.Properties.Name)

    $parts = $Query -split '\.'
    $matched = $allTags | Where-Object { Test-VersionMatch -Tag $_ -Parts $parts }
    $matchedAll = @($matched)
    $matched = @($matchedAll | Sort-Object { Get-VersionKey $_ } | Select-Object -Last $Count)
    $total = $matchedAll.Count

    Write-Host "`nChrome tags matching '$Query' (latest $Count of $total):" -ForegroundColor Cyan
    Write-Host ('-' * 55) -ForegroundColor Cyan
    $i = 1
    foreach ($v in $matched[($matched.Count - 1)..0]) {
        Write-Host ("  {0}. {1}" -f $i, $v)
        $i++
    }
}

function Search-Chromium {
    param(
        [string]$Query,
        [int]$Count = 10
    )
    $Query = Get-StripV $Query
    if ([string]::IsNullOrEmpty($Query)) { Write-Die "Usage: search chromium <version> [N]" }
    Get-FetchTags
    $cacheFile = Join-Path $CacheDir 'chrome-tags.json'
    $allTags = @(((Get-Content -Path $cacheFile -Raw) | ConvertFrom-Json).PSObject.Properties.Name)

    $parts = ($Query -split '\.')
    $matchedAll = @($allTags | Where-Object { Test-VersionMatch -Tag $_ -Parts $parts })
    $matched = @($matchedAll | Sort-Object { Get-VersionKey $_ } | Select-Object -Last $Count)

    # Load CfT data for revision mapping
    $revMap = @{}
    try {
        $cftData = Get-CachedFile -Url $CftKnownGood -CacheName 'cft-versions.json' | ConvertFrom-Json
        foreach ($v in $cftData.versions) {
            $revMap[$v.version] = $v.revision
        }
    } catch {}

    $total = $matchedAll.Count

    Write-Host "`nChromium revisions matching '$Query' (latest $Count of $total):" -ForegroundColor Cyan
    Write-Host ('-' * 60) -ForegroundColor Cyan
    $i = 1
    foreach ($v in $matched[($matched.Count - 1)..0]) {
        if ($revMap.ContainsKey($v)) {
            Write-Host ("  {0}. v{1}  ->  revision {2}" -f $i, $v, $revMap[$v])
        } else {
            Write-Host ("  {0}. v{1}  ->  revision ?" -f $i, $v)
        }
        $i++
    }
}

# --- Commit position resolution ---

function Get-CommitPosition {
    param([string]$Version)
    Write-Info "Resolving commit position for Chrome $Version ..."

    $tagUrl = "https://chromium.googlesource.com/chromium/src/+/refs/tags/$Version`?format=JSON"
    try {
        $tagDataRaw = (Invoke-WebRequest -Uri $tagUrl -UseBasicParsing -ErrorAction Stop).Content
    } catch {
        Write-Die "Version '$Version' not found in googlesource tags"
    }
    # Strip leading ")]}'\n" JSON hijacking prefix
    $tagDataRaw = $tagDataRaw -replace '^\)\]\}\''\r?\n', ''
    $tagData = $tagDataRaw | ConvertFrom-Json

    $parent = @($tagData.parents)[0]
    if (-not $parent) { Write-Die "No parent commit found for tag $Version" }

    $parentUrl = "https://chromium.googlesource.com/chromium/src/+/$parent`?format=JSON"
    try {
        $parentDataRaw = (Invoke-WebRequest -Uri $parentUrl -UseBasicParsing -ErrorAction Stop).Content
    } catch {
        Write-Die "Failed to fetch parent commit $parent"
    }
    $parentDataRaw = $parentDataRaw -replace '^\)\]\}\''\r?\n', ''
    $parentData = $parentDataRaw | ConvertFrom-Json

    $message = $parentData.message
    if (-not $message) { Write-Die "Could not determine commit position for Chrome $Version" }

    # Extract Cr-Branched-From position
    if ($message -match 'refs/heads/(main|master)@\{#(\d+)\}') {
        $position = $Matches[2]
    } elseif ($message -match 'Cr-Commit-Position:.*?@\{#(\d+)\}') {
        $position = $Matches[1]
    } else {
        Write-Die "Could not determine commit position for Chrome $Version"
    }

    Write-Info "Commit position: $position"
    return $position
}

function Find-NearestBuild {
    param(
        [string]$Base,
        [int]$MaxSearch = 200
    )

    function Test-BuildExists([string]$Url) {
        try {
            $response = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -ErrorAction Stop
            return $true
        } catch {
            return $false
        }
    }

    if (Test-BuildExists "$ChromiumLegacyBase/Win_x64/$Base/chrome-win.zip") { return $Base }

    Write-Info "Searching for nearest build around position $Base ..."
    for ($offset = 1; $offset -le $MaxSearch; $offset++) {
        if ($offset % 10 -eq 0) { Write-Host "`r  searched +-$offset" -NoNewline }

        $pos1 = [int]$Base - $offset
        if (Test-BuildExists "$ChromiumLegacyBase/Win_x64/$pos1/chrome-win.zip") {
            Write-Host ''
            return $pos1
        }
        $pos2 = [int]$Base + $offset
        if (Test-BuildExists "$ChromiumLegacyBase/Win_x64/$pos2/chrome-win.zip") {
            Write-Host ''
            return $pos2
        }
    }
    Write-Host ''
    return $null
}

# --- Download / install ---

function Install-Chrome {
    param([string]$Version)

    $Version = Resolve-Version $Version
    if ([string]::IsNullOrEmpty($Version)) { Write-Die "Version '$Version' not found" }
    $dest = Join-Path $ChromeBase $Version
    Write-Info "Target version: $Version"
    if (Test-Path (Join-Path $dest 'chrome')) {
        Write-Warn "Chrome $Version already exists at $dest"
        return
    }

    # Try CfT first
    Write-Info "Trying Chrome for Testing ..."
    $cftUrl = $null
    try {
        $cftData = Get-CachedFile -Url $CftKnownGood -CacheName 'cft-versions.json' | ConvertFrom-Json
        foreach ($v in $cftData.versions) {
            if ($v.version -eq $Version) {
                foreach ($dl in $v.downloads.chrome) {
                    if ($dl.platform -eq 'win64') {
                        $cftUrl = $dl.url
                        break
                    }
                }
                break
            }
        }
    } catch {}

    if ($cftUrl) {
        if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
        Write-Info "Download URL: $cftUrl"
        $zipPath = Join-Path $dest 'chrome.zip'
        try {
            Invoke-WebRequest -Uri $cftUrl -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
        } catch {
            Write-Die "Download failed"
        }
        Write-Info "Extracting ..."
        Expand-Archive -Path $zipPath -DestinationPath $dest -Force
        Remove-Item $zipPath -Force
        $extracted = Get-ChildItem $dest -Directory | Where-Object { $_.Name -like 'chrome-*' } | Select-Object -First 1
        if ($extracted) { Rename-Item $extracted.FullName (Join-Path $dest 'chrome') -Force }
    } else {
        Write-Info "Not in CfT, trying chromium-browser-snapshots ..."
        $position = Get-CommitPosition $Version
        Write-Info "Base commit position: $position"
        $nearest = Find-NearestBuild $position
        if (-not $nearest) { Write-Die "No build found near position $position in snapshots bucket" }
        Write-Info "Found build at nearest position: $nearest"
        $zipUrl = "$ChromiumLegacyBase/Win_x64/$nearest/chrome-win.zip"
        if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
        Write-Info "Download URL: $zipUrl"
        $zipPath = Join-Path $dest 'chrome.zip'
        try {
            Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
        } catch {
            Write-Die "Download failed"
        }
        Write-Info "Extracting ..."
        Expand-Archive -Path $zipPath -DestinationPath $dest -Force
        Remove-Item $zipPath -Force
        $extracted = Get-ChildItem $dest -Directory | Where-Object { $_.Name -like 'chrome-*' } | Select-Object -First 1
        if ($extracted) { Rename-Item $extracted.FullName (Join-Path $dest 'chrome') -Force }
        Set-Content -Path (Join-Path $dest '.position') -Value $nearest -NoNewline
    }

    New-Item -ItemType Directory -Path (Join-Path $dest 'user-data') -Force | Out-Null

    $chromeExe = Join-Path $dest 'chrome\chrome.exe'
    $files = @(Get-ChildItem (Join-Path $dest 'chrome') -Recurse -File -ErrorAction SilentlyContinue)
    $size = '0.0 MB'
    if ($files.Count -gt 0) {
        $sum = ($files | Measure-Object -Property Length -Sum).Sum
        if ($sum) { $size = '{0:N1} MB' -f ($sum / 1MB) }
    }
    Write-Info "Chrome $Version installed at $dest\chrome ($size)"
}

function Install-Chromium {
    param([string]$Input_)

    if ([string]::IsNullOrEmpty($Input_)) { Write-Die "Revision required" }

    $revision = $Input_

    # If input looks like a version, try to resolve to revision
    if ($Input_ -match '\.' -or $Input_.Length -le 5) {
        $resolved = $null
        try { $resolved = Resolve-Version $Input_ } catch {}
        if ($resolved) {
            $pos = $null
            try { $pos = Get-CommitPosition $resolved } catch {}
            if ($pos) {
                $nearest = $null
                try { $nearest = Find-NearestBuild $pos } catch {}
                if ($nearest) { $revision = $nearest }
            }
        }
    }

    $dest = Join-Path $ChromiumBase $revision
    if (Test-Path (Join-Path $dest 'chrome')) {
        Write-Output $revision
        return
    }

    $url = "$ChromiumLegacyBase/Win_x64/$revision/chrome-win.zip"

    Write-Info "Checking Chromium revision $revision ..."
    try {
        $response = Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -ErrorAction Stop
    } catch {
        Write-Die "Chromium revision $revision not found"
    }

    if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
    Write-Info "Download URL: $url"
    $zipPath = Join-Path $dest 'chromium.zip'
    try {
        Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
    } catch {
        Write-Die "Download failed"
    }

    Write-Info "Extracting ..."
    Expand-Archive -Path $zipPath -DestinationPath $dest -Force
    Remove-Item $zipPath -Force

    $extracted = Get-ChildItem $dest -Directory | Where-Object { $_.Name -like 'chrome-*' } | Select-Object -First 1
    if ($extracted) { Rename-Item $extracted.FullName (Join-Path $dest 'chrome') -Force }

    New-Item -ItemType Directory -Path (Join-Path $dest 'user-data') -Force | Out-Null

    $files = @(Get-ChildItem (Join-Path $dest 'chrome') -Recurse -File -ErrorAction SilentlyContinue)
    $size = '0.0 MB'
    if ($files.Count -gt 0) {
        $sum = ($files | Measure-Object -Property Length -Sum).Sum
        if ($sum) { $size = '{0:N1} MB' -f ($sum / 1MB) }
    }
    Write-Info "Chromium revision $revision installed at $dest\chrome ($size)"
    Write-Output $revision
}

# --- Run ---

function Invoke-Chrome {
    param(
        [string]$Input_,
        [string[]]$Args_
    )
    $version = Resolve-Version $Input_
    $dest = Join-Path $ChromeBase $version
    $bin = Join-Path $dest 'chrome\chrome.exe'

    if (-not (Test-Path $bin)) {
        Write-Warn "Chrome $version not downloaded."
        $reply = Read-Host "Download now? [Y/n]"
        if ($reply -match '^[nN]') { Write-Die "Aborted." }
        Install-Chrome $Input_
        $version = Resolve-Version $Input_
        $dest = Join-Path $ChromeBase $version
        $bin = Join-Path $dest 'chrome\chrome.exe'
    }

    $major = [int]($version -split '\.')[0]
    $extraArgs = @()
    if ($major -lt 113) { $extraArgs += '--disable-gpu' }

    Write-Info "Starting Chrome $version ..."
    $userDataDir = Join-Path $dest 'user-data'
    & $bin "--user-data-dir=$userDataDir" @extraArgs @Args_
}

function Invoke-Chromium {
    param(
        [string]$Input_,
        [string[]]$Args_
    )
    $revision = $Input_
    $resolved = $null
    try { $resolved = Resolve-Version $Input_ } catch {}
    if ($resolved) {
        $pos = $null
        try { $pos = Get-CommitPosition $resolved } catch {}
        if ($pos) {
            $nearest = $null
            try { $nearest = Find-NearestBuild $pos } catch {}
            if ($nearest) { $revision = $nearest }
        }
    }

    $dest = Join-Path $ChromiumBase $revision
    $bin = Join-Path $dest 'chrome\chrome.exe'

    if (-not (Test-Path $bin)) {
        Write-Warn "Chromium revision $revision not downloaded."
        $reply = Read-Host "Download now? [Y/n]"
        if ($reply -match '^[nN]') { Write-Die "Aborted." }
        Install-Chromium $Input_
        # Re-resolve
        $revision = $Input_
        $resolved = $null
        try { $resolved = Resolve-Version $Input_ } catch {}
        if ($resolved) {
            $pos = $null
            try { $pos = Get-CommitPosition $resolved } catch {}
            if ($pos) {
                $nearest = $null
                try { $nearest = Find-NearestBuild $pos } catch {}
                if ($nearest) { $revision = $nearest }
            }
        }
        $dest = Join-Path $ChromiumBase $revision
        $bin = Join-Path $dest 'chrome\chrome.exe'
    }

    Write-Info "Starting Chromium revision $revision ..."
    $userDataDir = Join-Path $dest 'user-data'
    & $bin "--user-data-dir=$userDataDir" @Args_
}

# --- Latest ---

function Get-LatestChrome {
    Write-Info "Fetching latest stable Chrome ..."
    $data = Get-CachedFile -Url $CftLatest -CacheName 'cft-latest.json' | ConvertFrom-Json
    $version = $data.channels.Stable.version
    if ([string]::IsNullOrEmpty($version)) { Write-Die "Could not determine latest Chrome version" }
    Write-Info "Latest stable: $version"
    Install-Chrome $version
}

function Get-LatestChromium {
    Write-Info "Fetching latest Chromium revision ..."
    $data = Get-CachedFile -Url $CftLatest -CacheName 'cft-latest.json' | ConvertFrom-Json
    $revision = $data.channels.Stable.revision
    if ([string]::IsNullOrEmpty($revision)) { Write-Die "Could not determine latest Chromium revision" }
    Write-Info "Latest stable Chromium revision: $revision"
    Install-Chromium $revision
}

# --- Remove ---

function Remove-Chrome {
    param([string]$Ver)
    try { $Ver = Resolve-Version $Ver } catch {}
    $dir = Join-Path $ChromeBase $Ver
    if (-not (Test-Path $dir)) { Write-Die "Chrome $Ver not found at $dir" }
    Remove-Item $dir -Recurse -Force
    Write-Info "Removed Chrome $Ver"
}

function Remove-Chromium {
    param([string]$Rev)
    $dir = Join-Path $ChromiumBase $Rev
    if (-not (Test-Path $dir)) { Write-Die "Chromium $Rev not found at $dir" }
    Remove-Item $dir -Recurse -Force
    Write-Info "Removed Chromium $Rev"
}

# --- Clean ---

function Clear-Cache {
    if (Test-Path $CacheDir) { Remove-Item $CacheDir -Recurse -Force }
    Write-Info "Cache cleared"
}

function Clear-All {
    if (Test-Path $CacheDir)  { Remove-Item $CacheDir -Recurse -Force }
    if (Test-Path $ChromeBase)   { Remove-Item $ChromeBase -Recurse -Force }
    if (Test-Path $ChromiumBase) { Remove-Item $ChromiumBase -Recurse -Force }
    Write-Info "All data and cache cleared"
}

# --- Main ---

Test-Dependencies

if ([string]::IsNullOrEmpty($Command)) { Show-Usage }

switch ($Command.ToLower()) {
    'list' {
        $subVal = if ($Sub) { $Sub.ToLower() } else { 'chrome' }
        switch ($subVal) {
            'local' {
                $ltype = if ($Value) { $Value.ToLower() } else { 'chrome' }
                Show-Local -Type $ltype
            }
            'chrome' {
                $count = if ($Value) { [int]$Value } else { 30 }
                Show-ChromeVersions -Count $count
            }
            'tags' {
                $count = if ($Value) { [int]$Value } else { 30 }
                Show-Tags -Count $count
            }
            'chromium' {
                $count = if ($Value) { [int]$Value } else { 30 }
                Show-ChromiumRevisions -Count $count
            }
            default { Write-Die "Usage: list local|chrome|tags|chromium [N]" }
        }
    }
    'search' {
        $count = if ($Value2) { [int]$Value2 } else { 10 }
        if (-not $Sub -or -not $Value) { Write-Die "Usage: search chrome|chromium <query> [N]" }
        switch ($Sub.ToLower()) {
            'chrome'   { Search-Chrome -Query $Value -Count $count }
            'chromium' { Search-Chromium -Query $Value -Count $count }
            default    { Write-Die "Usage: search chrome|chromium <query> [N]" }
        }
    }
    'download' {
        if (-not $Sub -or -not $Value) { Write-Die "Usage: download chrome|chromium <version|revision>" }
        switch ($Sub.ToLower()) {
            'chrome'   { Install-Chrome $Value }
            'chromium' { Install-Chromium $Value }
            default    { Write-Die "Usage: download chrome|chromium <version|revision>" }
        }
    }
    'remove' {
        if (-not $Sub -or -not $Value) { Write-Die "Usage: remove chrome|chromium <version|revision>" }
        switch ($Sub.ToLower()) {
            'chrome'   { Remove-Chrome $Value }
            'chromium' { Remove-Chromium $Value }
            default    { Write-Die "Usage: remove chrome|chromium <version|revision>" }
        }
    }
    'run' {
        if (-not $Sub -or -not $Value) { Write-Die "Usage: run chrome|chromium <version|revision> [args...]" }
        $remaining = if ($ExtraArgs) { $ExtraArgs } else { @() }
        switch ($Sub.ToLower()) {
            'chrome'   { Invoke-Chrome -Input_ $Value -Args_ $remaining }
            'chromium' { Invoke-Chromium -Input_ $Value -Args_ $remaining }
            default    { Write-Die "Usage: run chrome|chromium <version|revision> [args...]" }
        }
    }
    'latest' {
        $subVal = if ($Sub) { $Sub.ToLower() } else { 'chrome' }
        switch ($subVal) {
            'chrome'   { Get-LatestChrome }
            'chromium' { Get-LatestChromium }
            default    { Write-Die "Usage: latest chrome|chromium" }
        }
    }
    'clean' {
        $subVal = if ($Sub) { $Sub.ToLower() } else { 'cache' }
        switch ($subVal) {
            'cache' { Clear-Cache }
            'all'   { Clear-All }
            default { Write-Die "Usage: clean cache|all" }
        }
    }
    default { Show-Usage }
}
