<#
.SYNOPSIS
    Day 3: Proves the ADMT migration worked, account by account.

.DESCRIPTION
    Run on the iamlab.local side AFTER the ADMT user and group wizards finish.
    Reads the "before" CSVs from 05_Export-PeachtreeDirectory.ps1 and finds each
    source object in iamlab.local.

    Matching order (strongest proof first):
      1. sIDHistory on the target contains the source SID  (ADMT with SID history)
      2. employeeID matches                                 (users only)
      3. same SamAccountName / group name                   (weakest)

    The output shows renames (jsmith -> jsmith_pt), whether SID history landed,
    and anything missing. That CSV plus the summary table is your Day 3
    "before and after" evidence.

.EXAMPLE
    .\06_Compare-MigrationResults.ps1 -TargetSearchBase "OU=Peachtree,OU=Acquired,DC=iamlab,DC=local"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$TargetSearchBase,
    [string]$EvidenceFolder = '.\evidence'
)

Import-Module ActiveDirectory -ErrorAction Stop

$srcUsers  = Import-Csv (Join-Path $EvidenceFolder 'day3_source_users.csv')
$srcGroups = Import-Csv (Join-Path $EvidenceFolder 'day3_source_groups.csv')

$tgtUsers  = Get-ADUser  -SearchBase $TargetSearchBase -Filter * -Properties sIDHistory, employeeID
$tgtGroups = Get-ADGroup -SearchBase $TargetSearchBase -Filter * -Properties sIDHistory

function Find-Target {
    param($SourceSid, $SourceName, $EmployeeId, $Candidates)

    $hit = $Candidates | Where-Object { $_.sIDHistory.Value -contains $SourceSid } | Select-Object -First 1
    if ($hit) { return @{ Obj = $hit; MatchedBy = 'SIDHistory' } }

    if ($EmployeeId) {
        $hit = $Candidates | Where-Object { $_.employeeID -eq $EmployeeId } | Select-Object -First 1
        if ($hit) { return @{ Obj = $hit; MatchedBy = 'EmployeeID' } }
    }

    $hit = $Candidates | Where-Object { $_.SamAccountName -eq $SourceName -or $_.Name -eq $SourceName } | Select-Object -First 1
    if ($hit) { return @{ Obj = $hit; MatchedBy = 'Name' } }

    return @{ Obj = $null; MatchedBy = 'NotFound' }
}

$rows = New-Object System.Collections.Generic.List[object]

foreach ($s in $srcUsers) {
    $m = Find-Target -SourceSid $s.SourceSID -SourceName $s.SamAccountName -EmployeeId $s.EmployeeID -Candidates $tgtUsers
    $t = $m.Obj
    $rows.Add([pscustomobject]@{
        Type          = 'User'
        SourceName    = $s.SamAccountName
        TargetName    = if ($t) { $t.SamAccountName } else { '' }
        Renamed       = if ($t) { $t.SamAccountName -ne $s.SamAccountName } else { '' }
        MatchedBy     = $m.MatchedBy
        HasSIDHistory = if ($t) { [bool]$t.sIDHistory } else { $false }
        TargetOU      = if ($t) { ($t.DistinguishedName -split ',', 2)[1] } else { '' }
    })
}

foreach ($s in $srcGroups) {
    $m = Find-Target -SourceSid $s.SourceSID -SourceName $s.Name -EmployeeId $null -Candidates $tgtGroups
    $t = $m.Obj
    $rows.Add([pscustomobject]@{
        Type          = 'Group'
        SourceName    = $s.Name
        TargetName    = if ($t) { $t.Name } else { '' }
        Renamed       = if ($t) { $t.Name -ne $s.Name } else { '' }
        MatchedBy     = $m.MatchedBy
        HasSIDHistory = if ($t) { [bool]$t.sIDHistory } else { $false }
        TargetOU      = if ($t) { ($t.DistinguishedName -split ',', 2)[1] } else { '' }
    })
}

$detailPath = Join-Path $EvidenceFolder 'day3_migration_results.csv'
$rows | Export-Csv -Path $detailPath -NoTypeInformation

$summary = foreach ($type in 'User', 'Group') {
    $set = $rows | Where-Object Type -eq $type
    [pscustomobject]@{
        Type            = $type
        InSource        = @($set).Count
        FoundInTarget   = @($set | Where-Object MatchedBy -ne 'NotFound').Count
        WithSIDHistory  = @($set | Where-Object HasSIDHistory).Count
        Renamed         = @($set | Where-Object { $_.Renamed -eq $true }).Count
        Missing         = @($set | Where-Object MatchedBy -eq 'NotFound').Count
    }
}
$summaryPath = Join-Path $EvidenceFolder 'day3_migration_counts.csv'
$summary | Export-Csv -Path $summaryPath -NoTypeInformation

$summary | Format-Table -AutoSize
$rows | Where-Object { $_.Renamed -eq $true -or $_.MatchedBy -eq 'NotFound' } | Format-Table -AutoSize
Write-Host "Evidence saved to $detailPath and $summaryPath" -ForegroundColor Cyan
