$ErrorActionPreference = "Stop"

. "$PSScriptRoot/00_Config.ps1"

# Get configuration values
$keyVaultName = Get-ConfigValue -Key "KeyVaultName"
$storageAccountName = Get-ConfigValue -Key "StorageAccountName"
$resourceGroupPrefix = Get-ConfigValue -Key "ResourceGroupPrefix"
$primaryRegion = Get-ConfigValue -Key "PrimaryRegion"
$secondaryRegion = Get-ConfigValue -Key "SecondaryRegion"
$vnetPrefix = Get-ConfigValue -Key "VNetPrefix"
$sharedResourceGroup = Get-ConfigValue -Key "SharedResourceGroup"

# Define DNS zones and VNet names
$kvPrivateDnsZoneName = "privatelink.vaultcore.azure.net"
$blobPrivateDnsZoneName = "privatelink.blob.core.windows.net"
$primaryVnetName = "$vnetPrefix$primaryRegion"
$secondaryVnetName = "$vnetPrefix$secondaryRegion"

# Key Vault DNS link names
$kvPrimaryDnsLinkName = "link-to-$primaryVnetName"
$kvSecondaryDnsLinkName = "link-to-$secondaryVnetName"

# Blob Storage DNS link names
$blobPrimaryDnsLinkName = "blob-link-to-$primaryVnetName"
$blobSecondaryDnsLinkName = "blob-link-to-$secondaryVnetName"

# 1) Check KeyVault DNS on Primary Region VM
# Execute the script with the following command on the Primary Region VM:
# nslookup kv-multi-perm02.vault.azure.net
# nslookup samultipe02.blob.core.windows.net
# Expected Address for the DNS: internal IP address, which is valid - can connect to the Key Vault and Storage from this location

# 2) Check KeyVault DNS on Secondary Region VM
# Execute the script with the following command on the Secondary Region VM:
# nslookup {key vault name}.vault.azure.net
# nslookup {storage account name}.blob.core.windows.net
# Expected Address for the DNS: internet address, which is not valid - cannot connect to the Key Vault and Storage from this location

# 3) Perform failover and reconfigure the Private DNS Zone Vnet links

# # Initiate Storage Account failover
# Write-Output "Initiating Storage Account failover for '$storageAccountName'..."
# $primaryResourceGroup = "$resourceGroupPrefix-$primaryRegion"

# # Check if failover is already in progress
# $failoverInProgress = $(az storage account show `
#     --name $storageAccountName `
#     --resource-group $primaryResourceGroup `
#     --query failoverInProgress)

# if ($failoverInProgress -eq $true) {
#     Write-Warning "Failover is already in progress for storage account '$storageAccountName'"
# } else {
#     Write-Output "Starting failover for storage account '$storageAccountName'..."
#     az storage account failover `
#         --name $storageAccountName `
#         --resource-group $primaryResourceGroup `
#         --yes

#     if ($LASTEXITCODE -ne 0) {
#         throw "Failed to initiate storage account failover"
#     }
#     Write-Output "Storage account failover initiated successfully"
# }

# # Wait for failover to complete
# Write-Output "Waiting for storage account failover to complete..."
# $failoverComplete = $false
# $retryCount = 0
# $maxRetries = 30  # Maximum number of retries (30 x 20 seconds = 10 minutes maximum wait time)

# while (-not $failoverComplete -and $retryCount -lt $maxRetries) {
#     $retryCount++
#     $failoverInProgress = $(az storage account show `
#         --name $storageAccountName `
#         --resource-group $primaryResourceGroup `
#         --query failoverInProgress)
    
#     if ($failoverInProgress -eq $false) {
#         $failoverComplete = $true
#         Write-Output "Storage account failover completed successfully"
#     } else {
#         Write-Output "Failover still in progress. Waiting 20 seconds before checking again... (Attempt $retryCount of $maxRetries)"
#         Start-Sleep -Seconds 20
#     }
# }

# if (-not $failoverComplete) {
#     throw "Failover did not complete within the expected time. Please check the storage account status manually."
# }

# Remove the VNet links from Primary Region
Write-Output "Removing DNS Zone VNet links from primary region '$primaryRegion'..."

# Remove Key Vault DNS link
Write-Output "Removing Key Vault DNS Zone VNet link..."
az network private-dns link vnet delete `
    --name $kvPrimaryDnsLinkName `
    --resource-group $sharedResourceGroup `
    --zone-name $kvPrivateDnsZoneName `
    --yes

if ($LASTEXITCODE -ne 0) {
    throw "Failed to remove Key Vault DNS Zone VNet link from primary region"
}

# Remove Blob Storage DNS link
Write-Output "Removing Blob Storage DNS Zone VNet link..."
az network private-dns link vnet delete `
    --name $blobPrimaryDnsLinkName `
    --resource-group $sharedResourceGroup `
    --zone-name $blobPrivateDnsZoneName `
    --yes

if ($LASTEXITCODE -ne 0) {
    throw "Failed to remove Blob Storage DNS Zone VNet link from primary region"
}
    
# Add the VNet links to Secondary Region
Write-Output "Creating DNS Zone VNet links to secondary region '$secondaryRegion'..."
$secondaryResourceGroup = "$resourceGroupPrefix-$secondaryRegion"
$secondaryVnetId = $(az network vnet show --resource-group $secondaryResourceGroup --name $secondaryVnetName --query id -o tsv)

# Add Key Vault DNS link
Write-Output "Creating Key Vault DNS Zone VNet link..."
az network private-dns link vnet create `
    --resource-group $sharedResourceGroup `
    --zone-name $kvPrivateDnsZoneName `
    --name $kvSecondaryDnsLinkName `
    --virtual-network $secondaryVnetId `
    --registration-enabled false

if ($LASTEXITCODE -ne 0) {
    throw "Failed to create Key Vault DNS Zone VNet link to secondary region"
}

# Add Blob Storage DNS link
Write-Output "Creating Blob Storage DNS Zone VNet link..."
az network private-dns link vnet create `
    --resource-group $sharedResourceGroup `
    --zone-name $blobPrivateDnsZoneName `
    --name $blobSecondaryDnsLinkName `
    --virtual-network $secondaryVnetId `
    --registration-enabled false

if ($LASTEXITCODE -ne 0) {
    throw "Failed to create Blob Storage DNS Zone VNet link to secondary region"
}

Write-Output "DNS Zone VNet links successfully updated for failover"

# 4) Check KeyVault DNS on Primary Region VM
# Execute the script with the following command on the Primary Region VM:
# nslookup {key vault name}.vault.azure.net
# Expected Address for the DNS: internet address, which is not valid - cannot connect to the Key Vault from this location

# 5) Check KeyVault DNS on Secondary Region VM
# Execute the script with the following command on the Secondary Region VM:
# nslookup {key vault name}.vault.azure.net
# Expected Address for the DNS: internal IP address, which is valid - can connect to the Key Vault from this location