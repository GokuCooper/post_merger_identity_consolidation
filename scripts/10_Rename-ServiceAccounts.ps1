<#
.SYNOPSIS
    Day 6: Applies the naming standard and assigns an owner to each service account.

.DESCRIPTION
    Reads evidence\day6_service_account_naming.csv (OldSam, NewSam, Owner, App, Env, Purpose)
    and for each row:
      - renames sAMAccountName, UPN and the object's CN
      - sets the manager attribute to the human owner
      - writes "Owner: <owner> | App: <app> | Env: <env> | <purpose>" into Description

    Supports -WhatIf. Do a dry run first and screenshot it.

    IMPORTANT: renaming does not change the password or SID, so anything already
    running as the old name keeps working, but update the "Log on as" field
    on any service you configure afterward to use the NEW name.

.EXAMPLE
    .\10_Rename-ServiceAccounts.ps1 -WhatIf
    .\10_Rename-ServiceAccounts.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$MappingCsv     = '.\evidence\day6_service_account_naming.csv',
    [string]$EvidenceFolder = '.\evidence'
)

Import-Module ActiveDirectory -ErrorAction Stop
$upnSuffix = (Get-ADDomain).DNSRoot
$map = Import-Csv $MappingCsv

$results = foreach ($row in $map) {
    $acct = Get-ADUser -Filter "SamAccountName -eq '$($row.OldSam)'" -ErrorAction SilentlyContinue
    if (-not $acct) {
        [pscustomobject]@{ OldSam = $row.OldSam; NewSam = $row.NewSam; Owner = $row.Owner; Status = 'NotFound' }
        continue
    }

    $desc = "Owner: $($row.Owner) | App: $($row.App) | Env: $($row.Env) | $($row.Purpose)"
    if ($PSCmdlet.ShouldProcess($row.OldSam, "Rename to $($row.NewSam) and set owner $($row.Owner)")) {
        try {
            Set-ADUser -Identity $acct -SamAccountName $row.NewSam `
                -UserPrincipalName "$($row.NewSam)@$upnSuffix" `
                -Manager $row.Owner -Description $desc -ErrorAction Stop
            Rename-ADObject -Identity $acct.DistinguishedName -NewName $row.NewSam -ErrorAction Stop
            $status = 'Renamed'
        } catch {
            $status = "Error: $($_.Exception.Message)"
        }
    } else {
        $status = 'WhatIf'
    }
    [pscustomobject]@{ OldSam = $row.OldSam; NewSam = $row.NewSam; Owner = $row.Owner; Status = $status }
}

$results | Format-Table -AutoSize

# Only write evidence on a real run. A dry run must not overwrite the real results
# or claim a file was saved when Export-Csv was skipped by -WhatIf.
if ($WhatIfPreference) {
    Write-Host 'Dry run only. No changes made and no evidence file written.' -ForegroundColor Yellow
} else {
    $path = Join-Path $EvidenceFolder 'day6_service_account_rename_results.csv'
    $results | Export-Csv -Path $path -NoTypeInformation
    Write-Host "Evidence saved to $path" -ForegroundColor Cyan
}
