[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ModId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:HubBaseUrl = 'https://hub.coigame.com'
$script:DefaultUserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) CoI-Mod-Updater/1.0'
$script:AppRoot = Join-Path $env:APPDATA 'Captain of Industry'
$script:ModsRoot = Join-Path $script:AppRoot 'Mods'
$script:DownloadsRoot = Join-Path $script:AppRoot 'Mods_dl'
$script:BackupRoot = Join-Path $script:AppRoot 'Bkup'
$script:StagingRoot = Join-Path $script:DownloadsRoot '_staging'
$script:CachePath = Join-Path $script:DownloadsRoot 'mod-url-cache.json'
$script:LogPath = Join-Path $script:DownloadsRoot ("update-log-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$script:Session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
$script:Summary = [System.Collections.Generic.List[object]]::new()

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = '[{0}] [{1}] {2}' -f $timestamp, $Level, $Message
    Write-Host $line
    Add-Content -LiteralPath $script:LogPath -Value $line
}

function Ensure-Directory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        if ($PSCmdlet.ShouldProcess($Path, 'Create directory')) {
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
        }
    }
}

function ConvertTo-HashtableRecursive {
    param(
        [Parameter(Mandatory = $true)]
        $InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $table = @{}
        foreach ($key in $InputObject.Keys) {
            $table[$key] = ConvertTo-HashtableRecursive -InputObject $InputObject[$key]
        }

        return $table
    }

    if (($InputObject -is [System.Collections.IEnumerable]) -and -not ($InputObject -is [string])) {
        $items = @()
        foreach ($item in $InputObject) {
            $items += ,(ConvertTo-HashtableRecursive -InputObject $item)
        }

        return $items
    }

    if ($InputObject -is [pscustomobject]) {
        $table = @{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $table[$property.Name] = ConvertTo-HashtableRecursive -InputObject $property.Value
        }

        return $table
    }

    return $InputObject
}

function Get-Cache {
    if (-not (Test-Path -LiteralPath $script:CachePath)) {
        return @{}
    }

    try {
        $raw = Get-Content -LiteralPath $script:CachePath -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return @{}
        }

        $parsed = $raw | ConvertFrom-Json
        if ($null -eq $parsed) {
            return @{}
        }

        return (ConvertTo-HashtableRecursive -InputObject $parsed)
    }
    catch {
        Write-Log -Level 'WARN' -Message ("Cache file could not be read, starting fresh: {0}" -f $_.Exception.Message)
        return @{}
    }
}

function Save-Cache {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Cache
    )

    $json = $Cache | ConvertTo-Json -Depth 10
    Set-Content -LiteralPath $script:CachePath -Value $json -Encoding UTF8
}

function Invoke-HubRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    return Invoke-WebRequest -Uri $Url -WebSession $script:Session -Headers @{ 'User-Agent' = $script:DefaultUserAgent } -UseBasicParsing
}

function Resolve-AbsoluteUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Href,

        [string]$BaseUrl = $script:HubBaseUrl
    )

    if ([string]::IsNullOrWhiteSpace($Href)) {
        return $null
    }

    if ($Href -match '^https?://') {
        return $Href
    }

    return ([System.Uri]::new([System.Uri]$BaseUrl, $Href)).AbsoluteUri
}

function Get-NormalizedModName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return (($Value.ToLowerInvariant()) -replace '[^a-z0-9]', '')
}

function Try-GetObjectPropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        $InputObject,

        [Parameter(Mandatory = $true)]
        [string]$PropertyName
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$PropertyName]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Get-VersionTokens {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Version
    )

    return [regex]::Matches($Version.ToLowerInvariant(), '\d+|[a-z]+') | ForEach-Object { $_.Value }
}

