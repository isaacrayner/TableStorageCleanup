# WAD Cleanup Scripts - User Guide

This folder contains PowerShell scripts for safely decommissioning Windows Azure Diagnostics (WAD) infrastructure as part of the Azure Diagnostics Modernisation project.

## 📋 Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Scripts](#scripts)
  - [Remove-WadExtension.ps1](#remove-wadextensionps1)
  - [Delete-WadTables.ps1](#delete-wadtablesps1)
- [Recommended Workflow](#recommended-workflow)
- [Multi-Tenant / Multi-Subscription Scenarios](#multi-tenant--multi-subscription-scenarios)
- [Troubleshooting](#troubleshooting)

---

## Overview

These scripts help you:
1. **Remove WAD extensions** from Azure VMs (stops data collection)
2. **Delete WAD tables** from Azure Storage (reclaims storage and reduces costs)

**Cost Benefit:** Complete table deletion is a single API call per table vs. millions of transactions for entity-by-entity deletion, saving significant transaction costs.

---

## Prerequisites

### Required Modules
```powershell
# Install Azure PowerShell modules (if not already installed)
Install-Module -Name Az.Accounts -Force -AllowClobber
Install-Module -Name Az.Compute -Force -AllowClobber
Install-Module -Name Az.Storage -Force -AllowClobber
Install-Module -Name Az.Resources -Force -AllowClobber
```

### Required Permissions

| Task | Required RBAC Role |
|------|-------------------|
| Remove WAD extensions | `Virtual Machine Contributor` or `Contributor` |
| Delete storage tables | `Storage Account Contributor` or `Storage Table Data Contributor` |
| List VMs/Storage | `Reader` (minimum) |

### Connect to Azure
```powershell
# Connect to Azure
Connect-AzAccount

# Or connect to specific tenant
Connect-AzAccount -TenantId "your-tenant-id"
```

---

## Scripts

### Remove-WadExtension.ps1

**Purpose:** Discovers and removes the Windows Azure Diagnostics extension from Azure VMs.

#### Key Features
- ✅ Discovery mode to see what you have
- ✅ Multi-subscription support (`-AllSubscriptions`)
- ✅ Filtering by resource group, VM name pattern, or tags
- ✅ WhatIf mode for safe testing
- ✅ Automatic CSV export of results
- ✅ Supports both Windows and Linux diagnostics extensions

#### Basic Usage

```powershell
# 1. Discovery - see what VMs have WAD installed
.\Remove-WadExtension.ps1 -DiscoveryOnly

# 2. Test run - see what would be removed
.\Remove-WadExtension.ps1 -WhatIf

# 3. Actual removal - interactive with confirmation
.\Remove-WadExtension.ps1

# 4. Remove across ALL subscriptions (requires confirmation)
.\Remove-WadExtension.ps1 -AllSubscriptions
```

#### Advanced Filtering

```powershell
# Filter by resource group
.\Remove-WadExtension.ps1 -ResourceGroupName "rg-production" -DiscoveryOnly

# Filter by VM name pattern
.\Remove-WadExtension.ps1 -VMNamePattern "web-*" -DiscoveryOnly

# Filter by tags
.\Remove-WadExtension.ps1 -TagName "Environment" -TagValue "Production" -DiscoveryOnly

# Combine filters
.\Remove-WadExtension.ps1 -ResourceGroupName "rg-prod" -VMNamePattern "web-*" -WhatIf
```

#### Parameters Reference

| Parameter | Description | Example |
|-----------|-------------|---------|
| `-DiscoveryOnly` | List VMs with WAD without removing | `-DiscoveryOnly` |
| `-WhatIf` | Test run without making changes | `-WhatIf` |
| `-Force` | Skip confirmation prompts | `-Force` |
| `-AllSubscriptions` | Process all accessible subscriptions | `-AllSubscriptions` |
| `-SubscriptionId` | Target specific subscription | `-SubscriptionId "guid"` |
| `-ResourceGroupName` | Filter to specific resource group | `-ResourceGroupName "rg-prod"` |
| `-VMNamePattern` | Filter VMs by name (wildcards supported) | `-VMNamePattern "web-*"` |
| `-TagName` / `-TagValue` | Filter VMs by tags | `-TagName "Env" -TagValue "Prod"` |

#### Output
- Console output with color-coded logging
- CSV export: `WAD_Discovery_YYYYMMDD_HHMMSS.csv` or `WAD_Removal_Results_YYYYMMDD_HHMMSS.csv`

---

### Delete-WadTables.ps1

**Purpose:** Discovers and deletes WAD tables from Azure Storage accounts.

#### Key Features
- ✅ Multi-storage account support
- ✅ Automatic WAD table detection (tables starting with 'WAD*')
- ✅ Soft delete status checking
- ✅ WhatIf mode for safe testing
- ✅ Requires explicit "DELETE" confirmation
- ✅ Detailed logging and summary

#### Basic Usage

```powershell
# 1. Test run - see what would be deleted
.\Delete-WadTables.ps1 -StorageAccountNames @("diagstorage01", "diagstorage02") -WhatIf

# 2. Actual deletion - requires typing "DELETE" to confirm
.\Delete-WadTables.ps1 -StorageAccountNames @("diagstorage01", "diagstorage02")

# 3. Interactive mode - will prompt for storage account names
.\Delete-WadTables.ps1
```

#### Multi-Subscription Support

```powershell
# Process storage accounts in specific subscription
.\Delete-WadTables.ps1 -SubscriptionId "your-sub-id" -StorageAccountNames @("storage1", "storage2")
```

#### Parameters Reference

| Parameter | Description | Example |
|-----------|-------------|---------|
| `-StorageAccountNames` | Array of storage account names | `-StorageAccountNames @("sa1", "sa2")` |
| `-SubscriptionId` | Target specific subscription | `-SubscriptionId "guid"` |
| `-WhatIf` | Test run without deleting | `-WhatIf` |
| `-Force` | Skip confirmation (dangerous!) | `-Force` |

#### Safety Features
- Only deletes tables starting with `WAD*`
- Checks soft delete status (note: Table Storage doesn't support soft delete)
- Requires typing "DELETE" to confirm
- Shows summary before deletion

---

## Recommended Workflow

### Phase 1 & 2: Migration and Extension Removal (Day 1)

```powershell
# Step 1: Connect to Azure
Connect-AzAccount

# Step 2: Discovery - Find all VMs with WAD
.\Remove-WadExtension.ps1 -AllSubscriptions -DiscoveryOnly
# Review the CSV output

# Step 3: Test removal
.\Remove-WadExtension.ps1 -AllSubscriptions -WhatIf

# Step 4: Remove WAD extensions (interactive confirmation)
.\Remove-WadExtension.ps1 -AllSubscriptions

# Step 5: Wait 30-60 minutes for any in-flight writes to complete

# Step 6: Verify no new data in tables (check timestamps in Azure Portal)
```

### Phase 3: Table Deletion (Day 30+)

⚠️ **Wait 30 days after Phase 1 & 2** to ensure:
- New LAW-based logging is stable
- No issues reported with the new platform
- No compliance/audit requirements for historical data

```powershell
# Step 1: Connect to Azure
Connect-AzAccount

# Step 2: Test deletion
.\Delete-WadTables.ps1 -StorageAccountNames @("diagstorage01", "diagstorage02") -WhatIf

# Step 3: Delete tables (requires typing "DELETE")
.\Delete-WadTables.ps1 -StorageAccountNames @("diagstorage01", "diagstorage02")

# Step 4: Verify storage costs reduced (check Azure Portal after 24-48 hours)
```

---

## Multi-Tenant / Multi-Subscription Scenarios

### Scenario 1: Multiple Subscriptions, Single Tenant

```powershell
# Option A: Process all at once
Connect-AzAccount -TenantId "your-tenant-id"
.\Remove-WadExtension.ps1 -AllSubscriptions -DiscoveryOnly

# Option B: Process one by one
$subscriptions = @("sub-id-1", "sub-id-2", "sub-id-3")
foreach ($subId in $subscriptions) {
    Write-Host "Processing subscription: $subId" -ForegroundColor Cyan
    .\Remove-WadExtension.ps1 -SubscriptionId $subId
}
```

### Scenario 2: Multiple Tenants (Requires Multiple Connections)

```powershell
# Tenant 1
Connect-AzAccount -TenantId "tenant-1-id"
.\Remove-WadExtension.ps1 -AllSubscriptions -DiscoveryOnly
.\Remove-WadExtension.ps1 -AllSubscriptions

# Disconnect and reconnect to next tenant
Disconnect-AzAccount

# Tenant 2
Connect-AzAccount -TenantId "tenant-2-id"
.\Remove-WadExtension.ps1 -AllSubscriptions -DiscoveryOnly
.\Remove-WadExtension.ps1 -AllSubscriptions

# Repeat for each tenant...
```

### Scenario 3: Batch Processing with Automation

```powershell
# Create a configuration file
$config = @{
    Tenants = @(
        @{
            TenantId = "tenant-1-id"
            StorageAccounts = @("diagstorage01", "diagstorage02")
        },
        @{
            TenantId = "tenant-2-id"
            StorageAccounts = @("diagstorage03", "diagstorage04")
        }
    )
}

# Process each tenant
foreach ($tenant in $config.Tenants) {
    Write-Host "Processing Tenant: $($tenant.TenantId)" -ForegroundColor Magenta
    
    # Connect to tenant
    Connect-AzAccount -TenantId $tenant.TenantId
    
    # Remove WAD extensions
    .\Remove-WadExtension.ps1 -AllSubscriptions
    
    # Wait before table deletion
    Write-Host "Waiting 30 days before table deletion..." -ForegroundColor Yellow
    
    # ... (Wait 30 days) ...
    
    # Delete tables
    foreach ($storageAccount in $tenant.StorageAccounts) {
        .\Delete-WadTables.ps1 -StorageAccountNames @($storageAccount)
    }
    
    Disconnect-AzAccount
}
```

---

## Troubleshooting

### Issue: "Not connected to Azure"
**Solution:**
```powershell
Connect-AzAccount
# Or specify tenant
Connect-AzAccount -TenantId "your-tenant-id"
```

### Issue: "Storage account not found"
**Solution:**
- Verify storage account name is correct (case-sensitive)
- Ensure you're in the correct subscription: `Get-AzContext`
- Switch subscription: `Set-AzContext -SubscriptionId "sub-id"`

### Issue: "Access denied" or "Forbidden"
**Solution:**
- Verify you have required RBAC permissions (see Prerequisites)
- Check if MFA or Conditional Access policies are blocking

### Issue: Extension removal fails on some VMs
**Solution:**
- Check VM power state (VM should be running)
- Review error message in console output
- Check CSV export for detailed failure reasons
- Try removing manually: `Remove-AzVMExtension -ResourceGroupName "rg" -VMName "vm" -Name "extension-name" -Force`

### Issue: Table deletion shows "Unable to determine size"
**Solution:**
- This is normal for very large tables (1B+ rows)
- Deletion will still work correctly
- Table size estimation is optional and may timeout

### Issue: Script hangs during VM scanning
**Solution:**
- Some VMs may be slow to respond
- Press `Ctrl+C` to cancel if needed
- Use filtering to reduce scope: `-ResourceGroupName` or `-VMNamePattern`

### Issue: Multiple tenants - switching contexts
**Solution:**
```powershell
# Clear current session
Disconnect-AzAccount

# Connect to new tenant
Connect-AzAccount -TenantId "new-tenant-id"

# Verify context
Get-AzContext
```

---

## Cost Savings Calculation

### Before (Entity-by-Entity Deletion)
- 1.5 billion entities to delete
- 1.5 billion read operations (to query old entities)
- Total: 3 billion operations = 300,000 units @ £0.0003 = **£90**

### After (Table Deletion)
- 8 tables × 1 delete operation = 8 operations
- Total: 8 operations < 10,000 = **£0.0003** (1 unit)

**Savings: £89.9997 per cleanup** 💰

Plus ongoing storage cost savings once tables are deleted!

---

## Support

**Project:** Azure Diagnostics Modernisation  
**Date:** December 2025

For issues or questions:
1. Review this README and troubleshooting section
2. Check Azure Portal for resource state
3. Review script output and CSV exports
4. Open an issue or review execution logs

---

## Important Reminders

⚠️ **Before Running Scripts:**
1. ✅ Migrate to Log Analytics Workspace (LAW)
2. ✅ Deploy Azure Monitor Agent (AMA) with Data Collection Rules (DCR)
3. ✅ Validate new logging is working correctly
4. ✅ Configure 90-day retention policy in LAW
5. ✅ Confirm no compliance requirements for historical WAD data

⚠️ **After Removing Extensions:**
1. ✅ Wait 30-60 minutes before checking tables
2. ✅ Verify no new entities in WAD tables
3. ✅ Wait 30 days validation period
4. ✅ Then proceed with table deletion

⚠️ **Table Deletion is Permanent:**
- No soft delete for Table Storage
- Cannot be undone
- Ensure validation period complete before deletion
