#requires -Version 7.0
# Dot-source from $PROFILE.CurrentUserAllHosts. Machine-specific overrides run last.
[CmdletBinding()]
param([string] $LocalProfilePath = (Join-Path $HOME '.powershell.local.ps1'))

$env:DOTFILES_DIR = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))

if (Get-Command Set-PSReadLineOption -ErrorAction SilentlyContinue) {
    Set-PSReadLineOption -MaximumHistoryCount 50000 -HistoryNoDuplicates `
        -HistorySaveStyle SaveIncrementally
}

# Keep native aliases such as gc, gp, gl, ls, cp, mv and rm intact.
function .. { Set-Location .. }
function ... { Set-Location ../.. }
function g { git @args }
function gs { git status --short --branch @args }
function ga { git add @args }
function gd { git diff @args }
function gco { git checkout @args }
function gb { git branch @args }
function glog { git log --oneline --graph --decorate @args }

# Initialize mise first so tools it exposes are available on this first startup.
# Evaluate in the profile scope so generated functions/hooks remain available.
$dotfilesInitializers = @(
    @{ Name = 'mise'; Arguments = @('activate', 'pwsh') }
    @{ Name = 'oh-my-posh'; Arguments = @('init', 'pwsh') }
    @{ Name = 'zoxide'; Arguments = @('init', 'powershell') }
)
foreach ($dotfilesInitializer in $dotfilesInitializers) {
    if (-not (Get-Command $dotfilesInitializer.Name -ErrorAction SilentlyContinue)) { continue }
    $dotfilesArguments = $dotfilesInitializer.Arguments
    if ($dotfilesInitializer.Name -eq 'oh-my-posh' -and $env:OH_MY_POSH_CONFIG) {
        $dotfilesArguments += @('--config', $env:OH_MY_POSH_CONFIG)
    }
    try {
        $dotfilesOutput = & $dotfilesInitializer.Name @dotfilesArguments | Out-String
        if ($LASTEXITCODE -ne 0) {
            throw "Initializer exited with code $LASTEXITCODE"
        }
        if (-not [string]::IsNullOrWhiteSpace($dotfilesOutput)) {
            Invoke-Expression $dotfilesOutput
        }
    } catch {
        Write-Warning "Could not initialize $($dotfilesInitializer.Name): $_"
    }
}
Remove-Variable dotfilesInitializers, dotfilesInitializer, dotfilesArguments, dotfilesOutput `
    -ErrorAction SilentlyContinue

if (Test-Path -LiteralPath $LocalProfilePath -PathType Leaf) {
    . $LocalProfilePath
}
