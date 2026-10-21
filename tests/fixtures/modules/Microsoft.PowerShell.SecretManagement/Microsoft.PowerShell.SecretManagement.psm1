# Fake SecretManagement module for the tests. It is found first on PSModulePath in the child pwsh.
#   STUB_DEFAULT_VAULT  name of the vault reported as default ('Remote' or 'Local'); none if unset
#   STUB_SECRET_KIND    what Get-Secret returns: string (default), securestring, credential or hashtable
# Get-Secret records its arguments in $env:STUB_LOG_DIR/secret.json.

function Get-SecretVault {
    param([string] $Name)
    $vaults = @(
        [pscustomobject]@{ Name = 'Remote'; ModuleName = 'Az.KeyVault'; IsDefault = $env:STUB_DEFAULT_VAULT -eq 'Remote' }
        [pscustomobject]@{ Name = 'Local'; ModuleName = 'Microsoft.PowerShell.SecretStore'; IsDefault = $env:STUB_DEFAULT_VAULT -eq 'Local' }
    )
    if ($Name) { $vaults | Where-Object Name -EQ $Name } else { $vaults }
}

function Get-Secret {
    param([string] $Name, [string] $Vault)
    [ordered]@{ name = $Name; vault = $Vault } | ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $env:STUB_LOG_DIR 'secret.json') -Encoding utf8NoBOM

    $token = 'github_pat_FROMVAULT'
    switch ($env:STUB_SECRET_KIND) {
        'securestring' { ConvertTo-SecureString -String $token -AsPlainText -Force }
        'credential' { [pscredential]::new('user', (ConvertTo-SecureString -String $token -AsPlainText -Force)) }
        'hashtable' { @{ token = $token } }
        default { $token }
    }
}

Export-ModuleMember -Function Get-SecretVault, Get-Secret
