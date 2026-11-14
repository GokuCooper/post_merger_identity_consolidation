<#
.SYNOPSIS
    Day 4: Finds what will break Entra Connect BEFORE you sync.

.DESCRIPTION
    Run on the iamlab.local DC. Checks the two problems this lab plants on purpose:

      1. Duplicate proxyAddresses or mail values (Entra rejects the second object)
      2. UPN suffixes Entra cannot use (like .local), so users land as
         @<tenant>.onmicrosoft.com instead

    Run it once before the first sync (to predict the errors) and once after
    you fix things (to prove they are gone).

    Pass -SearchBase with the same OUs Entra Connect will sync, so the report
    only covers objects that will actually reach the cloud.

.EXAMPLE
    .\07_Find-SyncBlockers.ps1 -Label before -SearchBase "OU=Sales,DC=iamlab,DC=local","OU=IT,DC=iamlab,DC=local"
#>
[CmdletBinding()]
param(
    [string[]]$SearchBase,
    [ValidateSet('before', 'after')]
    [string]$Label = 'before',
    [string]$EvidenceFolder = '.\evidence'
)

Import-Module ActiveDirectory -ErrorAction Stop
if (-not (Test-Path $EvidenceFolder)) { New-Item -ItemType Directory -Path $EvidenceFolder | Out-Null }
if (-not $SearchBase) { $SearchBase = @((Get-ADDomain).DistinguishedName) }

$users = foreach ($sb in $SearchBase) {
    Get-ADUser -SearchBase $sb -Filter * -Properties proxyAddresses, mail, userPrincipalName
}

# ---------- 1. Duplicate proxyAddresses / mail ----------
$addressRows = foreach ($u in $users) {
    foreach ($p in $u.proxyAddresses) {
        [pscustomobject]@{ Address = ($p -replace '^smtp:', '').ToLower(); Source = 'proxyAddresses'; User = $u.SamAccountName }
    }
    if ($u.mail) {
        [pscustomobject]@{ Address = $u.mail.ToLower(); Source = 'mail'; User = $u.SamAccountName }
    }
}

$dupes = $addressRows |
    Group-Object Address |
    Where-Object { ($_.Group.User | Select-Object -Unique).Count -gt 1 } |
    ForEach-Object {
        [pscustomobject]@{
            Address = $_.Name
            Users   = ($_.Group.User | Select-Object -Unique) -join ';'
            Fields  = ($_.Group.Source | Select-Object -Unique) -join ';'
        }
    }

# ---------- 2. Non routable UPN suffixes ----------
$nonRoutable = '.local', '.lan', '.internal', '.corp', '.home'
$upnRows = $users | ForEach-Object {
    if ([string]::IsNullOrWhiteSpace($_.UserPrincipalName)) {
        # No UPN at all. Entra Connect builds one from the tenant domain, so flag it
        # instead of quietly counting a blank suffix as routable.
        $suffix   = '(no UPN)'
        $routable = $false
    } else {
        $suffix   = ($_.UserPrincipalName -split '@')[-1]
        $routable = -not ($nonRoutable | Where-Object { $suffix -like "*$_" })
    }
    [pscustomobject]@{
        User     = $_.SamAccountName
        OU       = ($_.DistinguishedName -split ',', 2)[1]
        UPN      = $_.UserPrincipalName
        Suffix   = $suffix
        Routable = $routable
    }
}

$dupePath = Join-Path $EvidenceFolder "day4_duplicate_addresses_$Label.csv"
$upnPath  = Join-Path $EvidenceFolder "day4_upn_suffix_check_$Label.csv"
$dupes   | Export-Csv -Path $dupePath -NoTypeInformation
$upnRows | Export-Csv -Path $upnPath  -NoTypeInformation

Write-Host "`nDuplicate addresses found: $(@($dupes).Count)" -ForegroundColor Yellow
$dupes | Format-Table -AutoSize
Write-Host "UPN suffix summary:" -ForegroundColor Yellow
$upnRows | Group-Object Suffix, Routable | Select-Object Name, Count | Format-Table -AutoSize
Write-Host "Evidence saved to $dupePath and $upnPath" -ForegroundColor Cyan
