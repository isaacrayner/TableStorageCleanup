<#
.SYNOPSIS
    Safely deletes Windows Azure Diagnostics (WAD) tables from Azure Storage accounts.

.DESCRIPTION
    This script automatically discovers all storage accounts in a subscription,
    finds WAD-related tables, and offers to delete them.
    It includes safety checks to ensure:
    - Only WAD tables are deleted (tables starting with 'WAD')
    - All storage accounts in the subscription are scanned
    - Confirmation is required before executing deletions
    - Detailed logging of all operations

.PARAMETER SubscriptionId
    Azure subscription ID. If not provided, uses the current subscription context.

.PARAMETER StorageAccountNames
    Optional: Array of specific storage account names to process. 
    If not provided, will scan ALL storage accounts in the subscription.

.PARAMETER WhatIf
    Shows what would be deleted without actually deleting anything.

.PARAMETER Force
    Skips confirmation prompts (use with caution).

.EXAMPLE
    .\Delete-WadTables.ps1
    Scans all storage accounts in the current subscription

.EXAMPLE
    .\Delete-WadTables.ps1 -SubscriptionId "12345678-1234-1234-1234-123456789012"
    Scans all storage accounts in the specified subscription

.EXAMPLE
    .\Delete-WadTables.ps1 -StorageAccountNames @("diagstorage01", "diagstorage02")
    Scans only specific storage accounts

.EXAMPLE
    .\Delete-WadTables.ps1 -WhatIf
    Shows what would be deleted without actually deleting

.NOTES
    Date: December 2025
    Project: Azure Diagnostics Modernisation
    
    IMPORTANT: This script permanently deletes tables. Ensure you have:
    1. Migrated to Log Analytics Workspace (LAW)
    2. Decommissioned the WAD extension
    3. Waited the appropriate validation period (30 days recommended)
    4. Confirmed no processes are writing to these tables
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [string[]]$StorageAccountNames,
    
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory = $false)]
    [switch]$Force
)

# Strict mode for better error handling
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#region Functions

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        'Info'    { 'Cyan' }
        'Success' { 'Green' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
    }
    
    Write-Host "[$timestamp] " -NoNewline -ForegroundColor Gray
    Write-Host "[$Level] " -NoNewline -ForegroundColor $color
    Write-Host $Message
}

function Test-AzureConnection {
    Write-Log "Checking Azure connection..." -Level Info
    
    try {
        $context = Get-AzContext
        if ($null -eq $context) {
            Write-Log "Not connected to Azure. Please run 'Connect-AzAccount' first." -Level Error
            return $false
        }
        
        Write-Log "Connected to Azure as: $($context.Account.Id)" -Level Success
        Write-Log "Subscription: $($context.Subscription.Name) ($($context.Subscription.Id))" -Level Info
        return $true
    }
    catch {
        Write-Log "Failed to get Azure context: $_" -Level Error
        return $false
    }
}

function Get-StorageAccountKey {
    param(
        [string]$StorageAccountName,
        [string]$ResourceGroupName
    )
    
    try {
        $keys = Get-AzStorageAccountKey -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
        return $keys[0].Value
    }
    catch {
        Write-Log "Failed to get storage account key for '$StorageAccountName': $_" -Level Error
        throw
    }
}

function Test-SoftDeleteStatus {
    param(
        [Microsoft.Azure.Commands.Management.Storage.Models.PSStorageAccount]$StorageAccount
    )
    
    Write-Log "Checking soft delete status for '$($StorageAccount.StorageAccountName)'..." -Level Info
    
    # Note: As of late 2024, Azure Table Storage does not support soft delete
    # This is a blob-only feature. Tables are deleted immediately and permanently.
    # Keeping this function for future compatibility if the feature is added.
    
    try {
        if ($StorageAccount.PSObject.Properties['EnableBlobDeleteRetentionPolicy'] -and 
            $StorageAccount.EnableBlobDeleteRetentionPolicy) {
            Write-Log "INFO: Blob soft delete is enabled (does not affect tables)" -Level Info
        }
    }
    catch {
        # Property doesn't exist or can't be accessed - this is fine
    }
    
    Write-Log "Table Storage does not support soft delete - deletions are immediate and permanent." -Level Warning
    return $false
}

function Get-WadTables {
    param(
        [string]$StorageAccountName,
        [string]$StorageAccountKey
    )
    
    Write-Log "Discovering WAD tables in '$StorageAccountName'..." -Level Info
    
    try {
        $ctx = New-AzStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $StorageAccountKey
        $allTables = Get-AzStorageTable -Context $ctx -ErrorAction Stop
        
        # Filter for WAD tables only
        $wadTables = $allTables | Where-Object { $_.Name -like 'WAD*' }
        
        if ($wadTables) {
            Write-Log "Found $($wadTables.Count) WAD table(s):" -Level Success
            foreach ($table in $wadTables) {
                Write-Log "  - $($table.Name)" -Level Info
            }
        }
        else {
            Write-Log "No WAD tables found in this storage account." -Level Warning
        }
        
        return $wadTables
    }
    catch {
        Write-Log "Failed to retrieve tables from '$StorageAccountName': $_" -Level Error
        throw
    }
}

