$ErrorActionPreference = "Stop"

. "$PSScriptRoot/00_Config.ps1"
. "$PSScriptRoot/00_Secrets.ps1"

# Define resource group prefix and regions
$keyVaultName = Get-ConfigValue -Key "KeyVaultName"
$resourceGroupPrefix = Get-ConfigValue -Key "ResourceGroupPrefix"
$primaryRegion = Get-ConfigValue -Key "PrimaryRegion"
$secondaryRegion = Get-ConfigValue -Key "SecondaryRegion"
$regions = @($primaryRegion, $secondaryRegion)
$vnetPrefix = Get-ConfigValue -Key "VNetPrefix"
$vnetAddressPrefix = Get-ConfigValue -Key "VNetAddressPrefix"
$subnets = Get-ConfigValue -Key "Subnets"
$sharedResourceGroup = Get-ConfigValue -Key "SharedResourceGroup"
$sharedResourceLocation = $primaryRegion

# VM Configuration
$vmSize = "Standard_E2s_v3"
$vmAdminUsername = "azureadmin"
$vmPassword = $env:VMVMPASSWORD
$vmImagePublisher = "MicrosoftWindowsServer"
$vmImageOffer = "WindowsServer"
$vmImageSku = "2022-datacenter-azure-edition-hotpatch"
$vmImageVersion = "latest"


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
            --public-ip-address $bastionPipName `
            --no-wait
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
        --bypass AzureServices `
        --public-network-access Disabled
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
# Create Private Endpoint for Key Vault on Primary Region
$privateEndpointName = "pe-$keyVaultName-$primaryRegion"
# Check if Private Endpoint exists
$privateEndpointExists = $(az network private-endpoint show --name $privateEndpointName --resource-group $primaryResourceGroup --query name -o tsv 2>$null)

if (-not $privateEndpointExists) {
    Write-Output "Creating Private Endpoint for Key Vault in primary region '$primaryRegion'..."
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
    Write-Output "Creating DNS Zone Group for Private Endpoint in primary region..."
    az network private-endpoint dns-zone-group create `
        --resource-group $primaryResourceGroup `
        --endpoint-name $privateEndpointName `
        --name "keyvault-zone-group" `
        --private-dns-zone $(az network private-dns zone show --name $privateDnsZoneName --resource-group $sharedResourceGroup --query id -o tsv) `
        --zone-name "keyvault"
} else {
    Write-Output "Private Endpoint '$privateEndpointName' already exists, skipping creation."
}

# Create Private Endpoint for Key Vault on Secondary Region
$secondaryResourceGroup = "$resourceGroupPrefix-$secondaryRegion"
$secondaryVnet = "$vnetPrefix$secondaryRegion"
$secondaryPrivateEndpointName = "pe-$keyVaultName-$secondaryRegion"

# Check if Private Endpoint exists in secondary region
$secondaryPrivateEndpointExists = $(az network private-endpoint show --name $secondaryPrivateEndpointName --resource-group $secondaryResourceGroup --query name -o tsv 2>$null)

if (-not $secondaryPrivateEndpointExists) {
    Write-Output "Creating Private Endpoint for Key Vault in secondary region '$secondaryRegion'..."
    $keyVaultId = $(az keyvault show --name $keyVaultName --resource-group $primaryResourceGroup --query id -o tsv)
    
    az network private-endpoint create `
        --name $secondaryPrivateEndpointName `
        --resource-group $secondaryResourceGroup `
        --location $secondaryRegion `
        --vnet-name $secondaryVnet `
        --subnet "PrivateEndpointSubnet" `
        --private-connection-resource-id $keyVaultId `
        --group-id vault `
        --connection-name "connection-to-$keyVaultName"
        
    # Create DNS Zone Group for Private Endpoint
    Write-Output "Creating DNS Zone Group for Private Endpoint in secondary region..."
    az network private-endpoint dns-zone-group create `
        --resource-group $secondaryResourceGroup `
        --endpoint-name $secondaryPrivateEndpointName `
        --name "keyvault-zone-group" `
        --private-dns-zone $(az network private-dns zone show --name $privateDnsZoneName --resource-group $sharedResourceGroup --query id -o tsv) `
        --zone-name "keyvault"
} else {
    Write-Output "Private Endpoint '$secondaryPrivateEndpointName' already exists, skipping creation."
}

# Create Storage Account in primary region with private endpoint
$storageAccountName = Get-ConfigValue -Key "StorageAccountName"
$primaryResourceGroup = "$resourceGroupPrefix-$primaryRegion"
$primaryVnet = "$vnetPrefix$primaryRegion"

# Check if Storage Account exists
$storageAccountExists = $(az storage account show --name $storageAccountName --resource-group $primaryResourceGroup --query name -o tsv 2>$null)

if (-not $storageAccountExists) {
    Write-Output "Creating Storage Account '$storageAccountName' in primary region '$primaryRegion'..."
    az storage account create `
        --name $storageAccountName `
        --resource-group $primaryResourceGroup `
        --location $primaryRegion `
        --sku Standard_GRS `
        --kind StorageV2 `
        --enable-hierarchical-namespace false `
        --min-tls-version TLS1_2 `
        --allow-blob-public-access false `
        --default-action Deny `
        --bypass AzureServices

    # Wait for storage account to be fully provisioned
    Start-Sleep -Seconds 10
} else {
    Write-Output "Storage Account '$storageAccountName' already exists, skipping creation."
}

