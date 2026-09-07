#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$installer = Join-Path $repo 'scripts/install-powershell.ps1'
$template = Join-Path $repo 'config/shell/powershell/profile.ps1'
$fixture = Join-Path ([IO.Path]::GetTempPath()) "dotfiles space ' $([guid]::NewGuid())"

function Assert-Equal($Actual, $Expected, [string] $Message) {
    if ($Actual -cne $Expected) {
        throw "$Message : expected <$Expected>, got <$Actual>"
    }
}

try {
    New-Item -ItemType Directory -Path $fixture | Out-Null
    $fixtureRepo = Join-Path $fixture 'repo'
    New-Item -ItemType Directory -Path (Join-Path $fixtureRepo 'scripts') | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fixtureRepo 'config/shell/powershell') | Out-Null
    Copy-Item -LiteralPath $installer -Destination (Join-Path $fixtureRepo 'scripts')
    Copy-Item -LiteralPath $template -Destination (Join-Path $fixtureRepo 'config/shell/powershell')
    $installer = Join-Path $fixtureRepo 'scripts/install-powershell.ps1'
    $template = Join-Path $fixtureRepo 'config/shell/powershell/profile.ps1'
    $target = Join-Path $fixture 'PowerShell/profile.ps1'
    & $installer -ProfilePath $target -WhatIf
    Assert-Equal (Test-Path $target) $false 'WhatIf must not create a profile'
    Assert-Equal (Test-Path (Split-Path $target)) $false 'WhatIf must not create directories'
    & $installer -ProfilePath $target
    $loader = Get-Content -LiteralPath $target -Raw
    & $installer -ProfilePath $target
    Assert-Equal (Get-Content -LiteralPath $target -Raw) $loader 'Reinstall must be idempotent'

    Set-Content -LiteralPath $target -Value '# existing user profile'
    $existing = [IO.File]::ReadAllBytes($target)
    $refused = $false
    try { & $installer -ProfilePath $target } catch { $refused = $true }
    Assert-Equal $refused $true 'Existing profiles must be refused'
    Assert-Equal ([Convert]::ToBase64String([IO.File]::ReadAllBytes($target))) `
        ([Convert]::ToBase64String($existing)) 'Existing profile bytes must survive'

    # Mock optional tools so tests never activate the developer/runner toolchain.
    function mise {
        Assert-Equal ($args -join ' ') 'activate pwsh' 'mise activation arguments'
        $global:LASTEXITCODE = 0
        'function Test-MiseActivation { "active" }'
    }
    function oh-my-posh {
        Assert-Equal ($args -join ' ') 'init pwsh' 'Oh My Posh initialization arguments'
        $global:LASTEXITCODE = 0
        'function Test-PoshActivation { "active" }'
    }
    function zoxide {
        Assert-Equal ($args -join ' ') 'init powershell' 'zoxide initialization arguments'
        $global:LASTEXITCODE = 0
        'function Test-ZoxideActivation { "active" }'
    }
    function Set-PSReadLineOption { }
    function git { $args | ConvertTo-Json -Compress }
    $env:OH_MY_POSH_CONFIG = ''
    $localProfile = Join-Path $fixture 'local.ps1'
    Set-Content -LiteralPath $localProfile -Value 'function gs { "local override" }'
    . ([scriptblock]::Create($loader)) -LocalProfilePath $localProfile
    Assert-Equal $env:DOTFILES_DIR $fixtureRepo 'Loader must handle spaces and quotes in repository paths'
    Assert-Equal (Test-MiseActivation) 'active' 'mise definitions must survive initialization'
    Assert-Equal (Test-PoshActivation) 'active' 'Prompt definitions must survive initialization'
    Assert-Equal (Test-ZoxideActivation) 'active' 'zoxide definitions must survive initialization'
    Assert-Equal (gs) 'local override' 'Local configuration must run last'
    Assert-Equal (gco 'branch with spaces') '["checkout","branch with spaces"]' 'Git argument boundaries'
    Assert-Equal ((Get-Alias gc).Definition) 'Get-Content' 'Native gc alias'
    Assert-Equal ((Get-Alias gp).Definition) 'Get-ItemProperty' 'Native gp alias'
    Assert-Equal ((Get-Alias gl).Definition) 'Get-Location' 'Native gl alias'

    function mise {
        $global:LASTEXITCODE = 1
        'throw "Failed initializer output must not execute"'
    }
    . $template -LocalProfilePath $localProfile -WarningVariable activationWarnings
    Assert-Equal ($activationWarnings -match 'mise' | Measure-Object).Count 1 'Failed activation must warn'
    Assert-Equal (gs) 'local override' 'Failed activation must not stop local configuration'

    # Test absent tools in the same process without depending on runner installations.
    function Get-Command {
        param([string] $Name, $ErrorAction)
        if ($Name -in @('mise', 'oh-my-posh', 'zoxide', 'Set-PSReadLineOption')) { return }
        Microsoft.PowerShell.Core\Get-Command $Name -ErrorAction $ErrorAction
    }
    . $template -LocalProfilePath (Join-Path $fixture 'missing.ps1')
    Assert-Equal (gs) '["status","--short","--branch"]' 'Profile without optional tools'
    Write-Output 'PowerShell profile and installer tests passed'
} finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force
}
