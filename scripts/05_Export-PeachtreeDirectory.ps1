<#
.SYNOPSIS
    Day 3: Takes a "before" snapshot of the Peachtree forest.

.DESCRIPTION
    Run from the iamlab.local side (DC or DKNMIG01) BEFORE ADMT moves anything.
    Exports every Peachtree user (with SID, employeeID, groups) and every group
    (with members) to CSV.

    These files do two jobs:
      1. Evidence: the "before" half of the migration count table.
      2. Fallback input: if ADMT will not cooperate, these CSVs are what you
         rebuild the accounts from with New-ADUser (no SID history in that case).

.EXAMPLE
    $cred = Get-Credential PEACHTREE\Administrator
    .\05_Export-PeachtreeDirectory.ps1 -Server PTDC01.peachtree.local -Credential $cred
#>
[CmdletBinding()]
param(
    [string]$Server = 'PTDC01.peachtree.local',
    [Parameter(Mandatory)]
    [pscredential]$Credential,
    [string]$EvidenceFolder = '.\evidence'
)

Import-Module ActiveDirectory -ErrorAction Stop
if (-not (Test-Path $EvidenceFolder)) { New-Item -ItemType Directory -Path $EvidenceFolder | Out-Null }

$common = @{ Server = $Server; Credential = $Credential }
$domainDN = (Get-ADDomain @common).DistinguishedName

# Skip built in accounts so the counts match what you seeded.
# Also skip trust accounts (IAMLAB$): they are user objects, but they are the
# forest trust's shared secret, not people, and must never be migrated.
$builtIn = 'Administrator', 'Guest', 'krbtgt', 'DefaultAccount', 'WDAGUtilityAccount'

$users = Get-ADUser @common -SearchBase $domainDN -Filter * -Properties employeeID, department, title,
            manager, memberOf, PasswordNeverExpires, servicePrincipalName, mail, objectSid |
         Where-Object { $_.SamAccountName -notin $builtIn -and $_.SamAccountName -notlike '*$' }

$userRows = foreach ($u in $users) {
    [pscustomobject]@{
        SamAccountName       = $u.SamAccountName
        Name                 = $u.Name
        GivenName            = $u.GivenName
        Surname              = $u.Surname
        EmployeeID           = $u.employeeID
        Department           = $u.department
        Title                = $u.title
        Mail                 = $u.mail
        Manager              = if ($u.manager) { (Get-ADUser @common -Identity $u.manager).SamAccountName } else { '' }
        SourceOU             = ($u.DistinguishedName -split ',', 2)[1]
        SourceSID            = $u.objectSid.Value
        PasswordNeverExpires = $u.PasswordNeverExpires
        HasSPN               = [bool]$u.servicePrincipalName
        Groups               = ($u.memberOf | ForEach-Object { ($_ -split ',')[0] -replace '^CN=' }) -join ';'
    }
}

$groups = Get-ADGroup @common -SearchBase "OU=Groups,$domainDN" -Filter * -Properties members, objectSid
$groupRows = foreach ($g in $groups) {
    [pscustomobject]@{
        Name        = $g.Name
        Scope       = $g.GroupScope
        SourceSID   = $g.objectSid.Value
        MemberCount = @($g.members).Count
        Members     = ($g.members | ForEach-Object { ($_ -split ',')[0] -replace '^CN=' }) -join ';'
    }
}

$userPath  = Join-Path $EvidenceFolder 'day3_source_users.csv'
$groupPath = Join-Path $EvidenceFolder 'day3_source_groups.csv'
$userRows  | Export-Csv -Path $userPath  -NoTypeInformation
$groupRows | Export-Csv -Path $groupPath -NoTypeInformation

Write-Host "Exported $(@($userRows).Count) users  -> $userPath"  -ForegroundColor Cyan
Write-Host "Exported $(@($groupRows).Count) groups -> $groupPath" -ForegroundColor Cyan