function Compare-VersionStrings {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Left,

        [Parameter(Mandatory = $true)]
        [string]$Right
    )

    if ($Left -eq $Right) {
        return 0
    }

    try {
        $leftVersion = [version]($Left -replace '[^0-9\.]', '')
        $rightVersion = [version]($Right -replace '[^0-9\.]', '')
        if ($leftVersion -lt $rightVersion) { return -1 }
        if ($leftVersion -gt $rightVersion) { return 1 }
    }
    catch {
    }

    $leftTokens = @(Get-VersionTokens -Version $Left)
    $rightTokens = @(Get-VersionTokens -Version $Right)
    $maxCount = [Math]::Max($leftTokens.Count, $rightTokens.Count)

    for ($i = 0; $i -lt $maxCount; $i++) {
        $leftToken = if ($i -lt $leftTokens.Count) { $leftTokens[$i] } else { $null }
        $rightToken = if ($i -lt $rightTokens.Count) { $rightTokens[$i] } else { $null }

        if ($leftToken -eq $rightToken) {
            continue
        }

        if ($null -eq $leftToken) {
            return -1
        }

        if ($null -eq $rightToken) {
            return 1
        }

        $leftIsNumber = $leftToken -match '^\d+$'
        $rightIsNumber = $rightToken -match '^\d+$'

        if ($leftIsNumber -and $rightIsNumber) {
            $leftNumber = [int64]$leftToken
            $rightNumber = [int64]$rightToken
            if ($leftNumber -lt $rightNumber) { return -1 }
            if ($leftNumber -gt $rightNumber) { return 1 }
            continue
        }

        if ($leftIsNumber -and -not $rightIsNumber) {
            return 1
        }

        if (-not $leftIsNumber -and $rightIsNumber) {
            return -1
        }

        $stringCompare = [string]::CompareOrdinal($leftToken, $rightToken)
        if ($stringCompare -lt 0) { return -1 }
        if ($stringCompare -gt 0) { return 1 }
    }

    return [string]::CompareOrdinal($Left, $Right)
}

function Get-InstalledMods {
    param(
        [string]$FilterModId
    )

    $mods = [System.Collections.Generic.List[object]]::new()
    $seenModIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $directories = Get-ChildItem -LiteralPath $script:ModsRoot -Directory -ErrorAction SilentlyContinue

    foreach ($directory in $directories) {
        $manifestPath = Join-Path $directory.FullName 'manifest.json'
        if (-not (Test-Path -LiteralPath $manifestPath)) {
            $nestedManifestCandidates = @(Get-ChildItem -LiteralPath $directory.FullName -Filter 'manifest.json' -File -Recurse -ErrorAction SilentlyContinue)
            if ($nestedManifestCandidates.Count -eq 1) {
                $manifestPath = $nestedManifestCandidates[0].FullName
                Write-Log -Message ("Using nested manifest for '{0}': {1}" -f $directory.Name, $manifestPath)
            }
            elseif ($nestedManifestCandidates.Count -gt 1) {
                Write-Log -Level 'WARN' -Message ("Skipping '{0}' because multiple manifest.json files were found under the folder." -f $directory.Name)
                continue
            }
            else {
                Write-Log -Level 'WARN' -Message ("Skipping '{0}' because manifest.json is missing." -f $directory.Name)
                continue
            }
        }

        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        }
        catch {
            Write-Log -Level 'WARN' -Message ("Skipping '{0}' because manifest.json could not be parsed: {1}" -f $directory.Name, $_.Exception.Message)
            continue
        }

        if ([string]::IsNullOrWhiteSpace($manifest.id) -or [string]::IsNullOrWhiteSpace($manifest.version)) {
            Write-Log -Level 'WARN' -Message ("Skipping '{0}' because manifest.json is missing id or version." -f $directory.Name)
            continue
        }

        if ($FilterModId -and $manifest.id -ne $FilterModId) {
            continue
        }

        if (-not $seenModIds.Add([string]$manifest.id)) {
            Write-Log -Level 'WARN' -Message ("Skipping duplicate installed mod id '{0}' found under '{1}'." -f $manifest.id, $directory.Name)
            continue
        }

        $mods.Add([pscustomobject]@{
                Id           = [string]$manifest.id
                Version      = [string]$manifest.version
                Directory    = $directory.FullName
                DirectoryName = $directory.Name
                ManifestPath = $manifestPath
            })
    }

    return $mods
}

