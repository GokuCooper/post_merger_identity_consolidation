<#
.SYNOPSIS
    Day 2: Generates a unique OID for the custom dknSourceCompany schema attribute.

.DESCRIPTION
    Every schema attribute needs a globally unique Object Identifier (OID).
    This uses the Microsoft documented method: a fixed prefix plus numbers
    derived from a new GUID. Copy the OID it prints into the Active Directory
    Schema snap in when you create the attribute.

    The OID is also written to evidence\day2_schema_oid.txt so you have a record
    of exactly what you added to the schema (schema changes are permanent).

.EXAMPLE
    .\03_New-SchemaOID.ps1
#>
[CmdletBinding()]
param(
    [string]$AttributeName = 'dknSourceCompany',
    [string]$EvidencePath  = '.\evidence\day2_schema_oid.txt'
)

$prefix = '1.2.840.113556.1.8000.2554'
$guid   = [System.Guid]::NewGuid().ToString()

$parts = @(
    [UInt64]::Parse($guid.Substring(0, 4),  'AllowHexSpecifier')
    [UInt64]::Parse($guid.Substring(4, 4),  'AllowHexSpecifier')
    [UInt64]::Parse($guid.Substring(9, 4),  'AllowHexSpecifier')
    [UInt64]::Parse($guid.Substring(14, 4), 'AllowHexSpecifier')
    [UInt64]::Parse($guid.Substring(19, 4), 'AllowHexSpecifier')
    [UInt64]::Parse($guid.Substring(24, 6), 'AllowHexSpecifier')
    [UInt64]::Parse($guid.Substring(30, 6), 'AllowHexSpecifier')
)

$oid = '{0}.{1}.{2}.{3}.{4}.{5}.{6}.{7}' -f $prefix, $parts[0], $parts[1], $parts[2], $parts[3], $parts[4], $parts[5], $parts[6]

$record = @"
Attribute     : $AttributeName
OID           : $oid
Syntax        : Unicode String (single value)
Added to class: user
Generated     : $(Get-Date -Format s) on $env:COMPUTERNAME
Note          : Schema changes cannot be deleted, only made defunct. DC snapshot taken first.
"@

$dir = Split-Path -Parent $EvidencePath
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
$record | Set-Content -Path $EvidencePath
Write-Output $record
