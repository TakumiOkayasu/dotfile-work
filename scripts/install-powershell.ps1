#requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param([string] $ProfilePath = $PROFILE.CurrentUserAllHosts)

$ErrorActionPreference = 'Stop'
$source = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../config/shell/powershell/profile.ps1'))
if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
    throw "PowerShell template not found: $source"
}
$target = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ProfilePath)
$loader = ". '$($source.Replace("'", "''"))' @args" + [Environment]::NewLine

if (Test-Path -LiteralPath $target) {
    if ((Test-Path -LiteralPath $target -PathType Leaf) -and
        [IO.File]::ReadAllText($target) -ceq $loader) {
        Write-Output "Already installed: $target"
        return
    }
    throw "Profile already exists: $target. Add this line manually: $($loader.TrimEnd())"
}

if ($PSCmdlet.ShouldProcess($target, 'Create PowerShell profile loader')) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
    # CreateNew also protects a profile created between the existence check and write.
    $stream = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($loader)
        $stream.Write($bytes, 0, $bytes.Length)
    } finally {
        $stream.Dispose()
    }
    Write-Output "Installed: $target"
}
