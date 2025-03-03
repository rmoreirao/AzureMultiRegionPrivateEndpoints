$ErrorActionPreference = "Stop"

& "$PSScriptRoot/00_Secrets.ps1"

# Define resource group prefix and regions
$resourceGroupPrefix = "rg-multi-pe"
$primaryRegion = "germanywestcentral"  # Primary region (correct name: lowercase)
$secondaryRegion = "swedencentral"     # Secondary region (correct name: lowercase)
$regions = @($primaryRegion, $secondaryRegion)
$vnetPrefix = "vnet-"
$vnetAddressPrefix = "10.0.0.0/16"
$keyVaultName = "kv-multi-perm01"  # Ensure unique name

# Add a shared resource group for global resources
$sharedResourceGroup = "rg-multi-pe-shared"
$sharedResourceLocation = $primaryRegion  # Use primary region for global resources

# VM Configuration
$vmSize = "Standard_E2s_v3"
$vmAdminUsername = "azureadmin"
$vmPassword = $env:VMVMPASSWORD
$vmImagePublisher = "MicrosoftWindowsServer"
$vmImageOffer = "WindowsServer"
$vmImageSku = "2022-datacenter-azure-edition-hotpatch"
$vmImageVersion = "latest"

# Define subnets and their address prefixes
$subnets = @{
    "VirtualMachineSubnet"    = "10.0.0.0/24"
    "PrivateEndpointSubnet"   = "10.0.1.0/24"
    "AzureBastionSubnet"      = "10.0.2.0/27"  # Added required subnet for Azure Bastion
}

# First create the shared resource group for global resources
Write-Output "Creating shared resource group '$sharedResourceGroup' in region '$sharedResourceLocation'..."
az group create --name $sharedResourceGroup --location $sharedResourceLocation

