# Configuration variables shared across scripts
$script:Config = @{
    # Resource naming
    KeyVaultName = "kv-multi-perm02"
    StorageAccountName = "samultipe02"  # Adding Storage Account name
    ResourceGroupPrefix = "rg-multi-pe"
    VNetPrefix = "vnet-"
    SharedResourceGroup = "rg-multi-pe-shared"

    # Regions
    PrimaryRegion = "germanywestcentral"
    SecondaryRegion = "swedencentral"

    # Network
    VNetAddressPrefix = "10.0.0.0/16"
    Subnets = @{
        VirtualMachineSubnet = "10.0.0.0/24"
        PrivateEndpointSubnet = "10.0.1.0/24"
        AzureBastionSubnet = "10.0.2.0/27"
    }
}

# Export functions to get config values
function Get-ConfigValue {
    param (
        [string]$Key
    )
    return $script:Config[$Key]
}