function Get-TableEntityCount {
    param(
        [string]$StorageAccountName,
        [string]$StorageAccountKey,
        [string]$TableName
    )
    
    try {
        $ctx = New-AzStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $StorageAccountKey
        $table = Get-AzStorageTable -Name $TableName -Context $ctx
        
        # Note: Getting exact count can be expensive for large tables
        # This is a rough estimate by querying a small sample
        $cloudTable = $table.CloudTable
        
        Write-Log "  Checking table size (this may take a moment)..." -Level Info
        
        # Try to get a rough count (limited to avoid timeout)
        $query = New-Object Microsoft.Azure.Cosmos.Table.TableQuery
        $query.TakeCount = 1000
        
        try {
            $entities = $cloudTable.ExecuteQuery($query)
            $sampleCount = ($entities | Measure-Object).Count
            
            if ($sampleCount -ge 1000) {
                return "1000+ entities"
            }
            else {
                return "$sampleCount entities"
            }
        }
        catch {
            return "Unable to determine (large table)"
        }
    }
    catch {
        return "Unknown"
    }
}

function Remove-WadTable {
    param(
        [string]$StorageAccountName,
        [string]$StorageAccountKey,
        [string]$TableName,
        [switch]$WhatIf
    )
    
    try {
        if ($WhatIf) {
            Write-Log "WHATIF: Would delete table '$TableName' from '$StorageAccountName'" -Level Warning
            return $true
        }
        
        $ctx = New-AzStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $StorageAccountKey
        Remove-AzStorageTable -Name $TableName -Context $ctx -Force -ErrorAction Stop
        
        Write-Log "Successfully deleted table: $TableName" -Level Success
        return $true
    }
    catch {
        Write-Log "Failed to delete table '$TableName': $_" -Level Error
        return $false
    }
}

function Confirm-Deletion {
    param(
        [int]$TotalTables,
        [string[]]$StorageAccountNames
    )
    
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "WARNING: PERMANENT DELETION" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "You are about to permanently delete:" -ForegroundColor Yellow
    Write-Host "  - $TotalTables WAD table(s)" -ForegroundColor Yellow
    Write-Host "  - Across $($StorageAccountNames.Count) storage account(s)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "This action CANNOT be undone." -ForegroundColor Red
    Write-Host ""
    Write-Host "Please confirm:" -ForegroundColor Yellow
    Write-Host "  1. You have migrated to Log Analytics Workspace" -ForegroundColor White
    Write-Host "  2. You have decommissioned the WAD extension" -ForegroundColor White
    Write-Host "  3. You have waited the validation period (30 days recommended)" -ForegroundColor White
    Write-Host "  4. No processes are writing to these tables" -ForegroundColor White
    Write-Host ""
    
    $confirmation = Read-Host "Type 'DELETE' to confirm deletion"
    
    return ($confirmation -eq 'DELETE')
}

#endregion

#region Main Script

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "WAD Table Deletion Script" -ForegroundColor Cyan
Write-Host "Azure Diagnostics Modernisation" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Check Azure connection
if (-not (Test-AzureConnection)) {
    Write-Log "Please connect to Azure using 'Connect-AzAccount' and try again." -Level Error
    exit 1
}

# Set subscription if provided
if ($SubscriptionId) {
    Write-Log "Setting subscription context to: $SubscriptionId" -Level Info
    try {
        Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
        Write-Log "Subscription context set successfully." -Level Success
    }
    catch {
        Write-Log "Failed to set subscription context: $_" -Level Error
        exit 1
    }
}

# Get storage account names if not provided
if (-not $StorageAccountNames -or $StorageAccountNames.Count -eq 0) {
    Write-Log "No specific storage accounts provided - discovering all storage accounts in subscription..." -Level Info
    
    try {
        $allStorageAccounts = Get-AzStorageAccount -ErrorAction Stop
        
        if (-not $allStorageAccounts -or $allStorageAccounts.Count -eq 0) {
            Write-Log "No storage accounts found in the current subscription." -Level Warning
            exit 0
        }
        
        $StorageAccountNames = $allStorageAccounts | ForEach-Object { $_.StorageAccountName }
        Write-Log "Found $($StorageAccountNames.Count) storage account(s) in subscription." -Level Success
        
        foreach ($sa in $StorageAccountNames) {
            Write-Log "  - $sa" -Level Info
        }
    }
    catch {
        Write-Log "Failed to retrieve storage accounts: $_" -Level Error
        exit 1
    }
}

