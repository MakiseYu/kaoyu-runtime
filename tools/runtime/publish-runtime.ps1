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
$credentialMap=@{}
$credentialLines="protocol=https`nhost=github.com`n`n" | git credential fill
foreach($entry in $credentialLines){if($entry -match '^([^=]+)=(.*)$'){$credentialMap[$Matches[1]]=$Matches[2]}}
if(-not $credentialMap.password){throw 'GitHub authentication is required'}
$headers=@{Authorization='Bearer '+$credentialMap.password;Accept='application/vnd.github+json';'X-GitHub-Api-Version'='2022-11-28'}
$api='https://api.github.com/repos/MakiseYu/kaoyu-runtime'
$release=$null
try{$release=Invoke-RestMethod -Uri "$api/releases/tags/$Tag" -Headers $headers}
catch{if([int]$_.Exception.Response.StatusCode -ne 404){throw}}
if($null -eq $release){
    $body=@{tag_name=$Tag;target_commitish='main';name=$Tag;body=[IO.File]::ReadAllText((Resolve-Path -LiteralPath $Notes));draft=$true;prerelease=$false}|ConvertTo-Json
    $release=Invoke-RestMethod -Method Post -Uri "$api/releases" -Headers $headers -ContentType 'application/json' -Body $body
}
if(-not $release.draft){throw 'Release is already public; do not mutate published runtime assets'}
$client=[System.Net.Http.HttpClient]::new()
$client.Timeout=[TimeSpan]::FromMinutes(45)
$client.DefaultRequestHeaders.Authorization=[System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$credentialMap.password)
$client.DefaultRequestHeaders.UserAgent.ParseAdd('kaoyu-runtime-publisher/1')
$credentialMap.Clear()
try {
    foreach($asset in $Assets){
        if([IO.Path]::GetFileName($asset) -ne $asset -or $asset -match '(?i)\.(pk8|jks|pem|key)$'){throw 'Invalid release asset name'}
        $path=Join-Path $releaseDirectory $asset
        $file=Get-Item -LiteralPath $path
        $hash=(Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
        $existing=@($release.assets | Where-Object {$_.name -eq $asset})
        if($existing.Count -gt 0){
            if($existing[0].size -ne $file.Length -or $existing[0].digest -ne "sha256:$hash"){throw "Existing asset mismatch: $asset"}
            Write-Output "Verified existing asset: $asset"
            continue
        }
        Write-Output "Uploading: $asset ($($file.Length) bytes)"
        $stream=[IO.File]::OpenRead($path)
        $content=[System.Net.Http.StreamContent]::new($stream)
        $content.Headers.ContentType=[System.Net.Http.Headers.MediaTypeHeaderValue]::new('application/octet-stream')
        $content.Headers.ContentLength=$file.Length
        try{
            $url="https://uploads.github.com/repos/MakiseYu/kaoyu-runtime/releases/$($release.id)/assets?name=$([Uri]::EscapeDataString($asset))"
            $response=$client.PostAsync($url,$content).GetAwaiter().GetResult()
            $result=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
            if(-not $response.IsSuccessStatusCode){throw "Upload failed: HTTP $([int]$response.StatusCode)"}
            if($result.size -ne $file.Length -or $result.digest -ne "sha256:$hash"){throw "Uploaded asset mismatch: $asset"}
            Write-Output "Verified uploaded asset: $asset sha256:$hash"
        } finally {$content.Dispose();$stream.Dispose()}
    }
    if($Publish){
        $release=Invoke-RestMethod -Method Patch -Uri "$api/releases/$($release.id)" -Headers $headers -ContentType 'application/json' -Body '{"draft":false,"make_latest":"true"}'
        Write-Output ('Published: '+$release.html_url)
    } else {Write-Output ('Draft prepared: '+$release.html_url)}
} finally {$client.Dispose();$headers.Clear()}
