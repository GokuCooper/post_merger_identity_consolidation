<#
.SYNOPSIS
    Day 1: Seeds peachtree.local with a realistic "acquired company" mess.

.DESCRIPTION
    Run on PTDC01 as a Peachtree Domain Admin right after the forest is promoted.
    Builds 5 OUs, 12 employees with employeeID and manager set, 6 groups,
    2 generic admin accounts, and 3 badly named service accounts with
    "password never expires" turned on and no owner.

    The mess is on purpose:
      - jsmith also exists in iamlab.local, which forces a naming collision on Day 3
      - admin and itadmin are shared, generic, and sit in Domain Admins (Day 6 vaults them)
      - sqlsvc, backup and reportsvc have no owner and never rotate (Day 6 fixes them)

    Everything it creates is exported to evidence\day1_peachtree_seed.csv.

.EXAMPLE
    .\01_Seed-Peachtree.ps1
#>
[CmdletBinding()]
param(
    [string]$EvidencePath = ".\evidence\day1_peachtree_seed.csv"
)

Import-Module ActiveDirectory -ErrorAction Stop

$domain   = Get-ADDomain
$domainDN = $domain.DistinguishedName
$dnsRoot  = $domain.DNSRoot
$password = Read-Host "Temporary password for every seeded account" -AsSecureString

# ---------- OUs ----------
foreach ($ouName in 'Ops', 'Finance', 'IT', 'Groups', 'ServiceAccounts') {
    $exists = Get-ADOrganizationalUnit -Filter "Name -eq '$ouName'" -SearchBase $domainDN -SearchScope OneLevel -ErrorAction SilentlyContinue
    if (-not $exists) {
        New-ADOrganizationalUnit -Name $ouName -Path $domainDN -ProtectedFromAccidentalDeletion $false
        Write-Host "Created OU $ouName" -ForegroundColor Green
    }
}

# ---------- Employees (managers first so the manager link works) ----------
$people = @(
    @{ Sam='dwalker';  First='Dana';    Last='Walker';  Dept='Ops';     Title='Operations Manager';  Id='PT1001'; Mgr=$null }
    @{ Sam='kpatel';   First='Kiran';   Last='Patel';   Dept='Finance'; Title='Finance Manager';     Id='PT1002'; Mgr=$null }
    @{ Sam='mreed';    First='Marcus';  Last='Reed';    Dept='IT';      Title='IT Manager';          Id='PT1003'; Mgr=$null }
    @{ Sam='jsmith';   First='Jordan';  Last='Smith';   Dept='Ops';     Title='Dispatcher';          Id='PT1004'; Mgr='dwalker' }
    @{ Sam='mlopez';   First='Maria';   Last='Lopez';   Dept='Ops';     Title='Dispatcher';          Id='PT1005'; Mgr='dwalker' }
    @{ Sam='tnguyen';  First='Tuan';    Last='Nguyen';  Dept='Ops';     Title='Warehouse Lead';      Id='PT1006'; Mgr='dwalker' }
    @{ Sam='bharris';  First='Bria';    Last='Harris';  Dept='Ops';     Title='Warehouse Associate'; Id='PT1007'; Mgr='dwalker' }
    @{ Sam='ljohnson'; First='Lena';    Last='Johnson'; Dept='Finance'; Title='AP Specialist';       Id='PT1008'; Mgr='kpatel' }
    @{ Sam='achen';    First='Alex';    Last='Chen';    Dept='Finance'; Title='AP Specialist';       Id='PT1009'; Mgr='kpatel' }
    @{ Sam='rcole';    First='Ray';     Last='Cole';    Dept='Finance'; Title='GL Accountant';       Id='PT1010'; Mgr='kpatel' }
    @{ Sam='cbrooks';  First='Casey';   Last='Brooks';  Dept='IT';      Title='Helpdesk Technician'; Id='PT1011'; Mgr='mreed' }
    @{ Sam='nfoster';  First='Nia';     Last='Foster';  Dept='IT';      Title='Systems Administrator'; Id='PT1012'; Mgr='mreed' }
)

$created = New-Object System.Collections.Generic.List[object]

