param(
    [Parameter(Mandatory=$true)][string]$Manifest,
    [Parameter(Mandatory=$true)][string]$PrivateKey,
    [string]$Signature
)
$ErrorActionPreference = 'Stop'
if (-not $Signature) { $Signature = $Manifest + '.sig' }
$signingKey = [System.Security.Cryptography.RSA]::Create()
try {
    $consumed = 0
    $signingKey.ImportPkcs8PrivateKey([System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $PrivateKey)), [ref]$consumed)
    $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Manifest))
    $signed = $signingKey.SignData($bytes, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    [System.IO.File]::WriteAllBytes($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Signature), $signed)
    if (-not $signingKey.VerifyData($bytes, $signed, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)) { throw 'Signature verification failed' }
    Write-Output ('Signed: ' + $Signature)
} finally { $signingKey.Dispose() }
