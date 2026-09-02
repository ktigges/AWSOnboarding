param(
    [Parameter(Mandatory)]
    [string]$DeviceName,

    [Parameter(Mandatory)]
    [string]$TenantId
)

$ErrorActionPreference = 'Stop'

function Get-GraphCollection {
    param([Parameter(Mandatory)][string]$Uri)

    $items = @()
    while ($Uri) {
        $page = Invoke-MgGraphRequest -Method GET -Uri $Uri
        $items += @($page.value)
        $Uri = $page.'@odata.nextLink'
    }
    return $items
}

Import-Module Microsoft.Graph.Authentication
Write-Host 'Authenticating to Microsoft Graph for Intune and Entra cleanup.'
Write-Host 'Complete the browser sign-in or consent prompt before teardown continues.'
Connect-MgGraph -TenantId $TenantId -Scopes @(
    'DeviceManagementManagedDevices.ReadWrite.All'
    'Directory.AccessAsUser.All'
) -ContextScope Process -NoWelcome

$shortName = $DeviceName.Split('.', 2)[0]
$acceptedNames = @($DeviceName, $shortName) | Where-Object { $_ } | Select-Object -Unique

$entraUri = 'https://graph.microsoft.com/v1.0/devices?$select=id,deviceId,displayName,operatingSystem&$top=999'
$entraDevices = @(Get-GraphCollection -Uri $entraUri)
$entraMatches = @(
    $entraDevices | Where-Object { $acceptedNames -icontains $_.displayName }
)
if ($entraMatches.Count -gt 1) {
    $names = ($entraMatches.displayName -join ', ')
    throw "Ambiguous Entra device match for '$DeviceName': $names"
}

$entraDevice = $entraMatches | Select-Object -First 1
$aadDeviceId = $entraDevice.deviceId
$managedUri = 'https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?$select=id,azureADDeviceId,deviceName,managedDeviceName&$top=999'
$managedDevices = @(Get-GraphCollection -Uri $managedUri)
$managedMatches = @(
    if ($aadDeviceId) {
        $managedDevices | Where-Object { $_.azureADDeviceId -ieq $aadDeviceId }
    }
    else {
        $managedDevices | Where-Object { $acceptedNames -icontains $_.deviceName }
    }
)
if ($managedMatches.Count -gt 1) {
    $names = ($managedMatches.deviceName -join ', ')
    throw "Ambiguous Intune managed-device match for '$DeviceName': $names"
}

$managedDevice = $managedMatches | Select-Object -First 1
if ($managedDevice) {
    Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$($managedDevice.id)"
    $managedRemaining = @(Get-GraphCollection -Uri $managedUri) |
        Where-Object { $_.id -eq $managedDevice.id }
    if ($managedRemaining) {
        throw "Intune managed device $($managedDevice.id) still exists after DELETE"
    }
    Write-Output "Deleted Intune managed device: $($managedDevice.id)"
}
else {
    Write-Output 'No matching Intune managed device remains'
}

if ($entraDevice) {
    Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/v1.0/devices/$($entraDevice.id)"
    $entraRemaining = @(Get-GraphCollection -Uri $entraUri) |
        Where-Object { $_.id -eq $entraDevice.id }
    if ($entraRemaining) {
        throw "Entra device $($entraDevice.id) still exists after DELETE"
    }
    Write-Output "Deleted Entra device: $($entraDevice.id)"
}
else {
    Write-Output 'No matching Entra device remains'
}