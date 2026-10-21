param([string]$Publisher=(Join-Path $PSScriptRoot 'publish-runtime.ps1'))
# Offline regression tests: all GitHub and credential operations are mocked.
$ErrorActionPreference='Stop'
$testDirectory=Join-Path ([IO.Path]::GetTempPath()) ('kaoyu-publish-test-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testDirectory) | Out-Null
$assetPath=Join-Path $testDirectory 'runtime.properties'
[IO.File]::WriteAllText($assetPath,"format=2`n")
$notesPath=Join-Path $testDirectory 'notes.txt'
[IO.File]::WriteAllText($notesPath,'Test release')
$digest='sha256:'+(Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash.ToLowerInvariant()
$assetSize=(Get-Item -LiteralPath $assetPath).Length
$global:kaoyuPublisherTest_checks=0
function git { 'password=offline-test-placeholder' }
function New-TestRelease([bool]$draft=$true) {
    [pscustomobject]@{id=42;tag_name='runtime-test';draft=$draft;html_url='https://example.invalid/release'}
}
function Invoke-RestMethod {
    param($Uri,$Headers,$Method='Get',$ContentType,$Body)
    $global:kaoyuPublisherTest_calls.Add("$Method $Uri")
    if($Method -eq 'Delete'){throw 'A release or asset must never be deleted'}
    if($Method -eq 'Post'){
        $global:kaoyuPublisherTest_postCount++
        $global:kaoyuPublisherTest_listed=@($global:kaoyuPublisherTest_testRelease)
        if($global:kaoyuPublisherTest_createLostResponse){throw 'Connection lost after release creation'}
        return $global:kaoyuPublisherTest_testRelease
    }
    if($Method -eq 'Patch'){
        $global:kaoyuPublisherTest_patchCount++
        $global:kaoyuPublisherTest_testRelease.draft=$false
        return $global:kaoyuPublisherTest_testRelease
    }
    if($Uri -match '/releases\?per_page=100&page=(\d+)$'){
        $page=[int]$Matches[1]
        if($global:kaoyuPublisherTest_laterPage -and $page -eq 1){
            return @(1..100 | ForEach-Object {[pscustomobject]@{id=$_+100;tag_name="unrelated-$_";draft=$false}})
        }
        return $global:kaoyuPublisherTest_listed
    }
    if($Uri -match '/releases/42/assets\?per_page=100&page=1$'){return $global:kaoyuPublisherTest_remoteAssets}
    if($Uri -match '/releases/42$'){return $global:kaoyuPublisherTest_testRelease}
    throw "Unexpected network operation: $Method $Uri"
}
function Test-PublishCase($name,$setup,$expectedError,$posts=0,$patches=0,[bool]$publish=$false) {
    $global:kaoyuPublisherTest_calls=[Collections.Generic.List[string]]::new()
    $global:kaoyuPublisherTest_postCount=0
    $global:kaoyuPublisherTest_patchCount=0
    $global:kaoyuPublisherTest_laterPage=$false
    $global:kaoyuPublisherTest_createLostResponse=$false
    $global:kaoyuPublisherTest_testRelease=New-TestRelease
    $global:kaoyuPublisherTest_listed=@($global:kaoyuPublisherTest_testRelease)
    $global:kaoyuPublisherTest_remoteAssets=@([pscustomobject]@{name='runtime.properties';state='uploaded';size=$assetSize;digest=$digest})
    & $setup
    $caught=$null
    try { & $Publisher -Directory $testDirectory -Tag runtime-test -Notes $notesPath -Assets runtime.properties -Publish:$publish | Out-Null }
    catch { $caught=$_.Exception.Message }
    if($expectedError){
        if(-not $caught -or $caught -notlike "*$expectedError*"){throw "$name failed: expected '$expectedError', got '$caught'"}
    } elseif($caught){throw "$name failed: $caught"}
    if($global:kaoyuPublisherTest_postCount -ne $posts -or $global:kaoyuPublisherTest_patchCount -ne $patches){throw "$name performed an unexpected release mutation"}
    if(@($global:kaoyuPublisherTest_calls | Where-Object {$_ -match '/tags/'}).Count){throw "$name used the draft-unsafe tag endpoint"}
    $global:kaoyuPublisherTest_checks++
    Write-Output "PASS $name"
}
try {
    Test-PublishCase 'Reuse existing draft and uploaded asset' {} $null
    Test-PublishCase 'Find draft on later page' {$global:kaoyuPublisherTest_laterPage=$true} $null
    Test-PublishCase 'Verify public release without mutation' {$global:kaoyuPublisherTest_testRelease.draft=$false} $null 0 0 $true
    Test-PublishCase 'Reject public release missing asset' {$global:kaoyuPublisherTest_testRelease.draft=$false;$global:kaoyuPublisherTest_remoteAssets=@()} 'Published release is missing'
    Test-PublishCase 'Reject mismatched size' {$global:kaoyuPublisherTest_remoteAssets[0].size++} 'Existing asset mismatch'
    Test-PublishCase 'Reject mismatched digest' {$global:kaoyuPublisherTest_remoteAssets[0].digest='sha256:wrong'} 'Existing asset mismatch'
    Test-PublishCase 'Reject incomplete upload without deletion' {$global:kaoyuPublisherTest_remoteAssets[0].state='starter'} 'Existing asset is not complete'
    Test-PublishCase 'Reject ambiguous duplicate releases' {$global:kaoyuPublisherTest_listed=@($global:kaoyuPublisherTest_testRelease,(New-TestRelease))} 'Multiple releases have tag'
    Test-PublishCase 'Reject ambiguous duplicate assets' {$global:kaoyuPublisherTest_remoteAssets=@($global:kaoyuPublisherTest_remoteAssets[0],$global:kaoyuPublisherTest_remoteAssets[0])} 'Multiple assets have name'
    Test-PublishCase 'Create only when no draft exists' {$global:kaoyuPublisherTest_listed=@()} $null 1
    Test-PublishCase 'Recover successful creation with lost response' {$global:kaoyuPublisherTest_listed=@();$global:kaoyuPublisherTest_createLostResponse=$true} $null 1
    Test-PublishCase 'Publish verified draft once' {} $null 0 1 $true
    Write-Output "$global:kaoyuPublisherTest_checks publisher regression tests passed"
} finally {
    # Only this invocation's explicitly created temporary directory is removed.
    $resolvedTest=[IO.Path]::GetFullPath($testDirectory)
    $expectedParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    if(-not $resolvedTest.StartsWith($expectedParent,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe test directory cleanup'}
    Remove-Item -LiteralPath $resolvedTest -Recurse -Force
    Remove-Variable -Name 'kaoyuPublisherTest_*' -Scope Global
}
