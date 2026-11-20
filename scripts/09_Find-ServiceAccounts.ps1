<#
.SYNOPSIS
    Day 6: Builds the non human identity (NHI) inventory.

.DESCRIPTION
    Searches AD for accounts that look like they belong to a program, not a
    person, and scores each one against the naming and ownership standard:

        Naming standard : svc_<app>_<env> or gmsa_<app>_<env>   (example: svc_sql_pt)
        Owner rule      : manager attribute set, or Description starts with "Owner:"

    An account is flagged as a likely service account when ANY of these are true:
      - Password never expires
      - Has a servicePrincipalName
      - Name looks like a service account (svc, sql, backup, report, service, app)
      - Lives in a ServiceAccounts OU
      - Is a group Managed Service Account (gMSA). These are not user objects,
        so Get-ADUser never returns them. They are pulled in separately.

    Run it before the cleanup (Label before) and after (Label after). The two
    CSVs side by side are the Day 6 evidence.

.EXAMPLE
    .\09_Find-ServiceAccounts.ps1 -Label before
#>
[CmdletBinding()]
param(
    [string]$SearchBase,
    [ValidateSet('before', 'after')]
    [string]$Label = 'before',
    [string]$NamingPattern = '^(svc|gmsa)_[a-z0-9]+_[a-z0-9]+$',
    [string]$EvidenceFolder = '.\evidence'
)

Import-Module ActiveDirectory -ErrorAction Stop
if (-not (Test-Path $EvidenceFolder)) { New-Item -ItemType Directory -Path $EvidenceFolder | Out-Null }
if (-not $SearchBase) { $SearchBase = (Get-ADDomain).DistinguishedName }

$nameHints = '(^|_)(svc|sql|backup|report|service|app)'
$props = 'PasswordNeverExpires', 'servicePrincipalName', 'PasswordLastSet', 'LastLogonDate',
         'Description', 'manager', 'Enabled', 'memberOf'

$all = @(Get-ADUser -SearchBase $SearchBase -Filter * -Properties $props |
       Where-Object { $_.SamAccountName -notin 'krbtgt', 'Guest', 'DefaultAccount' })

# gMSAs are a different object class, so Get-ADUser misses them. Without this,
# the after inventory would hide the account that replaced svc_reports_pt.
$gmsaProps = 'servicePrincipalName', 'PasswordLastSet', 'LastLogonDate', 'Description', 'Enabled', 'memberOf'
$gmsas = @(Get-ADServiceAccount -SearchBase $SearchBase -Filter * -Properties $gmsaProps)
$gmsaSams = $gmsas | ForEach-Object { $_.SamAccountName }
$all += $gmsas

$inventory = foreach ($a in $all) {
    $isGmsa  = $a.SamAccountName -in $gmsaSams
    $sam     = $a.SamAccountName.TrimEnd('$')
    $reasons = @()
    if ($isGmsa)                                        { $reasons += 'gMSA' }
    if ($a.PasswordNeverExpires)                        { $reasons += 'PasswordNeverExpires' }
    if ($a.servicePrincipalName)                        { $reasons += 'HasSPN' }
    if ($sam -match $nameHints)                         { $reasons += 'NameLooksLikeService' }
    if ($a.DistinguishedName -like '*OU=ServiceAccounts,*') { $reasons += 'InServiceAccountsOU' }
    if (-not $reasons) { continue }

    $owner = ''
    if (-not $isGmsa -and $a.manager) {
        $owner = (Get-ADUser -Identity $a.manager).SamAccountName
    } elseif ($a.Description -match '^Owner:\s*([^|]+)') {
        $owner = $Matches[1].Trim()
    }

    $pwdAge = if ($a.PasswordLastSet) { [int]((Get-Date) - $a.PasswordLastSet).TotalDays } else { $null }
    $privileged = [bool]($a.memberOf | Where-Object { $_ -match 'CN=(Domain Admins|Enterprise Admins|Administrators),' })

    $issues = @()
    if ($sam -notmatch $NamingPattern)             { $issues += 'BadName' }
    if (-not $owner)                               { $issues += 'NoOwner' }
    if ($a.PasswordNeverExpires)                   { $issues += 'NeverRotates' }
    if ($privileged)                               { $issues += 'Privileged' }

    [pscustomobject]@{
        SamAccountName   = $a.SamAccountName
        Type             = if ($isGmsa) { 'gMSA' } else { 'User' }
        Enabled          = $a.Enabled
        Owner            = $owner
        WhyFlagged       = $reasons -join ';'
        Issues           = if ($issues) { $issues -join ';' } else { 'None' }
        PasswordAgeDays  = $pwdAge
        LastLogonDate    = $a.LastLogonDate
        SPN              = ($a.servicePrincipalName -join ';')
        Privileged       = $privileged
        OU               = ($a.DistinguishedName -split ',', 2)[1]
    }
}

$path = Join-Path $EvidenceFolder "day6_nhi_inventory_$Label.csv"
$inventory | Sort-Object Issues -Descending | Export-Csv -Path $path -NoTypeInformation

$compliant = @($inventory | Where-Object Issues -eq 'None').Count
Write-Host "`nService accounts found: $(@($inventory).Count)   Fully compliant: $compliant" -ForegroundColor Yellow
$inventory | Select-Object SamAccountName, Type, Enabled, Owner, Issues, PasswordAgeDays | Format-Table -AutoSize
Write-Host "Evidence saved to $path" -ForegroundColor Cyan
