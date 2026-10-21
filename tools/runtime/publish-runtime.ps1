param(
    [Parameter(Mandatory=$true)][string]$Directory,
    [Parameter(Mandatory=$true)][string]$Tag,
    [Parameter(Mandatory=$true)][string]$Notes,
    [Parameter(Mandatory=$true)][string[]]$Assets,
    [switch]$Publish
)
# Use Git's existing account session. Never write the credential to disk or command arguments.
$ErrorActionPreference='Stop'
$env:GIT_TERMINAL_PROMPT='0'
$env:GCM_INTERACTIVE='never'
if($Tag -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,100}$'){throw 'Invalid release tag'}
$releaseDirectory=(Resolve-Path -LiteralPath $Directory).Path
$localAssets=@()
foreach($asset in $Assets){
    if([IO.Path]::GetFileName($asset) -ne $asset -or $asset -match '(?i)\.(pk8|jks|pem|key)$'){throw 'Invalid release asset name'}
    if(@($localAssets | Where-Object {$_.name -ceq $asset}).Count){throw "Duplicate requested asset: $asset"}
    $path=Join-Path $releaseDirectory $asset
    $file=Get-Item -LiteralPath $path
    if($file.PSIsContainer){throw "Expected an asset file: $asset"}
    $localAssets+=@{name=$asset;path=$path;size=$file.Length;digest='sha256:'+(Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()}
}
$releaseNotes=[IO.File]::ReadAllText((Resolve-Path -LiteralPath $Notes))
$credentialMap=@{}
$credentialLines="protocol=https`nhost=github.com`n`n" | git credential fill
foreach($entry in $credentialLines){if($entry -match '^([^=]+)=(.*)$'){$credentialMap[$Matches[1]]=$Matches[2]}}
if(-not $credentialMap.password){throw 'GitHub authentication is required'}
$headers=@{Authorization='Bearer '+$credentialMap.password;Accept='application/vnd.github+json';'X-GitHub-Api-Version'='2022-11-28';'User-Agent'='kaoyu-runtime-publisher/1'}
$api='https://api.github.com/repos/MakiseYu/kaoyu-runtime'
function Get-ReleaseForTag {
    # The tag endpoint can return 404 for a draft. Authenticated listings include it.
    $matchesForTag=@()
    for($page=1; ; $page++){
        $items=@(Invoke-RestMethod -Uri "$api/releases?per_page=100&page=$page" -Headers $headers)
        $matchesForTag+=@($items | Where-Object {$_.tag_name -ceq $Tag})
        if($items.Count -lt 100){break}
    }
    if($matchesForTag.Count -gt 1){throw "Multiple releases have tag $Tag; inspect their IDs before retrying"}
    if($matchesForTag.Count -eq 1){return $matchesForTag[0]}
}
function Get-ReleaseAssets($releaseId) {
    for($page=1; ; $page++){
        $items=@(Invoke-RestMethod -Uri "$api/releases/$releaseId/assets?per_page=100&page=$page" -Headers $headers)
        $items
        if($items.Count -lt 100){break}
    }
}
function Assert-ExistingAsset($remote,$local) {
    if($remote.state -ne 'uploaded'){throw "Existing asset is not complete: $($local.name) (state=$($remote.state)); inspect the active upload before retrying"}
    if($remote.size -ne $local.size -or $remote.digest -cne $local.digest){throw "Existing asset mismatch: $($local.name); nothing was deleted or overwritten"}
}
$client=$null
try {
    $release=Get-ReleaseForTag
    if($null -eq $release){
        $body=@{tag_name=$Tag;target_commitish='main';name=$Tag;body=$releaseNotes;draft=$true;prerelease=$false}|ConvertTo-Json
        try {$release=Invoke-RestMethod -Method Post -Uri "$api/releases" -Headers $headers -ContentType 'application/json' -Body $body}
        catch {
            # Creation may have succeeded before a connection dropped. Recover by listing.
            $createError=$_
            $release=Get-ReleaseForTag
            if($null -eq $release){throw $createError}
        }
    }
    Write-Output "Using release $($release.id) (draft=$($release.draft)): $Tag"
    $client=[System.Net.Http.HttpClient]::new()
    $client.Timeout=[TimeSpan]::FromMinutes(45)
    $client.DefaultRequestHeaders.Authorization=[System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$credentialMap.password)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('kaoyu-runtime-publisher/1')
    $credentialMap.Clear()
    foreach($local in $localAssets){
        $asset=$local.name
        # Refresh on every asset so a retry can reuse an upload completed by another attempt.
        $release=Invoke-RestMethod -Uri "$api/releases/$($release.id)" -Headers $headers
        $existing=@(Get-ReleaseAssets $release.id | Where-Object {$_.name -ceq $asset})
        if($existing.Count -gt 1){throw "Multiple assets have name $asset; inspect them before retrying"}
        if($existing.Count -gt 0){
            Assert-ExistingAsset $existing[0] $local
            Write-Output "Verified existing asset: $asset"
            continue
        }
        if(-not $release.draft){throw "Published release is missing $asset; published releases are never modified"}
        Write-Output "Uploading: $asset ($($local.size) bytes)"
        $stream=[IO.File]::OpenRead($local.path)
        $content=[System.Net.Http.StreamContent]::new($stream)
        $content.Headers.ContentType=[System.Net.Http.Headers.MediaTypeHeaderValue]::new('application/octet-stream')
        $content.Headers.ContentLength=$local.size
        $response=$null
        try{
            $url="https://uploads.github.com/repos/MakiseYu/kaoyu-runtime/releases/$($release.id)/assets?name=$([Uri]::EscapeDataString($asset))"
            $response=$client.PostAsync($url,$content).GetAwaiter().GetResult()
            $result=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
            if(-not $response.IsSuccessStatusCode){throw "Upload failed: HTTP $([int]$response.StatusCode)"}
            Assert-ExistingAsset $result $local
            Write-Output "Verified uploaded asset: $asset $($local.digest)"
        } finally {if($null -ne $response){$response.Dispose()};$content.Dispose();$stream.Dispose()}
    }
    $release=Invoke-RestMethod -Uri "$api/releases/$($release.id)" -Headers $headers
    if(-not $release.draft){Write-Output ('Verified public release: '+$release.html_url)}
    elseif($Publish){
        $release=Invoke-RestMethod -Method Patch -Uri "$api/releases/$($release.id)" -Headers $headers -ContentType 'application/json' -Body '{"draft":false,"make_latest":"true"}'
        Write-Output ('Published: '+$release.html_url)
    } else {Write-Output ('Draft prepared: '+$release.html_url)}
} finally {if($null -ne $client){$client.Dispose()};$credentialMap.Clear();$headers.Clear();$credentialLines=$null}
