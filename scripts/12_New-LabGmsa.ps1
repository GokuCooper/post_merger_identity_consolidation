<#
.SYNOPSIS
    Day 6 (stretch): Replaces one service account with a group Managed Service Account (gMSA).

.DESCRIPTION
    A gMSA is a service account whose password Windows rotates by itself
    (every 30 days by default) and that no human ever knows. It is the right
    choice when the program runs on Windows and supports gMSA. CyberArk is the
    right choice when it does not, or when a human sometimes needs the password.

    This script:
      1. Makes sure a KDS root key exists (the thing that generates gMSA passwords)
      2. Creates gmsa_reports_pt, allowed to be used only by the computers you name
      3. Exports the gMSA's settings as evidence

    LAB ONLY: the -EffectiveTime 10 hours in the past trick makes the KDS key
    usable right away. In production you create the key and wait for AD
    replication (about 10 hours) instead.

    After this runs, on the target server:
        Install-ADServiceAccount gmsa_reports_pt
        Test-ADServiceAccount   gmsa_reports_pt     # should return True
    then set the service's "Log on as" to IAMLAB\gmsa_reports_pt$ with a blank password.

.EXAMPLE
    .\12_New-LabGmsa.ps1 -AllowedComputers DKNMIG01
#>
[CmdletBinding()]
param(
    [string]$Name = 'gmsa_reports_pt',
    [Parameter(Mandatory)]
    [string[]]$AllowedComputers,
    [string]$EvidencePath = '.\evidence\day6_gmsa_settings.csv'
)

Import-Module ActiveDirectory -ErrorAction Stop
$dnsRoot = (Get-ADDomain).DNSRoot

if (-not (Get-KdsRootKey)) {
    Write-Host 'No KDS root key found. Creating one (lab shortcut).' -ForegroundColor Yellow
    Add-KdsRootKey -EffectiveTime ((Get-Date).AddHours(-10)) | Out-Null
}

$principals = $AllowedComputers | ForEach-Object { Get-ADComputer -Identity $_ }

if (-not (Get-ADServiceAccount -Filter "Name -eq '$Name'" -ErrorAction SilentlyContinue)) {
    New-ADServiceAccount -Name $Name `
        -DNSHostName "$Name.$dnsRoot" `
        -PrincipalsAllowedToRetrieveManagedPassword $principals `
        -Description 'Owner: mreed | App: reports | Env: pt | gMSA, rotated by Windows'
    Write-Host "Created gMSA $Name" -ForegroundColor Green
}

$g = Get-ADServiceAccount -Identity $Name -Properties PrincipalsAllowedToRetrieveManagedPassword, ManagedPasswordIntervalInDays, Description
[pscustomobject]@{
    Name                 = $g.Name
    DNSHostName          = $g.DNSHostName
    RotationIntervalDays = $g.ManagedPasswordIntervalInDays
    AllowedHosts         = ($g.PrincipalsAllowedToRetrieveManagedPassword | ForEach-Object { ($_ -split ',')[0] -replace '^CN=' }) -join ';'
    Description          = $g.Description
} | Tee-Object -Variable record | Format-List

$dir = Split-Path -Parent $EvidencePath
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
$record | Export-Csv -Path $EvidencePath -NoTypeInformation
Write-Host "Evidence saved to $EvidencePath" -ForegroundColor Cyan