function Get-LatestVersionFromHtml {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Html
    )

    $patterns = @(
        '(?is)v(?<version>[0-9A-Za-z\.\-_]+)\s*<span[^>]*>\s*Latest\s*</span>',
        '(?is)<h4[^>]*>\s*v?(?<version>[0-9A-Za-z\.\-_]+)\s*</h4>\s*<span[^>]*>\s*Latest\s*</span>',
        '(?is)class="mv2-version-label"[^>]*>\s*v?(?<version>[0-9A-Za-z\.\-_]+)\s*(?:<span[^>]*>\s*Latest\s*</span>)?',
        '(?is)<h1[^>]*>.*?v(?<version>[0-9A-Za-z\.\-_]+)\s*</',
        '(?im)^\s*#\s+.+?\sv(?<version>[0-9A-Za-z\.\-_]+)\s*$',
        '(?im)^\s*####\s+v(?<version>[0-9A-Za-z\.\-_]+)\s*$',
        '(?im)\bv(?<version>[0-9A-Za-z\.\-_]+)\s+Latest\b',
        '(?im)^(?<version>[0-9A-Za-z\.\-_]+)\s*\((?:CURRENT|Current)\)\s*$'
    )

    foreach ($pattern in $patterns) {
        $match = [regex]::Match($Html, $pattern)
        if ($match.Success) {
            return $match.Groups['version'].Value
        }
    }

    return $null
}

function Test-IsValidModPage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ModId,

        [Parameter(Mandatory = $true)]
        $Response
    )

    $responseUri = Try-GetObjectPropertyValue -InputObject $Response.BaseResponse -PropertyName 'ResponseUri'
    if ($null -eq $responseUri -or $responseUri.AbsoluteUri -notmatch '/Mod/\d+/') {
        return $false
    }

    $downloadUrl = Get-DownloadUrlFromResponse -Response $Response
    if ([string]::IsNullOrWhiteSpace($downloadUrl)) {
        return $false
    }

    $content = [string]$Response.Content
    if ([string]::IsNullOrWhiteSpace($content)) {
        return $false
    }

    $hasVersion = -not [string]::IsNullOrWhiteSpace((Get-LatestVersionFromHtml -Html $content))
    return $hasVersion
}

function Get-DownloadUrlFromResponse {
    param(
        [Parameter(Mandatory = $true)]
        $Response
    )

    foreach ($link in @($Response.Links)) {
        $text = [string](Try-GetObjectPropertyValue -InputObject $link -PropertyName 'innerText')
        $href = [string](Try-GetObjectPropertyValue -InputObject $link -PropertyName 'href')
        if (-not [string]::IsNullOrWhiteSpace($href) -and $href -match '/Mod/DownloadMod/\d+') {
            return Resolve-AbsoluteUrl -Href $href -BaseUrl $Response.BaseResponse.ResponseUri.AbsoluteUri
        }

        if ($text -match '^\s*Download\s*$' -and -not [string]::IsNullOrWhiteSpace($href)) {
            return Resolve-AbsoluteUrl -Href $href -BaseUrl $Response.BaseResponse.ResponseUri.AbsoluteUri
        }
    }

    $html = [string]$Response.Content
    if (-not [string]::IsNullOrWhiteSpace($html)) {
        $match = [regex]::Match($html, '/Mod/DownloadMod/\d+')
        if ($match.Success) {
            return Resolve-AbsoluteUrl -Href $match.Value -BaseUrl $Response.BaseResponse.ResponseUri.AbsoluteUri
        }
    }

    return $null
}

