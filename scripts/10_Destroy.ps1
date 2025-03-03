$ErrorActionPreference = "Stop"

# Import configuration
. "$PSScriptRoot/00_Config.ps1"

# Get resource group information from config
$resourceGroupPrefix = Get-ConfigValue -Key "ResourceGroupPrefix"
$primaryRegion = Get-ConfigValue -Key "PrimaryRegion"
$secondaryRegion = Get-ConfigValue -Key "SecondaryRegion"
$sharedResourceGroup = Get-ConfigValue -Key "SharedResourceGroup"
$regions = @($primaryRegion, $secondaryRegion)

Write-Output "Starting the cleanup process for all created resource groups..."

# Ask for confirmation before proceeding
$confirmation = Read-Host "This script will DELETE ALL resource groups created by the deployment script. Are you sure you want to continue? (y/n)"
if ($confirmation -ne 'y') {
    Write-Output "Operation canceled by user."
    exit
}

# Delete region-specific resource groups first
foreach ($region in $regions) {
    $resourceGroup = "$resourceGroupPrefix-$region"
    
    Write-Output "Deleting resource group: $resourceGroup"
    
    # Check if resource group exists
    $rgExists = $(az group exists --name $resourceGroup)
    
    if ($rgExists -eq "true") {
        Write-Output "Resource group '$resourceGroup' exists. Deleting..."
        
        # Setting --no-wait would allow the deletion to happen in background
        # but we'll wait for each deletion to complete to ensure dependencies are handled properly
        az group delete --name $resourceGroup --yes
        
        Write-Output "Resource group '$resourceGroup' deletion initiated."
    } else {
        Write-Output "Resource group '$resourceGroup' does not exist. Skipping deletion."
    }
}

# Delete the shared resource group last (it contains DNS zones that may be referenced by other resources)
Write-Output "Deleting shared resource group: $sharedResourceGroup"

# Check if shared resource group exists
$sharedRgExists = $(az group exists --name $sharedResourceGroup)

if ($sharedRgExists -eq "true") {
    Write-Output "Shared resource group '$sharedResourceGroup' exists. Deleting..."
    az group delete --name $sharedResourceGroup --yes
    Write-Output "Shared resource group '$sharedResourceGroup' deletion initiated."
} else {
    Write-Output "Shared resource group '$sharedResourceGroup' does not exist. Skipping deletion."
}

Write-Output "Resource group deletion process has been initiated for all resource groups."
Write-Output "Note: Azure resource group deletion happens asynchronously and may take several minutes to complete."
Write-Output "You can check the status in the Azure Portal or using 'az group list'."
