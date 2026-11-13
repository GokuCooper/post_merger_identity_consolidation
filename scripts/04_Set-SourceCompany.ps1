<#
.SYNOPSIS
    Days 2 and 3: Stamps the custom dknSourceCompany attribute on users.

.DESCRIPTION
    Run on the iamlab.local DC after the attribute exists in the schema.

    Day 2: stamp the original DKN users with "DKN".
    Day 3: right after ADMT lands the Peachtree users in iamlab.local,
           stamp them with "Peachtree".

    (Peachtree users cannot be stamped on Day 2 because they still live in
    peachtree.local, which does not have this attribute in its schema.)

    Supports -WhatIf so you can screenshot a dry run first.

.EXAMPLE
    .\04_Set-SourceCompany.ps1 -Company DKN -SearchBase "OU=HR,DC=iamlab,DC=local","OU=IT,DC=iamlab,DC=local" -WhatIf
    .\04_Set-SourceCompany.ps1 -Company Peachtree -SearchBase "OU=Peachtree,OU=Acquired,DC=iamlab,DC=local"
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('DKN', 'Peachtree')]
    [string]$Company,

    [Parameter(Mandatory)]
    [string[]]$SearchBase,

    [string]$AttributeName = 'dknSourceCompany',
    [string]$EvidenceFolder = '.\evidence'
)

Import-Module ActiveDirectory -ErrorAction Stop
if (-not (Test-Path $EvidenceFolder)) { New-Item -ItemType Directory -Path $EvidenceFolder | Out-Null }

# One or more OUs; results from all of them land in one evidence file
$users = foreach ($sb in $SearchBase) {
    Get-ADUser -SearchBase $sb -Filter * -Properties $AttributeName, employeeID
}

# Never stamp DKN onto anyone sitting in the Acquired OU
if ($Company -eq 'DKN') {
    $users = $users | Where-Object { $_.DistinguishedName -notlike '*OU=Acquired,*' }
}

$results = foreach ($u in $users) {
    $before = $u.$AttributeName
    if ($before -eq $Company) {
        $status = 'AlreadySet'
    } elseif ($PSCmdlet.ShouldProcess($u.SamAccountName, "Set $AttributeName = $Company")) {
        try {
            Set-ADUser -Identity $u -Replace @{ $AttributeName = $Company } -ErrorAction Stop
            $status = 'Updated'
        } catch {
            $status = "Error: $($_.Exception.Message)"
        }
    } else {
        $status = 'WhatIf'
    }
    [pscustomobject]@{
        SamAccountName = $u.SamAccountName
        OU             = ($u.DistinguishedName -split ',', 2)[1]
        EmployeeID     = $u.employeeID
        Before         = $before
        After          = $Company
        Status         = $status
    }
}

$day  = if ($Company -eq 'DKN') { 'day2' } else { 'day3' }
$path = Join-Path $EvidenceFolder "${day}_source_company_stamp_$($Company.ToLower()).csv"
$results | Export-Csv -Path $path -NoTypeInformation
$results | Group-Object Status | Select-Object Name, Count | Format-Table -AutoSize
if ($WhatIfPreference) {
    Write-Host "Dry run only. Nothing changed and no evidence file was written." -ForegroundColor Yellow
} else {
    Write-Host "Evidence saved to $path" -ForegroundColor Cyan
}