function Get-ModPageCandidatesFromSearchResponse {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ModId,

        [Parameter(Mandatory = $true)]
        $Response
    )

    $searchUrl = $Response.BaseResponse.ResponseUri.AbsoluteUri
    $candidates = [System.Collections.Generic.List[object]]::new()
    $seenUrls = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $ordinal = 0

    foreach ($link in @($Response.Links)) {
        $href = [string](Try-GetObjectPropertyValue -InputObject $link -PropertyName 'href')
        if ([string]::IsNullOrWhiteSpace($href)) {
            continue
        }

        $absoluteUrl = Resolve-AbsoluteUrl -Href $href -BaseUrl $searchUrl
        if ([string]::IsNullOrWhiteSpace($absoluteUrl) -or $absoluteUrl -notmatch '/Mod/\d+/') {
            continue
        }

        if (-not $seenUrls.Add($absoluteUrl)) {
            continue
        }

        $text = [string](Try-GetObjectPropertyValue -InputObject $link -PropertyName 'innerText')
        $slug = ''
        if ($absoluteUrl -match '/Mod/\d+/([^/?#]+)') {
            $slug = $Matches[1]
        }
        $normalizedText = if ([string]::IsNullOrWhiteSpace($text)) { '' } else { Get-NormalizedModName -Value $text }
        $normalizedSlug = if ([string]::IsNullOrWhiteSpace($slug)) { '' } else { Get-NormalizedModName -Value $slug }
        $normalizedModId = Get-NormalizedModName -Value $ModId

        $score = 1000 - $ordinal
        $matchReason = 'search-result-order'
        if ($normalizedText -eq $normalizedModId -or $normalizedSlug -eq $normalizedModId) {
            $score += 100
            $matchReason = 'exact-match-in-search-results'
        }
        elseif ((-not [string]::IsNullOrWhiteSpace($normalizedText) -and $normalizedText -match [regex]::Escape($normalizedModId)) -or
            (-not [string]::IsNullOrWhiteSpace($normalizedSlug) -and $normalizedSlug -match [regex]::Escape($normalizedModId))) {
            $score += 50
            $matchReason = 'normalized-match-in-search-results'
        }

        $ordinal += 1

        $candidates.Add([pscustomobject]@{
                Url    = $absoluteUrl
                Text   = $text
                Slug   = $slug
                Score  = $score
                Reason = $matchReason
            })
    }

    if ($candidates.Count -gt 0) {
        return @($candidates | Sort-Object -Property @{ Expression = 'Score'; Descending = $true }, @{ Expression = 'Url'; Descending = $false })
    }

    $html = [string]$Response.Content
    if (-not [string]::IsNullOrWhiteSpace($html)) {
        $pattern = '/Mod/\d+/[^"''<>\s]+'
        $normalizedModId = Get-NormalizedModName -Value $ModId
        foreach ($match in [regex]::Matches($html, $pattern)) {
            $absoluteUrl = Resolve-AbsoluteUrl -Href $match.Value -BaseUrl $searchUrl
            if (-not $seenUrls.Add($absoluteUrl)) {
                continue
            }

            $slug = ''
            if ($absoluteUrl -match '/Mod/\d+/([^/?#]+)') {
                $slug = $Matches[1]
            }

            $normalizedSlug = if ([string]::IsNullOrWhiteSpace($slug)) { '' } else { Get-NormalizedModName -Value $slug }
            if ([string]::IsNullOrWhiteSpace($normalizedSlug)) {
                continue
            }

            $score = 500 - $ordinal
            $reason = 'raw-html-search-result'
            if ($normalizedSlug -eq $normalizedModId) {
                $score += 100
                $reason = 'raw-html-exact-match'
            }

            $ordinal += 1
            $candidates.Add([pscustomobject]@{
                    Url    = $absoluteUrl
                    Text   = ''
                    Slug   = $slug
                    Score  = $score
                    Reason = $reason
                })
        }
    }

    return @($candidates | Sort-Object -Property @{ Expression = 'Score'; Descending = $true }, @{ Expression = 'Url'; Descending = $false })
}