foreach ($p in $people) {
    if (Get-ADUser -Filter "SamAccountName -eq '$($p.Sam)'" -ErrorAction SilentlyContinue) {
        Write-Host "Skipping $($p.Sam), already exists" -ForegroundColor Yellow
        continue
    }
    $params = @{
        Name                  = "$($p.First) $($p.Last)"
        GivenName             = $p.First
        Surname               = $p.Last
        DisplayName           = "$($p.First) $($p.Last)"
        SamAccountName        = $p.Sam
        UserPrincipalName     = "$($p.Sam)@$dnsRoot"
        EmployeeID            = $p.Id
        Department            = $p.Dept
        Title                 = $p.Title
        Company               = 'Peachtree Logistics'
        EmailAddress          = "$($p.First.ToLower()).$($p.Last.ToLower())@$dnsRoot"
        Path                  = "OU=$($p.Dept),$domainDN"
        AccountPassword       = $password
        Enabled               = $true
        ChangePasswordAtLogon = $false
    }
    if ($p.Mgr) { $params.Manager = $p.Mgr }
    New-ADUser @params
    $created.Add([pscustomobject]@{ Type='User'; Name=$p.Sam; EmployeeID=$p.Id; Department=$p.Dept; Detail=$p.Title })
    Write-Host "Created user $($p.Sam)" -ForegroundColor Green
}

# ---------- Groups ----------
$groups = [ordered]@{
    'PT_Ops_Dispatch'   = @('dwalker','jsmith','mlopez')
    'PT_Ops_Warehouse'  = @('dwalker','tnguyen','bharris')
    'PT_Finance_AP'     = @('kpatel','ljohnson','achen')
    'PT_Finance_GL'     = @('kpatel','rcole')
    'PT_IT_Helpdesk'    = @('mreed','cbrooks','nfoster')
    'PT_All_Staff'      = $people.Sam
}

foreach ($g in $groups.Keys) {
    if (-not (Get-ADGroup -Filter "Name -eq '$g'" -ErrorAction SilentlyContinue)) {
        New-ADGroup -Name $g -GroupScope Global -GroupCategory Security -Path "OU=Groups,$domainDN"
    }
    Add-ADGroupMember -Identity $g -Members $groups[$g]
    $created.Add([pscustomobject]@{ Type='Group'; Name=$g; EmployeeID=''; Department=''; Detail=($groups[$g] -join ';') })
    Write-Host "Group $g has $($groups[$g].Count) members" -ForegroundColor Green
}

# ---------- Generic admin accounts (the Day 6 PAM problem) ----------
foreach ($adm in 'admin', 'itadmin') {
    if (-not (Get-ADUser -Filter "SamAccountName -eq '$adm'" -ErrorAction SilentlyContinue)) {
        New-ADUser -Name $adm -SamAccountName $adm -UserPrincipalName "$adm@$dnsRoot" `
            -Path "OU=IT,$domainDN" -AccountPassword $password -Enabled $true `
            -Description 'Shared admin account. Password is in the IT share.'
        Add-ADGroupMember -Identity 'Domain Admins' -Members $adm
        $created.Add([pscustomobject]@{ Type='PrivilegedAccount'; Name=$adm; EmployeeID=''; Department='IT'; Detail='Domain Admins, shared' })
        Write-Host "Created shared admin $adm" -ForegroundColor Green
    }
}

# ---------- Service accounts (the Day 6 NHI problem) ----------
$serviceAccounts = @(
    @{ Sam='sqlsvc';    Spn='MSSQLSvc/ptsql01.peachtree.local:1433' }
    @{ Sam='backup';    Spn=$null }
    @{ Sam='reportsvc'; Spn=$null }
)
foreach ($s in $serviceAccounts) {
    if (-not (Get-ADUser -Filter "SamAccountName -eq '$($s.Sam)'" -ErrorAction SilentlyContinue)) {
        New-ADUser -Name $s.Sam -SamAccountName $s.Sam -UserPrincipalName "$($s.Sam)@$dnsRoot" `
            -Path "OU=ServiceAccounts,$domainDN" -AccountPassword $password -Enabled $true `
            -PasswordNeverExpires $true
        if ($s.Spn) { Set-ADUser -Identity $s.Sam -ServicePrincipalNames @{ Add = $s.Spn } }
        $created.Add([pscustomobject]@{ Type='ServiceAccount'; Name=$s.Sam; EmployeeID=''; Department=''; Detail='No owner, password never expires' })
        Write-Host "Created service account $($s.Sam)" -ForegroundColor Green
    }
}

# ---------- Evidence ----------
$evidenceDir = Split-Path -Parent $EvidencePath
if ($evidenceDir -and -not (Test-Path $evidenceDir)) { New-Item -ItemType Directory -Path $evidenceDir | Out-Null }
$created | Export-Csv -Path $EvidencePath -NoTypeInformation
Write-Host "`nSeeded $($created.Count) objects. Evidence written to $EvidencePath" -ForegroundColor Cyan
