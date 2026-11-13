<#
.SYNOPSIS
    Day 1: Proves DNS and the forest trust work, and saves the proof as evidence.

.DESCRIPTION
    Run on the iamlab.local DC. Run it once BEFORE you create the trust
    (it should show DNS working and no trust yet) and once AFTER (it should
    show the trust, its direction, and a clean netdom verify).

    Output goes to a transcript file so the README can link real output,
    not just screenshots.

.EXAMPLE
    .\02_Test-ForestTrust.ps1 -Label before
    .\02_Test-ForestTrust.ps1 -Label after
#>
[CmdletBinding()]
param(
    [string]$PartnerForest = 'peachtree.local',
    [ValidateSet('before', 'after')]
    [string]$Label = 'after',
    [string]$EvidenceFolder = '.\evidence'
)

Import-Module ActiveDirectory -ErrorAction Stop
if (-not (Test-Path $EvidenceFolder)) { New-Item -ItemType Directory -Path $EvidenceFolder | Out-Null }

$localForest = (Get-ADDomain).DNSRoot
$logPath     = Join-Path $EvidenceFolder "day1_trust_validation_$Label.txt"

Start-Transcript -Path $logPath -Force | Out-Null
Write-Output "Trust validation ($Label) run on $env:COMPUTERNAME at $(Get-Date -Format s)"
Write-Output "Local forest: $localForest   Partner forest: $PartnerForest"

Write-Output "`n=== 1. DNS: can we find the partner forest? ==="
try {
    Resolve-DnsName -Name $PartnerForest -ErrorAction Stop | Format-Table -AutoSize | Out-String | Write-Output
    Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$PartnerForest" -Type SRV -ErrorAction Stop |
        Format-Table -AutoSize | Out-String | Write-Output
} catch {
    Write-Output "DNS FAILED: $($_.Exception.Message)"
    Write-Output "Fix: create a conditional forwarder for $PartnerForest pointing at its DC."
}

Write-Output "`n=== 2. DC locator: can we find a DC in the partner forest? ==="
$nl = & nltest.exe "/dsgetdc:$PartnerForest" 2>&1
$nl | Out-String | Write-Output

Write-Output "`n=== 3. Trust objects in $localForest ==="
$trusts = Get-ADTrust -Filter * -ErrorAction SilentlyContinue
if ($trusts) {
    $trusts | Select-Object Name, Direction, ForestTransitive, SelectiveAuthentication,
        SIDFilteringQuarantined, SIDFilteringForestAware |
        Format-List | Out-String | Write-Output
} else {
    Write-Output "No trusts found yet."
}

if ($Label -eq 'after') {
    Write-Output "`n=== 4. netdom verify ==="
    $nd = & netdom.exe trust $localForest "/domain:$PartnerForest" /verify 2>&1
    $nd | Out-String | Write-Output
}

Stop-Transcript | Out-Null
Write-Host "Evidence saved to $logPath" -ForegroundColor Cyan