function Find-ModPageUrlOnHub {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ModId
    )

    $encoded = [System.Uri]::EscapeDataString($ModId)
    $searchUrl = '{0}/Mods/Search?query={1}' -f $script:HubBaseUrl, $encoded
    Write-Log -Message ("Searching COI Hub for '{0}' using {1}" -f $ModId, $searchUrl)

    try {
        $response = Invoke-HubRequest -Url $searchUrl
    }
    catch {
        throw "search page fetch failed for '$ModId': $($_.Exception.Message)"
    }

    $candidates = @(Get-ModPageCandidatesFromSearchResponse -ModId $ModId -Response $response)
    if ($candidates.Count -eq 0) {
        throw "no matching mod result for '$ModId'"
    }

    $validationErrors = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in $candidates) {
        try {
            $detailResponse = Invoke-HubRequest -Url $candidate.Url
            if (Test-IsValidModPage -ModId $ModId -Response $detailResponse) {
                Write-Log -Message ("Resolved '{0}' from search results via {1}: {2}" -f $ModId, $candidate.Reason, $candidate.Url)
                return [pscustomobject]@{
                    ModPageUrl = $candidate.Url
                    Response   = $detailResponse
                    MatchReason = $candidate.Reason
                    SearchUrl  = $searchUrl
                }
            }

            $validationErrors.Add(("candidate '{0}' failed validation" -f $candidate.Url))
        }
        catch {
            $validationErrors.Add(("candidate '{0}' could not be loaded: {1}" -f $candidate.Url, $_.Exception.Message))
        }
    }

    throw ("detail page parsing failed for '{0}': {1}" -f $ModId, ($validationErrors -join '; '))
}

function Get-RemoteMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ModId,

        [hashtable]$CacheEntry
    )

    $modPageUrl = $null
    $cachedDownloadUrl = $null

    if ($CacheEntry) {
        $modPageUrl = [string]$CacheEntry.modPageUrl
        $cachedDownloadUrl = [string]$CacheEntry.downloadUrl
    }

    $response = $null
    $lookupSource = 'search'
    $matchReason = ''
    if (-not [string]::IsNullOrWhiteSpace($modPageUrl)) {
        try {
            $response = Invoke-HubRequest -Url $modPageUrl
            if (Test-IsValidModPage -ModId $ModId -Response $response) {
                $lookupSource = 'cache'
                Write-Log -Message ("Using cached COI Hub page for '{0}': {1}" -f $ModId, $modPageUrl)
            }
            else {
                Write-Log -Level 'WARN' -Message ("Cached page URL no longer validates for '{0}', re-searching: {1}" -f $ModId, $modPageUrl)
                $response = $null
                $modPageUrl = $null
            }
        }
        catch {
            Write-Log -Level 'WARN' -Message ("Cached page URL failed for '{0}', will re-search: {1}" -f $ModId, $_.Exception.Message)
            $response = $null
            $modPageUrl = $null
        }
    }

    if ($null -eq $response) {
        $lookup = Find-ModPageUrlOnHub -ModId $ModId
        $modPageUrl = $lookup.ModPageUrl
        $response = $lookup.Response
        $lookupSource = 'search'
        $matchReason = [string]$lookup.MatchReason
    }

    $remoteVersion = Get-LatestVersionFromHtml -Html $response.Content
    if ([string]::IsNullOrWhiteSpace($remoteVersion)) {
        throw "detail page parsing failed for '$ModId': could not determine the latest version from $modPageUrl"
    }

    $downloadUrl = Get-DownloadUrlFromResponse -Response $response
    if ([string]::IsNullOrWhiteSpace($downloadUrl)) {
        $downloadUrl = $cachedDownloadUrl
        if (-not [string]::IsNullOrWhiteSpace($downloadUrl)) {
            Write-Log -Level 'WARN' -Message ("Using cached download URL for '{0}' because the detail page did not expose one directly." -f $ModId)
        }
    }

    if ([string]::IsNullOrWhiteSpace($downloadUrl)) {
        throw "detail page parsing failed for '$ModId': could not determine a download URL from $modPageUrl"
    }

    return [pscustomobject]@{
        ModPageUrl    = $modPageUrl
        DownloadUrl   = $downloadUrl
        RemoteVersion = $remoteVersion
        LookupSource  = $lookupSource
        MatchReason   = $matchReason
    }
}

