<#
.SYNOPSIS
    Day 4: Proves the custom AD attribute made it to Entra ID.

.DESCRIPTION
    Directory extensions synced by Entra Connect show up in Entra with a long
    generated name like extension_<appIdWithoutDashes>_dknSourceCompany.
    The portal does not show them, so this script:

      1. Asks Microsoft Graph for every synced extension property
      2. Finds the one ending in _dknSourceCompany
      3. Pulls every user's value for it and exports the result

    Uses the Microsoft Graph PowerShell SDK with delegated sign in
    (use your labadmin account, read only scopes, user consent only).
    Run it from PowerShell 7 on a workstation, not on the Entra Connect server.

    -TenantId is required. Without it, Web Account Manager can treat a work
    account as a personal Microsoft account and fail with
    "That Microsoft account doesn't exist".

.EXAMPLE
    Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
    .\08_Get-SyncedSourceCompany.ps1 -TenantId <tenant>.onmicrosoft.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$TenantId,
    [string]$AttributeName  = 'dknSourceCompany',
    [string]$EvidencePath   = '.\evidence\day4_entra_source_company.csv'
)

Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
Connect-MgGraph -TenantId $TenantId -Scopes 'User.Read.All', 'Directory.Read.All' -NoWelcome -ErrorAction Stop

# 1. Find the generated extension name
$body = @{ isSyncedFromOnPremises = $true } | ConvertTo-Json
$ext  = Invoke-MgGraphRequest -Method POST `
            -Uri 'https://graph.microsoft.com/v1.0/directoryObjects/getAvailableExtensionProperties' `
            -Body $body -ContentType 'application/json'

$extName = ($ext.value | Where-Object { $_.name -like "*_$AttributeName" } | Select-Object -First 1).name
if (-not $extName) {
    throw "No synced extension ending in _$AttributeName found. Check Directory extension attribute sync in Entra Connect, then run a full sync."
}
Write-Host "Extension property: $extName" -ForegroundColor Green

# 2. Pull every user with that value (follow paging)
$select = "displayName,userPrincipalName,onPremisesSamAccountName,onPremisesSyncEnabled,$extName"
$uri    = "https://graph.microsoft.com/v1.0/users?`$select=$select&`$top=100"
$rows   = New-Object System.Collections.Generic.List[object]

while ($uri) {
    $page = Invoke-MgGraphRequest -Method GET -Uri $uri
    foreach ($u in $page.value) {
        $rows.Add([pscustomobject]@{
            DisplayName       = $u.displayName
            UserPrincipalName = $u.userPrincipalName
            OnPremSam         = $u.onPremisesSamAccountName
            SyncedFromAD      = [bool]$u.onPremisesSyncEnabled
            SourceCompany     = $u[$extName]
        })
    }
    $uri = $page.'@odata.nextLink'
}

$dir = Split-Path -Parent $EvidencePath
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
$rows | Export-Csv -Path $EvidencePath -NoTypeInformation

$rows | Where-Object SyncedFromAD | Group-Object SourceCompany | Select-Object Name, Count | Format-Table -AutoSize
Write-Host "Evidence saved to $EvidencePath" -ForegroundColor Cyan
Disconnect-MgGraph | Out-Null