# Create Private DNS Zone for Blob Storage
$blobDnsZoneName = "privatelink.blob.core.windows.net"

# Check if Private DNS Zone for Blob exists
$blobDnsZoneExists = $(az network private-dns zone show --name $blobDnsZoneName --resource-group $sharedResourceGroup --query name -o tsv 2>$null)

if (-not $blobDnsZoneExists) {
    Write-Output "Creating Private DNS Zone '$blobDnsZoneName' in shared resource group..."
    az network private-dns zone create `
        --resource-group $sharedResourceGroup `
        --name $blobDnsZoneName
} else {
    Write-Output "Private DNS Zone '$blobDnsZoneName' already exists, skipping creation."
}

# Link Blob Private DNS Zone to VNet in primary region
$blobDnsLinkName = "blob-link-to-$primaryVnetName"

# Check if Blob DNS link exists
$blobDnsLinkExists = $(az network private-dns link vnet show --name $blobDnsLinkName --resource-group $sharedResourceGroup --zone-name $blobDnsZoneName --query name -o tsv 2>$null)

if (-not $blobDnsLinkExists) {
    Write-Output "Linking Blob Private DNS Zone to VNet in $primaryRegion region..."
    az network private-dns link vnet create `
        --resource-group $sharedResourceGroup `
        --zone-name $blobDnsZoneName `
        --name $blobDnsLinkName `
        --virtual-network $(az network vnet show --resource-group $primaryResourceGroup --name $primaryVnetName --query id -o tsv) `
        --registration-enabled false
} else {
    Write-Output "Blob DNS Link '$blobDnsLinkName' already exists, skipping creation."
}

# Create Private Endpoint for Blob Storage in Primary Region
$blobPrivateEndpointName = "pe-$storageAccountName-blob-$primaryRegion"

# Check if Blob Private Endpoint exists
$blobPrivateEndpointExists = $(az network private-endpoint show --name $blobPrivateEndpointName --resource-group $primaryResourceGroup --query name -o tsv 2>$null)

if (-not $blobPrivateEndpointExists) {
    Write-Output "Creating Private Endpoint for Blob Storage in primary region '$primaryRegion'..."
    $storageAccountId = $(az storage account show --name $storageAccountName --resource-group $primaryResourceGroup --query id -o tsv)
    
    az network private-endpoint create `
        --name $blobPrivateEndpointName `
        --resource-group $primaryResourceGroup `
        --location $primaryRegion `
        --vnet-name $primaryVnet `
        --subnet "PrivateEndpointSubnet" `
        --private-connection-resource-id $storageAccountId `
        --group-id blob `
        --connection-name "connection-to-$storageAccountName-blob"
        
    # Create DNS Zone Group for Blob Private Endpoint
    Write-Output "Creating DNS Zone Group for Blob Private Endpoint in primary region..."
    az network private-endpoint dns-zone-group create `
        --resource-group $primaryResourceGroup `
        --endpoint-name $blobPrivateEndpointName `
        --name "blob-zone-group" `
        --private-dns-zone $(az network private-dns zone show --name $blobDnsZoneName --resource-group $sharedResourceGroup --query id -o tsv) `
        --zone-name "blob"
} else {
    Write-Output "Blob Private Endpoint '$blobPrivateEndpointName' already exists, skipping creation."
}

# Link Blob Private DNS Zone to VNet in secondary region
$secondaryResourceGroup = "$resourceGroupPrefix-$secondaryRegion"
$secondaryVnet = "$vnetPrefix$secondaryRegion"

# Create Private Endpoint for Blob Storage in Secondary Region
$blobPrivateEndpointNameSecondary = "pe-$storageAccountName-blob-$secondaryRegion"

# Check if Blob Private Endpoint exists in secondary region
$blobPrivateEndpointExistsSecondary = $(az network private-endpoint show --name $blobPrivateEndpointNameSecondary --resource-group $secondaryResourceGroup --query name -o tsv 2>$null)

if (-not $blobPrivateEndpointExistsSecondary) {
    Write-Output "Creating Private Endpoint for Blob Storage in secondary region '$secondaryRegion'..."
    $storageAccountId = $(az storage account show --name $storageAccountName --resource-group $primaryResourceGroup --query id -o tsv)
    
    az network private-endpoint create `
        --name $blobPrivateEndpointNameSecondary `
        --resource-group $secondaryResourceGroup `
        --location $secondaryRegion `
        --vnet-name $secondaryVnet `
        --subnet "PrivateEndpointSubnet" `
        --private-connection-resource-id $storageAccountId `
        --group-id blob `
        --connection-name "connection-to-$storageAccountName-blob"
        
    # Create DNS Zone Group for Secondary Blob Private Endpoint
    Write-Output "Creating DNS Zone Group for Blob Private Endpoint in secondary region..."
    az network private-endpoint dns-zone-group create `
        --resource-group $secondaryResourceGroup `
        --endpoint-name $blobPrivateEndpointNameSecondary `
        --name "blob-zone-group" `
        --private-dns-zone $(az network private-dns zone show --name $blobDnsZoneName --resource-group $sharedResourceGroup --query id -o tsv) `
        --zone-name "blob"
} else {
    Write-Output "Blob Private Endpoint '$blobPrivateEndpointNameSecondary' already exists, skipping creation."
}