function Download-ModArchive {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ModId,

        [Parameter(Mandatory = $true)]
        [string]$RemoteVersion,

        [Parameter(Mandatory = $true)]
        [string]$DownloadUrl
    )

    $safeVersion = ($RemoteVersion -replace '[^\w\.\-]+', '_')
    $zipPath = Join-Path $script:DownloadsRoot ('{0}-{1}.zip' -f $ModId, $safeVersion)

    if (-not (Test-Path -LiteralPath $zipPath)) {
        if ($PSCmdlet.ShouldProcess($zipPath, "Download archive from $DownloadUrl")) {
            Invoke-WebRequest -Uri $DownloadUrl -OutFile $zipPath -WebSession $script:Session -Headers @{ 'User-Agent' = $script:DefaultUserAgent } -UseBasicParsing
        }
    }
    else {
        Write-Log -Message ("Reusing existing archive: {0}" -f $zipPath)
    }

    return $zipPath
}

function Get-ValidatedExtractedMod {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ZipPath,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedModId,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedVersion
    )

    $safeVersion = ($ExpectedVersion -replace '[^\w\.\-]+', '_')
    $extractRoot = Join-Path (Join-Path $script:StagingRoot $ExpectedModId) $safeVersion

    if (Test-Path -LiteralPath $extractRoot) {
        Remove-Item -LiteralPath $extractRoot -Recurse -Force
    }

    if ($PSCmdlet.ShouldProcess($extractRoot, "Extract archive $ZipPath")) {
        New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null
        Expand-Archive -LiteralPath $ZipPath -DestinationPath $extractRoot -Force
    }

    $manifestCandidates = @(Get-ChildItem -LiteralPath $extractRoot -Filter 'manifest.json' -File -Recurse)
    if ($manifestCandidates.Count -eq 0) {
        throw "Downloaded archive does not contain a manifest.json file."
    }

    foreach ($manifestFile in $manifestCandidates) {
        try {
            $manifest = Get-Content -LiteralPath $manifestFile.FullName -Raw | ConvertFrom-Json
            if ($manifest.id -eq $ExpectedModId) {
                if ($manifest.version -ne $ExpectedVersion) {
                    Write-Log -Level 'WARN' -Message ("Package version for '{0}' is '{1}', expected '{2}'." -f $ExpectedModId, $manifest.version, $ExpectedVersion)
                }

                return [pscustomobject]@{
                    ExtractRoot     = $extractRoot
                    Manifest        = $manifest
                    ManifestPath    = $manifestFile.FullName
                    ModFolderPath   = Split-Path -Parent $manifestFile.FullName
                    ModFolderName   = Split-Path -Leaf (Split-Path -Parent $manifestFile.FullName)
                }
            }
        }
        catch {
            Write-Log -Level 'WARN' -Message ("Ignoring unreadable manifest candidate at '{0}': {1}" -f $manifestFile.FullName, $_.Exception.Message)
        }
    }

    throw "Downloaded archive did not contain a manifest.json with id '$ExpectedModId'."
}

