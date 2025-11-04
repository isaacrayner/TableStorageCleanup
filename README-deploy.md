# Deploying TableStorageCleanup Azure Function to Azure# Deploying TableStorageCleanup to Azure# Deploying TableStorageCleanup Azure Function to Azure



This guide explains how to deploy the TableStorageCleanup Azure Function to Azure so it runs automatically in the cloud.



## PrerequisitesThis guide explains how to deploy the TableStorageCleanup Azure Function to Azure using best practices and the latest Azure Functions deployment patterns.This guide explains how to deploy the TableStorageCleanup Azure Function to Azure so it runs automatically in the cloud.



- An Azure subscription

- [Azure CLI](https://docs.microsoft.com/cli/azure/install-azure-cli) installed

- [Azure Functions Core Tools](https://docs.microsoft.com/azure/azure-functions/functions-run-local) installed## Prerequisites## Prerequisites

- [.NET SDK](https://dotnet.microsoft.com/download) installed

- The function app code (this folder)



## Deployment Options- Azure subscription with appropriate permissions- An Azure subscription



### Option 1: Quick Deploy with Azure Functions Core Tools (Recommended for Dev/Test)- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) installed and configured- [Azure CLI](https://docs.microsoft.com/cli/azure/install-azure-cli) installed



This is the fastest method for deploying to an existing Function App.- [Azure Functions Core Tools v4](https://learn.microsoft.com/azure/azure-functions/functions-run-local) installed  - [Azure Functions Core Tools](https://docs.microsoft.com/azure/azure-functions/functions-run-local) installed



#### Step 1: Sign in to Azure- Project built successfully (`dotnet build` runs without errors)- [.NET SDK](https://dotnet.microsoft.com/download) installed



```pwsh- The function app code (this folder)

az login

az account set --subscription "<your-subscription-id-or-name>"## Deployment Options

```

## 1. Sign in to Azure

#### Step 2: Deploy to Existing Function App

### Option 1: Quick Deploy with Azure Functions Core Tools (Recommended for Dev/Test)

```pwsh

func azure functionapp publish <your-function-app-name>```pwsh

```

This is the fastest method for deploying to an existing Function App.az login

This command will:

- Build your project in Release mode```

- Package the compiled code

- Deploy to the specified Function App#### Step 1: Sign in to Azure

- Update application settings if using `--publish-local-settings`

## 2. Create a Resource Group (if needed)

### Option 2: Full Infrastructure Deployment with Azure CLI

```pwsh

Use this method to create all resources from scratch or for production deployments.

az login```pwsh

#### Step 1: Set Variables

az account set --subscription "<your-subscription-id-or-name>"az group create --name myResourceGroup --location westeurope

```pwsh

$resourceGroup = "rg-tablecleanup-prod"``````

$location = "westeurope"

$storageAccount = "sttablecleanupprod"  # must be globally unique

$functionApp = "func-tablecleanup-prod"

$appInsights = "appi-tablecleanup-prod"#### Step 2: Deploy to Existing Function App## 3. Create a Storage Account (for the function app itself)

```



#### Step 2: Create Resource Group

```pwsh```pwsh

```pwsh

az group create `func azure functionapp publish <your-function-app-name>az storage account create --name mystorageacctfunc --location westeurope --resource-group myResourceGroup --sku Standard_LRS

  --name $resourceGroup `

  --location $location``````

```



#### Step 3: Create Storage Account (for Function App runtime)

This command will:## 4. Create a Function App

```pwsh

az storage account create `- Build your project in Release mode

  --name $storageAccount `

  --location $location `- Package the compiled code```pwsh

  --resource-group $resourceGroup `

  --sku Standard_LRS `- Deploy to the specified Function Appaz functionapp create --resource-group myResourceGroup --consumption-plan-location westeurope --runtime dotnet --functions-version 4 --name my-tablecleanup-func --storage-account mystorageacctfunc

  --kind StorageV2

```- Update application settings if using `--publish-local-settings````



#### Step 4: Create Application Insights



```pwsh### Option 2: Full Infrastructure Deployment with Azure CLI## 5. Configure Application Settings

az monitor app-insights component create `

  --app $appInsights `

  --location $location `

  --resource-group $resourceGroup `Use this method to create all resources from scratch or for production deployments.Set your 8 storage account connection strings and other settings as app settings:

  --application-type web

```



Get the instrumentation key:#### Step 1: Set Variables```pwsh

```pwsh

$instrumentationKey = az monitor app-insights component show `az functionapp config appsettings set --name my-tablecleanup-func --resource-group myResourceGroup --settings \

  --app $appInsights `

  --resource-group $resourceGroup ````pwsh  STORAGE_ACCOUNT_1="<conn-string-1>" \

  --query instrumentationKey `

  --output tsv$resourceGroup = "rg-tablecleanup-prod"  STORAGE_ACCOUNT_2="<conn-string-2>" \

```

$location = "westeurope"  STORAGE_ACCOUNT_3="<conn-string-3>" \

#### Step 5: Create Function App (Flex Consumption - Recommended)

$storageAccount = "sttablecleanupprod"  # must be globally unique  STORAGE_ACCOUNT_4="<conn-string-4>" \

**Important**: Following Azure Functions best practices, use Flex Consumption (FC1) plan for cost-efficiency and auto-scaling.

$functionApp = "func-tablecleanup-prod"  STORAGE_ACCOUNT_5="<conn-string-5>" \

```pwsh

az functionapp create `$appInsights = "appi-tablecleanup-prod"  STORAGE_ACCOUNT_6="<conn-string-6>" \

  --name $functionApp `

  --storage-account $storageAccount ````  STORAGE_ACCOUNT_7="<conn-string-7>" \

  --resource-group $resourceGroup `

  --runtime dotnet-isolated `  STORAGE_ACCOUNT_8="<conn-string-8>" \

  --runtime-version 8 `

  --functions-version 4 `#### Step 2: Create Resource Group  RETENTION_DAYS=90 \

  --os-type Linux `

  --flexconsumption-location $location  TIMER_SCHEDULE="0 0 3 * * *"

```

```pwsh```

**Alternative: Elastic Premium Plan** (if Flex Consumption is not available):

```pwshaz group create `

# Create App Service Plan

az functionapp plan create `  --name $resourceGroup `## 6. Publish the Function to Azure

  --name "plan-$functionApp" `

  --resource-group $resourceGroup `  --location $location

  --location $location `

  --sku EP1 ```````pwsh

  --is-linux

dotnet publish -c Release

# Create Function App on Elastic Premium

az functionapp create `#### Step 3: Create Storage Account (for Function App runtime)func azure functionapp publish my-tablecleanup-func

  --name $functionApp `

  --storage-account $storageAccount ````

  --plan "plan-$functionApp" `

  --resource-group $resourceGroup ````pwsh

  --runtime dotnet-isolated `

  --runtime-version 8 `az storage account create `## 7. Monitor and Logs

  --functions-version 4 `

  --os-type Linux  --name $storageAccount `

```

  --location $location `- Go to the Azure Portal > your Function App > Monitor to view logs and invocations.

#### Step 6: Configure Application Settings

  --resource-group $resourceGroup `- You can also stream logs live:

Set all required configuration values. Add as many `STORAGE_ACCOUNT_*` settings as needed:

  --sku Standard_LRS `

```pwsh

az functionapp config appsettings set `  --kind StorageV2```pwsh

  --name $functionApp `

  --resource-group $resourceGroup ````func azure functionapp logstream my-tablecleanup-func

  --settings `

    "APPINSIGHTS_INSTRUMENTATIONKEY=$instrumentationKey" ````

    "APPLICATIONINSIGHTS_CONNECTION_STRING=InstrumentationKey=$instrumentationKey" `

    "STORAGE_ACCOUNT_1=DefaultEndpointsProtocol=https;AccountName=<account1>;AccountKey=<key1>;EndpointSuffix=core.windows.net" `#### Step 4: Create Application Insights

    "STORAGE_ACCOUNT_2=DefaultEndpointsProtocol=https;AccountName=<account2>;AccountKey=<key2>;EndpointSuffix=core.windows.net" `

    "STORAGE_ACCOUNT_3=DefaultEndpointsProtocol=https;AccountName=<account3>;AccountKey=<key3>;EndpointSuffix=core.windows.net" `## Notes

    "RETENTION_DAYS=90" `

    "TIMER_SCHEDULE=0 0 3 * * *"```pwsh

```

az monitor app-insights component create `- The function will run on the schedule you set (default: daily at 3 AM UTC).

**Note:** The function dynamically discovers all settings starting with `STORAGE_ACCOUNT_`. You can add as many as needed (e.g., `STORAGE_ACCOUNT_1` through `STORAGE_ACCOUNT_100`). Empty values are automatically skipped.

  --app $appInsights `- You can update app settings or redeploy at any time.

**Security Note**: Never store connection strings in code or source control. For production, use:

- **Azure Key Vault** for sensitive configuration  --location $location `- For production, consider using Application Insights for advanced monitoring.

- **Managed Identity** to access storage accounts without connection strings

  --resource-group $resourceGroup `

#### Step 7: Deploy Function Code  --application-type web

```

```pwsh

func azure functionapp publish $functionAppGet the instrumentation key:

``````pwsh

$instrumentationKey = az monitor app-insights component show `

## Quick Deploy Example (Creating Everything from Scratch)  --app $appInsights `

  --resource-group $resourceGroup `

If you want to create all resources with minimal configuration:  --query instrumentationKey `

  --output tsv

### 1. Sign in to Azure```



```pwsh#### Step 5: Create Function App (Flex Consumption - Recommended)

az login

```**Important**: Following Azure Functions best practices, use Flex Consumption (FC1) plan for cost-efficiency and auto-scaling.



### 2. Create a Resource Group (if needed)```pwsh

az functionapp create `

```pwsh  --name $functionApp `

az group create --name myResourceGroup --location westeurope  --storage-account $storageAccount `

```  --resource-group $resourceGroup `

  --runtime dotnet-isolated `

### 3. Create a Storage Account (for the function app itself)  --runtime-version 8 `

  --functions-version 4 `

```pwsh  --os-type Linux `

az storage account create --name mystorageacctfunc --location westeurope --resource-group myResourceGroup --sku Standard_LRS  --flexconsumption-location $location

``````



### 4. Create a Function App**Alternative: Elastic Premium Plan** (if Flex Consumption is not available):

```pwsh

```pwsh# Create App Service Plan

az functionapp create --resource-group myResourceGroup --consumption-plan-location westeurope --runtime dotnet-isolated --functions-version 4 --name my-tablecleanup-func --storage-account mystorageacctfuncaz functionapp plan create `

```  --name "plan-$functionApp" `

  --resource-group $resourceGroup `

### 5. Configure Application Settings  --location $location `

  --sku EP1 `

Set your storage account connection strings and other settings as app settings. Add as many storage accounts as needed using the sequential naming pattern `STORAGE_ACCOUNT_1`, `STORAGE_ACCOUNT_2`, `STORAGE_ACCOUNT_3`, etc.:  --is-linux



```pwsh# Create Function App on Elastic Premium

az functionapp config appsettings set --name my-tablecleanup-func --resource-group myResourceGroup --settings `az functionapp create `

  STORAGE_ACCOUNT_1="<conn-string-1>" `  --name $functionApp `

  STORAGE_ACCOUNT_2="<conn-string-2>" `  --storage-account $storageAccount `

  STORAGE_ACCOUNT_3="<conn-string-3>" `  --plan "plan-$functionApp" `

  RETENTION_DAYS=90 `  --resource-group $resourceGroup `

  TIMER_SCHEDULE="0 0 3 * * *"  --runtime dotnet-isolated `

```  --runtime-version 8 `

  --functions-version 4 `

### 6. Publish the Function to Azure  --os-type Linux

```

```pwsh

dotnet publish -c Release#### Step 6: Configure Application Settings

func azure functionapp publish my-tablecleanup-func

```Set all required configuration values. Add as many `STORAGE_ACCOUNT_*` settings as needed:



### 7. Monitor and Logs```pwsh

az functionapp config appsettings set `

- Go to the Azure Portal > your Function App > Monitor to view logs and invocations.  --name $functionApp `

- You can also stream logs live:  --resource-group $resourceGroup `

  --settings `

```pwsh    "APPINSIGHTS_INSTRUMENTATIONKEY=$instrumentationKey" `

func azure functionapp logstream my-tablecleanup-func    "APPLICATIONINSIGHTS_CONNECTION_STRING=InstrumentationKey=$instrumentationKey" `

```    "STORAGE_ACCOUNT_1=DefaultEndpointsProtocol=https;AccountName=<account1>;AccountKey=<key1>;EndpointSuffix=core.windows.net" `

    "STORAGE_ACCOUNT_2=DefaultEndpointsProtocol=https;AccountName=<account2>;AccountKey=<key2>;EndpointSuffix=core.windows.net" `

## Notes    "STORAGE_ACCOUNT_3=" `

    "RETENTION_DAYS=90" `

- The function will run on the schedule you set (default: daily at 3 AM UTC).    "TIMER_SCHEDULE=0 0 3 * * *"

- You can update app settings or redeploy at any time.```

- For production, consider using Application Insights for advanced monitoring.

**Note:** The function dynamically discovers all settings starting with `STORAGE_ACCOUNT_`. You can add as many as needed (e.g., `STORAGE_ACCOUNT_1` through `STORAGE_ACCOUNT_100`). Empty values are automatically skipped.

## Post-Deployment Verification

**Security Note**: Never store connection strings in code or source control. For production, use:

### 1. Check Function Status- **Azure Key Vault** for sensitive configuration

- **Managed Identity** to access storage accounts without connection strings

```pwsh

az functionapp show `#### Step 7: Deploy Function Code

  --name $functionApp `

  --resource-group $resourceGroup ````pwsh

  --query "state" `func azure functionapp publish $functionApp

  --output tsv```

```

## Post-Deployment Verification

Should return `Running`.

### 1. Check Function Status

### 2. View Function List

```pwsh

```pwshaz functionapp show `

az functionapp function list `  --name $functionApp `

  --name $functionApp `  --resource-group $resourceGroup `

  --resource-group $resourceGroup  --query "state" `

```  --output tsv

```

Should show `CleanupTimer` function.

Should return `Running`.

### 3. Monitor Logs

### 2. View Function List

Stream live logs:

```pwsh```pwsh

func azure functionapp logstream $functionAppaz functionapp function list `

```  --name $functionApp `

  --resource-group $resourceGroup

Or view in Azure Portal:```

1. Navigate to your Function App

2. Go to **Functions** > **CleanupTimer** > **Monitor**Should show `CleanupTimer` function.

3. Check **Invocations** and **Logs**

### 3. Monitor Logs

### 4. Manually Trigger (Optional)

Stream live logs:

Trigger the function manually for testing:```pwsh

```pwshfunc azure functionapp logstream $functionApp

az functionapp function invoke ````

  --name $functionApp `

  --resource-group $resourceGroup `Or view in Azure Portal:

  --function-name CleanupTimer1. Navigate to your Function App

```2. Go to **Functions** > **CleanupTimer** > **Monitor**

3. Check **Invocations** and **Logs**

## Production Best Practices

### 4. Manually Trigger (Optional)

### Security

Trigger the function manually for testing:

1. **Use Managed Identity for Storage Access**:```pwsh

   ```pwshaz functionapp function invoke `

   # Enable system-assigned managed identity  --name $functionApp `

   az functionapp identity assign --name $functionApp --resource-group $resourceGroup  --resource-group $resourceGroup `

     --function-name CleanupTimer

   # Grant Storage Table Data Contributor role to each storage account```

   az role assignment create `

     --assignee <function-app-principal-id> `## Production Best Practices

     --role "Storage Table Data Contributor" `

     --scope "/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.Storage/storageAccounts/<storage-account>"### Security

   ```

1. **Use Managed Identity for Storage Access**:

2. **Store Secrets in Key Vault**:   ```pwsh

   ```pwsh   # Enable system-assigned managed identity

   # Create Key Vault   az functionapp identity assign --name $functionApp --resource-group $resourceGroup

   az keyvault create --name "kv-tablecleanup" --resource-group $resourceGroup --location $location   

      # Grant Storage Table Data Contributor role to each storage account

   # Add connection strings (repeat for each storage account)   az role assignment create `

   az keyvault secret set --vault-name "kv-tablecleanup" --name "StorageAccount1" --value "<connection-string>"     --assignee <function-app-principal-id> `

        --role "Storage Table Data Contributor" `

   # Reference in Function App     --scope "/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.Storage/storageAccounts/<storage-account>"

   az functionapp config appsettings set `   ```

     --name $functionApp `

     --resource-group $resourceGroup `2. **Store Secrets in Key Vault**:

     --settings "STORAGE_ACCOUNT_1=@Microsoft.KeyVault(SecretUri=https://kv-tablecleanup.vault.azure.net/secrets/StorageAccount1/)"   ```pwsh

   ```   # Create Key Vault

   az keyvault create --name "kv-tablecleanup" --resource-group $resourceGroup --location $location

3. **Network Security**:   

   - Enable VNET integration for private connectivity   # Add connection strings

   - Configure private endpoints for storage accounts   az keyvault secret set --vault-name "kv-tablecleanup" --name "StorageAccount1" --value "<connection-string>"

   - Disable public network access where possible   

   # Reference in Function App

### Monitoring & Alerts   az functionapp config appsettings set `

     --name $functionApp `

1. **Configure Application Insights Alerts**:     --resource-group $resourceGroup `

   ```pwsh     --settings "STORAGE_ACCOUNT_1=@Microsoft.KeyVault(SecretUri=https://kv-tablecleanup.vault.azure.net/secrets/StorageAccount1/)"

   # Alert on function failures   ```

   az monitor metrics alert create `

     --name "FunctionFailures" `3. **Network Security**:

     --resource-group $resourceGroup `   - Enable VNET integration for private connectivity

     --scopes "/subscriptions/<subscription-id>/resourceGroups/$resourceGroup/providers/Microsoft.Insights/components/$appInsights" `   - Configure private endpoints for storage accounts

     --condition "count exceptions/count > 5" `   - Disable public network access where possible

     --window-size 5m `

     --evaluation-frequency 1m### Monitoring & Alerts

   ```

1. **Configure Application Insights Alerts**:

2. **Enable Diagnostic Settings**:   ```pwsh

   ```pwsh   # Alert on function failures

   az monitor diagnostic-settings create `   az monitor metrics alert create `

     --name "FunctionDiagnostics" `     --name "FunctionFailures" `

     --resource "/subscriptions/<subscription-id>/resourceGroups/$resourceGroup/providers/Microsoft.Web/sites/$functionApp" `     --resource-group $resourceGroup `

     --logs '[{"category": "FunctionAppLogs", "enabled": true}]' `     --scopes "/subscriptions/<subscription-id>/resourceGroups/$resourceGroup/providers/Microsoft.Insights/components/$appInsights" `

     --metrics '[{"category": "AllMetrics", "enabled": true}]' `     --condition "count exceptions/count > 5" `

     --workspace "/subscriptions/<subscription-id>/resourceGroups/$resourceGroup/providers/Microsoft.OperationalInsights/workspaces/<workspace-name>"     --window-size 5m `

   ```     --evaluation-frequency 1m

   ```

### Cost Optimization

2. **Enable Diagnostic Settings**:

1. **Choose Appropriate SKU**:   ```pwsh

   - **Flex Consumption (FC1)**: Best for sporadic workloads, pay-per-execution   az monitor diagnostic-settings create `

   - **Elastic Premium (EP1)**: Better for frequent executions with predictable load     --name "FunctionDiagnostics" `

     --resource "/subscriptions/<subscription-id>/resourceGroups/$resourceGroup/providers/Microsoft.Web/sites/$functionApp" `

2. **Optimize Execution**:     --logs '[{"category": "FunctionAppLogs", "enabled": true}]' `

   - Run during off-peak hours (configured via `TIMER_SCHEDULE`)     --metrics '[{"category": "AllMetrics", "enabled": true}]' `

   - Adjust retention period to minimize transaction volume     --workspace "/subscriptions/<subscription-id>/resourceGroups/$resourceGroup/providers/Microsoft.OperationalInsights/workspaces/<workspace-name>"

   - Monitor storage transaction costs in Cost Management   ```



### Failure Recovery### Cost Optimization



If deployment fails:1. **Choose Appropriate SKU**:

1. Check error messages in terminal output   - **Flex Consumption (FC1)**: Best for sporadic workloads, pay-per-execution

2. Verify all prerequisites are met   - **Elastic Premium (EP1)**: Better for frequent executions with predictable load

3. Clean up partial deployments:

   ```pwsh2. **Optimize Execution**:

   az group delete --name $resourceGroup --yes   - Run during off-peak hours (configured via `TIMER_SCHEDULE`)

   ```   - Adjust retention period to minimize transaction volume

4. Retry deployment from Step 2   - Monitor storage transaction costs in Cost Management



## Updating the Function### Failure Recovery



To deploy updates after code changes:If deployment fails:

1. Check error messages in terminal output

```pwsh2. Verify all prerequisites are met

# Build locally3. Clean up partial deployments:

dotnet build -c Release   ```pwsh

   az group delete --name $resourceGroup --yes

# Deploy   ```

func azure functionapp publish $functionApp4. Retry deployment from Step 2

```

## Updating the Function

## Rollback

To deploy updates after code changes:

To roll back to a previous deployment:

```pwsh

1. Go to Azure Portal > Function App > **Deployment Center**# Build locally

2. Find the previous deployment in the historydotnet build -c Release

3. Click **Redeploy**

# Deploy

Or use deployment slots for zero-downtime updates:func azure functionapp publish $functionApp

```pwsh```

# Create staging slot

az functionapp deployment slot create --name $functionApp --resource-group $resourceGroup --slot staging## Rollback



# Deploy to stagingTo roll back to a previous deployment:

func azure functionapp publish $functionApp --slot staging

1. Go to Azure Portal > Function App > **Deployment Center**

# Swap to production after testing2. Find the previous deployment in the history

az functionapp deployment slot swap --name $functionApp --resource-group $resourceGroup --slot staging3. Click **Redeploy**

```

Or use deployment slots for zero-downtime updates:

## Troubleshooting```pwsh

# Create staging slot

### Common Deployment Issuesaz functionapp deployment slot create --name $functionApp --resource-group $resourceGroup --slot staging



**Error: "Function App name already exists"**# Deploy to staging

- Function App names must be globally uniquefunc azure functionapp publish $functionApp --slot staging

- Choose a different name or append a unique suffix

# Swap to production after testing

**Error: "Insufficient permissions"**az functionapp deployment slot swap --name $functionApp --resource-group $resourceGroup --slot staging

- Ensure your Azure account has Contributor role on the subscription or resource group```

- Check with `az role assignment list --assignee <your-email>`

## Troubleshooting

**Error: "Runtime not supported"**

- Ensure you're using Functions v4 with .NET 8 isolated worker### Common Deployment Issues

- Verify with `az functionapp config show --name $functionApp --resource-group $resourceGroup`

**Error: "Function App name already exists"**

**Function not triggering on schedule**- Function App names must be globally unique

- Verify `TIMER_SCHEDULE` is a valid CRON expression- Choose a different name or append a unique suffix

- Check `AzureWebJobsStorage` is configured correctly

- Review logs in Application Insights for errors**Error: "Insufficient permissions"**

- Ensure your Azure account has Contributor role on the subscription or resource group

## Additional Resources- Check with `az role assignment list --assignee <your-email>`



- [Azure Functions Best Practices](https://learn.microsoft.com/azure/azure-functions/functions-best-practices)**Error: "Runtime not supported"**

- [Flex Consumption Plan Documentation](https://learn.microsoft.com/azure/azure-functions/flex-consumption-plan)- Ensure you're using Functions v4 with .NET 8 isolated worker

- [Azure Functions Deployment Guide](https://learn.microsoft.com/azure/azure-functions/functions-deployment-technologies)- Verify with `az functionapp config show --name $functionApp --resource-group $resourceGroup`

- [Monitoring Azure Functions](https://learn.microsoft.com/azure/azure-functions/functions-monitoring)

**Function not triggering on schedule**

## Sample Bicep Templates- Verify `TIMER_SCHEDULE` is a valid CRON expression

- Check `AzureWebJobsStorage` is configured correctly

For Infrastructure-as-Code deployments, refer to Azure Verified Modules (AVM):- Review logs in Application Insights for errors

- [JavaScript Functions AZD Sample](https://github.com/Azure-Samples/functions-quickstart-javascript-azd/tree/main/infra)

- [.NET Functions with EventGrid Sample](https://github.com/Azure-Samples/functions-quickstart-dotnet-azd-eventgrid-blob/tree/main/infra)## Additional Resources


- [Azure Functions Best Practices](https://learn.microsoft.com/azure/azure-functions/functions-best-practices)
- [Flex Consumption Plan Documentation](https://learn.microsoft.com/azure/azure-functions/flex-consumption-plan)
- [Azure Functions Deployment Guide](https://learn.microsoft.com/azure/azure-functions/functions-deployment-technologies)
- [Monitoring Azure Functions](https://learn.microsoft.com/azure/azure-functions/functions-monitoring)

## Sample Bicep Templates

For Infrastructure-as-Code deployments, refer to Azure Verified Modules (AVM):
- [JavaScript Functions AZD Sample](https://github.com/Azure-Samples/functions-quickstart-javascript-azd/tree/main/infra)
- [.NET Functions with EventGrid Sample](https://github.com/Azure-Samples/functions-quickstart-dotnet-azd-eventgrid-blob/tree/main/infra)