foreach ($region in $regions) {
    # Create region-specific resource group name
    $resourceGroup = "$resourceGroupPrefix-$region"
    
    # Create the resource group
    Write-Output "Creating resource group '$resourceGroup' in region '$region'..."
    az group create --name $resourceGroup --location $region
    
    # Construct a VNet name using the region name
    $vnetName = "$vnetPrefix$region"
    
    Write-Output "Creating virtual network '$vnetName' in region '$region'..."
    
    # Check if virtual network exists
    $vnetExists = $(az network vnet show --resource-group $resourceGroup --name $vnetName --query name -o tsv 2>$null)
    
    if (-not $vnetExists) {
        # Create the virtual network
        az network vnet create `
            --resource-group $resourceGroup `
            --location $region `
            --name $vnetName `
            --address-prefix $vnetAddressPrefix
    } else {
        Write-Output "Virtual network '$vnetName' already exists, skipping creation."
    }

    # Create each subnet within the virtual network
    foreach ($subnetName in $subnets.Keys) {
        $subnetPrefix = $subnets[$subnetName]
        Write-Output "Creating subnet '$subnetName' with address prefix '$subnetPrefix' in VNet '$vnetName'..."
        
        # Check if subnet exists first to avoid errors
        $subnetExists = $(az network vnet subnet list --resource-group $resourceGroup --vnet-name $vnetName --query "[?name=='$subnetName'].name" -o tsv)
        if (-not $subnetExists) {
            az network vnet subnet create `
                --resource-group $resourceGroup `
                --vnet-name $vnetName `
                --name $subnetName `
                --address-prefix $subnetPrefix
        } else {
            Write-Output "Subnet '$subnetName' already exists, skipping creation."
        }
    }
    
    # Create a VM in each region
    $vmName = "vm$($region.Substring(0, [Math]::Min(5, $region.Length)))"
    Write-Output "Creating virtual machine '$vmName' in region '$region'..."
    
    # Check if VM exists
    $vmExists = $(az vm show --name $vmName --resource-group $resourceGroup --query name -o tsv 2>$null)
    
    if (-not $vmExists) {
        Write-Output "Creating VM '$vmName' in region '$region'..."
        az vm create `
            --resource-group $resourceGroup `
            --name $vmName `
            --location $region `
            --vnet-name $vnetName `
            --subnet "VirtualMachineSubnet" `
            --image "${vmImagePublisher}:${vmImageOffer}:${vmImageSku}:${vmImageVersion}" `
            --admin-username $vmAdminUsername `
            --admin-password $vmPassword `
            --public-ip-address '""' `
            --size $vmSize `
            --nsg-rule NONE
    } else {
        Write-Output "VM '$vmName' already exists, skipping creation."
    }
    
    # Create Azure Bastion
    $bastionName = "bastion-$region"
    $bastionPipName = "pip-$bastionName"
    
    # Check if bastion exists
    $bastionExists = $(az network bastion show --name $bastionName --resource-group $resourceGroup --query name -o tsv 2>$null)
    
    if (-not $bastionExists) {
        Write-Output "Creating public IP for Bastion '$bastionName' in region '$region'..."
        az network public-ip create `
            --resource-group $resourceGroup `
            --name $bastionPipName `
            --location $region `
            --sku Standard `
            --allocation-method Static
        
        Write-Output "Creating Azure Bastion '$bastionName' in region '$region'..."
        az network bastion create `
            --resource-group $resourceGroup `
            --name $bastionName `
            --location $region `
            --vnet-name $vnetName `
            --public-ip-address $bastionPipName
    } else {
        Write-Output "Bastion '$bastionName' already exists, skipping creation."
    }
}

# Create Key Vault in primary region with private endpoint
$primaryResourceGroup = "$resourceGroupPrefix-$primaryRegion"
$primaryVnet = "$vnetPrefix$primaryRegion"

# Check if Key Vault exists
$keyVaultExists = $(az keyvault show --name $keyVaultName --resource-group $primaryResourceGroup --query name -o tsv 2>$null)

if (-not $keyVaultExists) {
    Write-Output "Creating Key Vault '$keyVaultName' in primary region '$primaryRegion'..."
    az keyvault create `
        --name $keyVaultName `
        --resource-group $primaryResourceGroup `
        --location $primaryRegion `
        --default-action Deny `
        --bypass AzureServices
} else {
    Write-Output "Key Vault '$keyVaultName' already exists, skipping creation."
}

# Create Private DNS Zone for Key Vault in the shared resource group
$privateDnsZoneName = "privatelink.vaultcore.azure.net"
# Check if Private DNS Zone exists
$dnsZoneExists = $(az network private-dns zone show --name $privateDnsZoneName --resource-group $sharedResourceGroup --query name -o tsv 2>$null)

if (-not $dnsZoneExists) {
    Write-Output "Creating Private DNS Zone '$privateDnsZoneName' in shared resource group..."
    az network private-dns zone create `
        --resource-group $sharedResourceGroup `
        --name $privateDnsZoneName
} else {
    Write-Output "Private DNS Zone '$privateDnsZoneName' already exists, skipping creation."
}
# Link Private DNS Zone to VNet in primary region only
$primaryResourceGroup = "$resourceGroupPrefix-$primaryRegion"
$primaryVnetName = "$vnetPrefix$primaryRegion"
$dnsLinkName = "link-to-$primaryVnetName"

# Check if DNS link exists
$dnsLinkExists = $(az network private-dns link vnet show --name $dnsLinkName --resource-group $sharedResourceGroup --zone-name $privateDnsZoneName --query name -o tsv 2>$null)

if (-not $dnsLinkExists) {
    Write-Output "Linking Private DNS Zone to VNet in $primaryRegion region..."
    az network private-dns link vnet create `
        --resource-group $sharedResourceGroup `
        --zone-name $privateDnsZoneName `
        --name $dnsLinkName `
        --virtual-network $(az network vnet show --resource-group $primaryResourceGroup --name $primaryVnetName --query id -o tsv) `
        --registration-enabled false
} else {
    Write-Output "DNS Link '$dnsLinkName' already exists, skipping creation."
}

# Create Private Endpoint for Key Vault
$privateEndpointName = "pe-$keyVaultName"
# Check if Private Endpoint exists
$privateEndpointExists = $(az network private-endpoint show --name $privateEndpointName --resource-group $primaryResourceGroup --query name -o tsv 2>$null)

if (-not $privateEndpointExists) {
    Write-Output "Creating Private Endpoint for Key Vault..."
    $keyVaultId = $(az keyvault show --name $keyVaultName --resource-group $primaryResourceGroup --query id -o tsv)
    
    az network private-endpoint create `
        --name $privateEndpointName `
        --resource-group $primaryResourceGroup `
        --location $primaryRegion `
        --vnet-name $primaryVnet `
        --subnet "PrivateEndpointSubnet" `
        --private-connection-resource-id $keyVaultId `
        --group-id vault `
        --connection-name "connection-to-$keyVaultName"
        
    # Create DNS Zone Group for Private Endpoint
    Write-Output "Creating DNS Zone Group for Private Endpoint..."
    az network private-endpoint dns-zone-group create `
        --resource-group $primaryResourceGroup `
        --endpoint-name $privateEndpointName `
        --name "keyvault-zone-group" `
        --private-dns-zone $(az network private-dns zone show --name $privateDnsZoneName --resource-group $sharedResourceGroup --query id -o tsv) `
        --zone-name "keyvault"
} else {
    Write-Output "Private Endpoint '$privateEndpointName' already exists, skipping creation."
}