function Merge-ModFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceRoot,

        [Parameter(Mandatory = $true)]
        [string]$DestinationRoot
    )

    $stats = [ordered]@{
        CreatedDirectories      = 0
        OverwrittenFiles        = 0
        CopiedNewFiles          = 0
        SkippedProtectedFiles   = 0
        CopiedNewProtectedFiles = 0
        DocExceptionOverwrites  = 0
        ReplacedManifest        = 0
    }

    $createdDirectories = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $sourceFiles = @(Get-ChildItem -LiteralPath $SourceRoot -File -Recurse)

    foreach ($sourceFile in $sourceFiles) {
        $relativePath = $sourceFile.FullName.Substring($SourceRoot.Length).TrimStart('\', '/')
        $destinationPath = Join-Path $DestinationRoot $relativePath
        $destinationDirectory = Split-Path -Parent $destinationPath
        $destinationExists = Test-Path -LiteralPath $destinationPath
        $fileName = $sourceFile.Name
        $relativePathParts = @($relativePath -split '[\\/]')
        $extension = [System.IO.Path]::GetExtension($fileName).ToLowerInvariant()
        $isManifest = $sourceFile.Name -ieq 'manifest.json'
        $isJson = $extension -eq '.json'
        $isText = $extension -eq '.txt'
        $isNoExtension = [string]::IsNullOrWhiteSpace($extension)
        $isTranslationsException = ($relativePathParts | Where-Object { $_ -match '(?i)translations' } | Select-Object -First 1) -ne $null
        $isDocExceptionName = ($relativePathParts | Where-Object { $_ -match '(?i)(readme|changelog|license|credits)' } | Select-Object -First 1) -ne $null
        $isDocException = ($isTranslationsException -and ($isJson -or $isText -or $isNoExtension)) -or ($isDocExceptionName -and -not $isJson -and ($isText -or $isNoExtension))
        $isProtected = ($isText -or $isJson) -and -not $isManifest -and -not $isDocException

        if (-not (Test-Path -LiteralPath $destinationDirectory)) {
            if ($PSCmdlet.ShouldProcess($destinationDirectory, 'Create destination directory for in-place merge')) {
                New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
            }

            if ($createdDirectories.Add($destinationDirectory)) {
                $stats.CreatedDirectories += 1
            }
        }

        if ($isManifest) {
            if ($PSCmdlet.ShouldProcess($destinationPath, "Replace manifest.json from $($sourceFile.FullName)")) {
                Copy-Item -LiteralPath $sourceFile.FullName -Destination $destinationPath -Force
            }

            $stats.ReplacedManifest += 1
            continue
        }

        if ($isDocException -and $destinationExists) {
            Write-Log -Message ("Overwriting doc exception file during in-place merge: {0}" -f $destinationPath)

            if ($PSCmdlet.ShouldProcess($destinationPath, "Overwrite doc exception file from $($sourceFile.FullName)")) {
                Copy-Item -LiteralPath $sourceFile.FullName -Destination $destinationPath -Force
            }

            $stats.DocExceptionOverwrites += 1
            continue
        }

        if ($isProtected) {
            if ($destinationExists) {
                Write-Log -Message ("Preserving protected file during in-place merge: {0}" -f $destinationPath)
                $stats.SkippedProtectedFiles += 1
                continue
            }

            if ($PSCmdlet.ShouldProcess($destinationPath, "Copy new protected file from $($sourceFile.FullName)")) {
                Copy-Item -LiteralPath $sourceFile.FullName -Destination $destinationPath -Force
            }

            $stats.CopiedNewProtectedFiles += 1
            continue
        }

        if ($PSCmdlet.ShouldProcess($destinationPath, "Merge file from $($sourceFile.FullName)")) {
            Copy-Item -LiteralPath $sourceFile.FullName -Destination $destinationPath -Force
        }

        if ($destinationExists) {
            $stats.OverwrittenFiles += 1
        }
        else {
            $stats.CopiedNewFiles += 1
        }
    }

    return [pscustomobject]$stats
}

function Backup-AndInstallMod {
    param(
        [Parameter(Mandatory = $true)]
        $InstalledMod,

        [Parameter(Mandatory = $true)]
        $ExtractedMod
    )

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupPath = Join-Path (Join-Path $script:BackupRoot $timestamp) $InstalledMod.DirectoryName
    $targetInstallPath = $InstalledMod.Directory

    if ($PSCmdlet.ShouldProcess($InstalledMod.Directory, "Back up installed mod to $backupPath")) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $backupPath) -Force | Out-Null
        Copy-Item -LiteralPath $InstalledMod.Directory -Destination $backupPath -Recurse -Force
    }

    Write-Log -Message ("Applying in-place merge install for '{0}' from '{1}' into '{2}'." -f $InstalledMod.Id, $ExtractedMod.ModFolderPath, $targetInstallPath)
    $mergeStats = Merge-ModFiles -SourceRoot $ExtractedMod.ModFolderPath -DestinationRoot $targetInstallPath
    Write-Log -Message ("In-place merge complete for '{0}': overwritten={1}, new={2}, skipped_protected={3}, new_protected={4}, doc_exception_overwrites={5}, manifest_replaced={6}, dirs_created={7}" -f $InstalledMod.Id, $mergeStats.OverwrittenFiles, $mergeStats.CopiedNewFiles, $mergeStats.SkippedProtectedFiles, $mergeStats.CopiedNewProtectedFiles, $mergeStats.DocExceptionOverwrites, $mergeStats.ReplacedManifest, $mergeStats.CreatedDirectories)

    return $targetInstallPath
}

