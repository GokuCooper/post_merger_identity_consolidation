<#
.SYNOPSIS
    Day 6: Finds WHERE each service account is actually used.

.DESCRIPTION
    Before CyberArk rotates a service account password, you need to know every
    Windows service and scheduled task that logs on with it. Miss one and that
    program breaks on its next restart. This is the "usages" list you configure
    in CyberArk so the CPM updates them on every rotation.

    Queries each server for:
      - Windows services whose "Log on as" is a domain account
      - Scheduled tasks that run as a domain account

.EXAMPLE
    .\11_Get-ServiceAccountUsage.ps1 -ComputerName DKNMIG01, DKNSYNC01
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]]$ComputerName,
    [string]$EvidencePath = '.\evidence\day6_service_account_usages.csv'
)

$builtIn = '^(LocalSystem|NT AUTHORITY\\|NT SERVICE\\|\.\\|$)'
$rows = New-Object System.Collections.Generic.List[object]

foreach ($c in $ComputerName) {
    try {
        $session = New-CimSession -ComputerName $c -ErrorAction Stop
    } catch {
        $rows.Add([pscustomobject]@{ Computer = $c; Type = 'Error'; Name = ''; RunsAs = ''; State = $_.Exception.Message })
        continue
    }

    Get-CimInstance -CimSession $session -ClassName Win32_Service |
        Where-Object { $_.StartName -notmatch $builtIn } |
        ForEach-Object {
            $rows.Add([pscustomobject]@{
                Computer = $c; Type = 'WindowsService'; Name = $_.Name; RunsAs = $_.StartName; State = $_.State
            })
        }

    Get-ScheduledTask -CimSession $session -ErrorAction SilentlyContinue |
        Where-Object { $_.Principal.UserId -and $_.Principal.UserId -match '\\|@' -and $_.Principal.UserId -notmatch $builtIn } |
        ForEach-Object {
            $rows.Add([pscustomobject]@{
                Computer = $c; Type = 'ScheduledTask'; Name = $_.TaskName; RunsAs = $_.Principal.UserId; State = $_.State
            })
        }

    Remove-CimSession $session
}

$dir = Split-Path -Parent $EvidencePath
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
if ($rows.Count -eq 0) {
    # Export-Csv writes a 0 byte file for an empty list, which looks like a failed run.
    # Write the header so the evidence file shows the scan ran and found nothing.
    '"Computer","Type","Name","RunsAs","State"' | Set-Content -Path $EvidencePath -Encoding ASCII
    Write-Host "No services or scheduled tasks log on as a domain account on: $($ComputerName -join ', ')" -ForegroundColor Yellow
} else {
    $rows | Export-Csv -Path $EvidencePath -NoTypeInformation
    $rows | Format-Table -AutoSize
}
Write-Host "Evidence saved to $EvidencePath" -ForegroundColor Cyan