Write-Log "Processing $($StorageAccountNames.Count) storage account(s)..." -Level Info

# Discovery phase
$discoveredTables = @()

foreach ($storageAccountName in $StorageAccountNames) {
    Write-Host ""
    Write-Log "Processing storage account: $storageAccountName" -Level Info
    Write-Log "----------------------------------------" -Level Info
    
    try {
        # Find the storage account
        Write-Log "Locating storage account in Azure..." -Level Info
        $storageAccount = Get-AzStorageAccount | Where-Object { $_.StorageAccountName -eq $storageAccountName }
        
        if (-not $storageAccount) {
            Write-Log "Storage account '$storageAccountName' not found in current subscription." -Level Error
            continue
        }
        
        Write-Log "Found in resource group: $($storageAccount.ResourceGroupName)" -Level Success
        
        # Check soft delete status
        Test-SoftDeleteStatus -StorageAccount $storageAccount
        
        # Get storage account key
        $storageAccountKey = Get-StorageAccountKey -StorageAccountName $storageAccountName -ResourceGroupName $storageAccount.ResourceGroupName
        
        # Discover WAD tables
        $wadTables = Get-WadTables -StorageAccountName $storageAccountName -StorageAccountKey $storageAccountKey
        
        if ($wadTables) {
            foreach ($table in $wadTables) {
                $discoveredTables += [PSCustomObject]@{
                    StorageAccount = $storageAccountName
                    ResourceGroup  = $storageAccount.ResourceGroupName
                    TableName      = $table.Name
                    Key            = $storageAccountKey
                }
            }
        }
    }
    catch {
        Write-Log "Error processing storage account '$storageAccountName': $_" -Level Error
        continue
    }
}

# Summary
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "DISCOVERY SUMMARY" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Log "Total WAD tables discovered: $($discoveredTables.Count)" -Level Info

if ($discoveredTables.Count -eq 0) {
    Write-Log "No WAD tables found. Exiting." -Level Warning
    exit 0
}

# Group by storage account for summary
$groupedTables = $discoveredTables | Group-Object -Property StorageAccount
foreach ($group in $groupedTables) {
    Write-Host ""
    Write-Host "Storage Account: $($group.Name)" -ForegroundColor White
    foreach ($table in $group.Group) {
        Write-Host "  - $($table.TableName)" -ForegroundColor Gray
    }
}

# Confirmation (unless WhatIf or Force)
Write-Host ""

if ($WhatIfPreference) {
    Write-Log "Running in WhatIf mode - no deletions will be performed." -Level Warning
    $proceed = $true
}
elseif ($Force) {
    Write-Log "Force mode enabled - skipping confirmation." -Level Warning
    $proceed = $true
}
else {
    $proceed = Confirm-Deletion -TotalTables $discoveredTables.Count -StorageAccountNames $StorageAccountNames
}

if (-not $proceed) {
    Write-Log "Deletion cancelled by user." -Level Warning
    exit 0
}

# Deletion phase
Write-Host ""
Write-Host "========================================" -ForegroundColor Red
Write-Host "DELETION PHASE" -ForegroundColor Red
Write-Host "========================================" -ForegroundColor Red
Write-Host ""

$deletionResults = @{
    Success = 0
    Failed  = 0
    Total   = $discoveredTables.Count
}

foreach ($table in $discoveredTables) {
    Write-Log "Deleting '$($table.TableName)' from '$($table.StorageAccount)'..." -Level Info
    
    $success = Remove-WadTable `
        -StorageAccountName $table.StorageAccount `
        -StorageAccountKey $table.Key `
        -TableName $table.TableName `
        -WhatIf:$WhatIfPreference
    
    if ($success) {
        $deletionResults.Success++
    }
    else {
        $deletionResults.Failed++
    }
    
    Start-Sleep -Milliseconds 500  # Brief pause between deletions
}

# Final summary
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "FINAL SUMMARY" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Log "Total tables processed: $($deletionResults.Total)" -Level Info
Write-Log "Successfully deleted: $($deletionResults.Success)" -Level Success
Write-Log "Failed deletions: $($deletionResults.Failed)" -Level $(if ($deletionResults.Failed -gt 0) { 'Error' } else { 'Info' })
Write-Host ""

if ($WhatIfPreference) {
    Write-Log "WhatIf mode - no actual deletions were performed." -Level Warning
}
elseif ($deletionResults.Success -gt 0) {
    Write-Log "Deletion completed successfully!" -Level Success
    Write-Log "Storage space will be reclaimed and costs reduced." -Level Success
}

Write-Host ""
Write-Log "Script completed." -Level Info

#endregion