Ensure-Directory -Path $script:DownloadsRoot
Ensure-Directory -Path $script:BackupRoot
Ensure-Directory -Path $script:StagingRoot
Ensure-Directory -Path $script:ModsRoot

if (-not (Test-Path -LiteralPath $script:LogPath)) {
    New-Item -ItemType File -Path $script:LogPath -Force | Out-Null
}

Write-Log -Message ("Starting Captain of Industry mod update run. Filter ModId: {0}" -f ($(if ($ModId) { $ModId } else { '<all>' })))

$cache = Get-Cache
$installedMods = @(Get-InstalledMods -FilterModId $ModId)

if ($installedMods.Count -eq 0) {
    Write-Log -Level 'WARN' -Message 'No installed mods were found that matched the requested filter.'
    return
}

foreach ($installedMod in $installedMods) {
    Write-Log -Message ("Checking '{0}' (installed version {1})" -f $installedMod.Id, $installedMod.Version)

    try {
        $cacheEntry = if ($cache.ContainsKey($installedMod.Id)) { $cache[$installedMod.Id] } else { $null }
        $remote = Get-RemoteMetadata -ModId $installedMod.Id -CacheEntry $cacheEntry

        $cache[$installedMod.Id] = @{
            id                = $installedMod.Id
            modPageUrl        = $remote.ModPageUrl
            downloadUrl       = $remote.DownloadUrl
            lastSeenRemoteVersion = $remote.RemoteVersion
            lastResolvedUtc   = [DateTime]::UtcNow.ToString('o')
        }
        Save-Cache -Cache $cache

        $comparison = Compare-VersionStrings -Left $installedMod.Version -Right $remote.RemoteVersion
        if ($comparison -ge 0) {
            Write-Log -Level 'SUCCESS' -Message ("'{0}' is up-to-date ({1})." -f $installedMod.Id, $installedMod.Version)
            $script:Summary.Add([pscustomobject]@{
                    Id      = $installedMod.Id
                    Status  = 'up-to-date'
                    Version = $installedMod.Version
                    Remote  = $remote.RemoteVersion
                    Note    = ''
                })
            continue
        }

        Write-Log -Message ("Update available for '{0}': {1} -> {2}" -f $installedMod.Id, $installedMod.Version, $remote.RemoteVersion)
        $zipPath = Download-ModArchive -ModId $installedMod.Id -RemoteVersion $remote.RemoteVersion -DownloadUrl $remote.DownloadUrl
        $extracted = Get-ValidatedExtractedMod -ZipPath $zipPath -ExpectedModId $installedMod.Id -ExpectedVersion $remote.RemoteVersion
        $installPath = Backup-AndInstallMod -InstalledMod $installedMod -ExtractedMod $extracted

        Write-Log -Level 'SUCCESS' -Message ("Installed '{0}' version {1} to {2}" -f $installedMod.Id, $remote.RemoteVersion, $installPath)
        $script:Summary.Add([pscustomobject]@{
                Id      = $installedMod.Id
                Status  = 'updated'
                Version = $installedMod.Version
                Remote  = $remote.RemoteVersion
                Note    = $installPath
            })
    }
    catch {
        Write-Log -Level 'ERROR' -Message ("Failed to process '{0}': {1}" -f $installedMod.Id, $_.Exception.Message)
        $script:Summary.Add([pscustomobject]@{
                Id      = $installedMod.Id
                Status  = 'failed'
                Version = $installedMod.Version
                Remote  = ''
                Note    = $_.Exception.Message
            })
    }
}

Write-Host ''
Write-Host 'Summary'
Write-Host '-------'
$script:Summary | Sort-Object Id | Format-Table -AutoSize
Write-Host ''
Write-Host ("Log file: {0}" -f $script:LogPath)
