$ErrorActionPreference = 'Stop'

function Get-EnvValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$DefaultValue = ''
    )

    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $DefaultValue
    }

    return $value
}

function Test-ContainerAppExists {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ResourceGroup
    )

    & az containerapp show --name $Name --resource-group $ResourceGroup --query name -o tsv 1>$null 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Invoke-Az {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$FailureMessage
    )

    & az @Arguments | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw $FailureMessage
    }
}

function Ensure-ResourceProviderRegistered {
    param(
        [Parameter(Mandatory = $true)][string]$Namespace
    )

    $state = az provider show --namespace $Namespace --query registrationState -o tsv 2>$null
    if ([string]::IsNullOrWhiteSpace($state)) {
        $state = 'NotRegistered'
    }

    if ($state -eq 'Registered') {
        return
    }

    Write-Host "Registering resource provider $Namespace"
    Invoke-Az -Arguments @('provider', 'register', '--namespace', $Namespace) -FailureMessage "Failed to register resource provider $Namespace."

    $deadline = (Get-Date).AddMinutes(10)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 10
        $state = az provider show --namespace $Namespace --query registrationState -o tsv 2>$null
        if ($state -eq 'Registered') {
            return
        }
    }

    throw "Timed out waiting for resource provider $Namespace to register."
}

function Set-ContainerApp {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ResourceGroup,
        [Parameter(Mandatory = $true)][string]$EnvironmentName,
        [Parameter(Mandatory = $true)][string]$Image,
        [Parameter(Mandatory = $true)][int]$TargetPort,
        [Parameter(Mandatory = $true)][string]$Ingress,
        [Parameter(Mandatory = $false)][hashtable]$EnvironmentVariables = @{},
        [Parameter(Mandatory = $false)][string]$RegistryServer = '',
        [Parameter(Mandatory = $false)][string]$RegistryUsername = '',
        [Parameter(Mandatory = $false)][string]$RegistryPassword = ''
    )

    $exists = Test-ContainerAppExists -Name $Name -ResourceGroup $ResourceGroup
    $envArgs = @()
    foreach ($key in $EnvironmentVariables.Keys) {
        $envArgs += "${key}=$($EnvironmentVariables[$key])"
    }

    if (-not $exists) {
        $createArgs = @(
            'containerapp', 'create',
            '--name', $Name,
            '--resource-group', $ResourceGroup,
            '--environment', $EnvironmentName,
            '--image', $Image,
            '--ingress', $Ingress,
            '--target-port', $TargetPort,
            '--registry-server', $RegistryServer,
            '--registry-username', $RegistryUsername,
            '--registry-password', $RegistryPassword
        )

        if ($envArgs.Count -gt 0) {
            $createArgs += '--env-vars'
            $createArgs += $envArgs
        }

        Invoke-Az -Arguments $createArgs -FailureMessage "Failed to create container app $Name"
        return
    }

    $updateArgs = @(
        'containerapp', 'update',
        '--name', $Name,
        '--resource-group', $ResourceGroup,
        '--image', $Image
    )

    # Some az containerapp update versions don't accept --ingress/--target-port flags.
    # Use --set to modify configuration.ingress when needed.
    if ($Ingress) {
        $ingressExternal = ($Ingress -eq 'external') -as [bool]
        $ingressExternalStr = if ($ingressExternal) { 'true' } else { 'false' }
        $updateArgs += '--set'
        $updateArgs += "configuration.ingress.external=$ingressExternalStr"
        $updateArgs += "configuration.ingress.targetPort=$TargetPort"
    }

    if ($envArgs.Count -gt 0) {
        $updateArgs += '--set-env-vars'
        $updateArgs += $envArgs
    }

    Invoke-Az -Arguments $updateArgs -FailureMessage "Failed to update container app $Name"
}

function Get-ContainerAppFqdn {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ResourceGroup
    )

    return (az containerapp show --name $Name --resource-group $ResourceGroup --query properties.configuration.ingress.fqdn -o tsv)
}

function Wait-ForContainerAppFqdn {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ResourceGroup,
        [int]$TimeoutMinutes = 10
    )

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    Write-Host "Waiting up to $TimeoutMinutes minutes for container app '$Name' FQDN..."
    while ((Get-Date) -lt $deadline) {
        try {
            $state = az containerapp show --name $Name --resource-group $ResourceGroup --query properties.provisioningState -o tsv 2>$null
            $fqdn = az containerapp show --name $Name --resource-group $ResourceGroup --query properties.configuration.ingress.fqdn -o tsv 2>$null
            if (-not [string]::IsNullOrWhiteSpace($fqdn) -and $fqdn -ne 'None') {
                Write-Host "Container app '$Name' FQDN: $fqdn (state: $state)"
                return $fqdn.Trim()
            }
            Write-Host "Status for '$Name': $state; FQDN not yet available, retrying..."
        } catch {
            Write-Host "Transient error checking container app '$Name' (will retry): $($_.Exception.Message)"
        }
        Start-Sleep -Seconds 15
    }
    Write-Host "Timed out waiting for FQDN of '$Name'"
    return ''
}

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$envFile = Join-Path $repoRoot '.env'
if (Test-Path $envFile) {
    foreach ($rawLine in Get-Content $envFile) {
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith('#')) {
            continue
        }

        $parts = $line -split '=', 2
        if ($parts.Count -eq 2) {
            [Environment]::SetEnvironmentVariable($parts[0].Trim(), $parts[1].Trim())
        }
    }
}

$rg = Get-EnvValue -Name 'AZURE_RESOURCE_GROUP' -DefaultValue 'azure-app-rg'
$location = Get-EnvValue -Name 'AZURE_LOCATION' -DefaultValue 'francecentral'
$lawName = Get-EnvValue -Name 'AZURE_LOG_ANALYTICS_WORKSPACE' -DefaultValue 'azure-app-law'
$envName = Get-EnvValue -Name 'AZURE_CONTAINERAPPS_ENVIRONMENT' -DefaultValue 'azure-app-env'
$acrLoginServer = Get-EnvValue -Name 'ACR_LOGIN_SERVER'
$acrUser = Get-EnvValue -Name 'ACR_USERNAME'
$acrPass = Get-EnvValue -Name 'ACR_PASSWORD'
$databaseUrl = Get-EnvValue -Name 'DATABASE_URL'
$storageConnectionString = Get-EnvValue -Name 'AZURE_STORAGE_CONNECTION_STRING'
$storageContainer = Get-EnvValue -Name 'AZURE_STORAGE_CONTAINER' -DefaultValue 'uploads'
$backendApp = Get-EnvValue -Name 'BACKEND_APP_NAME' -DefaultValue 'azure-app-backend'
$frontendApp = Get-EnvValue -Name 'FRONTEND_APP_NAME' -DefaultValue 'azure-app-frontend'
$nginxApp = Get-EnvValue -Name 'NGINX_APP_NAME' -DefaultValue 'azure-app-nginx'
$imageTag = Get-EnvValue -Name 'IMAGE_TAG' -DefaultValue 'latest'

$requiredValues = @{
    ACR_LOGIN_SERVER = $acrLoginServer
    ACR_USERNAME = $acrUser
    ACR_PASSWORD = $acrPass
    DATABASE_URL = $databaseUrl
    AZURE_STORAGE_CONNECTION_STRING = $storageConnectionString
}

foreach ($entry in $requiredValues.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace($entry.Value)) {
        throw "Missing required value for $($entry.Key). Set it as an environment variable or in .env before running the script."
    }
}

az extension add --name containerapp --upgrade --yes | Out-Null

Ensure-ResourceProviderRegistered -Namespace 'Microsoft.OperationalInsights'
Ensure-ResourceProviderRegistered -Namespace 'Microsoft.App'

$rgExists = $false
$rgCurrentLocation = $location
$rgQuery = az group show --name $rg --query location -o tsv 2>$null
if (-not [string]::IsNullOrWhiteSpace($rgQuery)) {
    $rgExists = $true
    $rgCurrentLocation = $rgQuery.Trim()
}

if ($rgExists) {
    $location = $rgCurrentLocation
    Write-Host "Using existing resource group $rg in $location"
} else {
    Write-Host "Deploying Container Apps to resource group $rg in $location"
    Invoke-Az -Arguments @('group', 'create', '--name', $rg, '--location', $location) -FailureMessage 'Failed to create resource group.'
}

$workspaceId = az monitor log-analytics workspace show -g $rg -n $lawName --query customerId -o tsv 2>$null
$workspaceKey = az monitor log-analytics workspace get-shared-keys -g $rg -n $lawName --query primarySharedKey -o tsv 2>$null
if ([string]::IsNullOrWhiteSpace($workspaceId) -or [string]::IsNullOrWhiteSpace($workspaceKey)) {
    Invoke-Az -Arguments @('monitor', 'log-analytics', 'workspace', 'create', '-g', $rg, '-n', $lawName, '-l', $location) -FailureMessage 'Failed to create Log Analytics workspace.'
    $workspaceId = az monitor log-analytics workspace show -g $rg -n $lawName --query customerId -o tsv
    $workspaceKey = az monitor log-analytics workspace get-shared-keys -g $rg -n $lawName --query primarySharedKey -o tsv
}

$envId = az containerapp env show --name $envName --resource-group $rg --query id -o tsv 2>$null
if ([string]::IsNullOrWhiteSpace($envId)) {
    Invoke-Az -Arguments @('containerapp', 'env', 'create', '--name', $envName, '--resource-group', $rg, '--location', $location, '--logs-workspace-id', $workspaceId, '--logs-workspace-key', $workspaceKey) -FailureMessage 'Failed to create Container Apps environment.'
}

Set-ContainerApp `
    -Name $backendApp `
    -ResourceGroup $rg `
    -EnvironmentName $envName `
    -Image "$acrLoginServer/azure-app-backend:$imageTag" `
    -TargetPort 5000 `
    -Ingress 'external' `
    -RegistryServer $acrLoginServer `
    -RegistryUsername $acrUser `
    -RegistryPassword $acrPass `
    -EnvironmentVariables @{
        PORT = '5000'
        DATABASE_URL = $databaseUrl
        AZURE_STORAGE_CONNECTION_STRING = $storageConnectionString
        AZURE_STORAGE_CONTAINER = $storageContainer
    }

$backendFqdn = Wait-ForContainerAppFqdn -Name $backendApp -ResourceGroup $rg -TimeoutMinutes 10
if ([string]::IsNullOrWhiteSpace($backendFqdn)) {
    throw 'Could not resolve backend FQDN after deployment.'
}

Set-ContainerApp `
    -Name $frontendApp `
    -ResourceGroup $rg `
    -EnvironmentName $envName `
    -Image "$acrLoginServer/azure-app-frontend:$imageTag" `
    -TargetPort 80 `
    -Ingress 'external' `
    -RegistryServer $acrLoginServer `
    -RegistryUsername $acrUser `
    -RegistryPassword $acrPass

Set-ContainerApp `
    -Name $frontendApp `
    -ResourceGroup $rg `
    -EnvironmentName $envName `
    -Image "$acrLoginServer/azure-app-frontend:$imageTag" `
    -TargetPort 80 `
    -Ingress 'external' `
    -RegistryServer $acrLoginServer `
    -RegistryUsername $acrUser `
    -RegistryPassword $acrPass `
    -EnvironmentVariables @{
        API_BASE_URL = "https://$backendFqdn"
    }

$frontendFqdn = Wait-ForContainerAppFqdn -Name $frontendApp -ResourceGroup $rg -TimeoutMinutes 10
if ([string]::IsNullOrWhiteSpace($frontendFqdn)) {
    throw 'Could not resolve backend or frontend FQDN after deployment.'
}

Set-ContainerApp `
    -Name $nginxApp `
    -ResourceGroup $rg `
    -EnvironmentName $envName `
    -Image "$acrLoginServer/azure-app-nginx:$imageTag" `
    -TargetPort 80 `
    -Ingress 'external' `
    -RegistryServer $acrLoginServer `
    -RegistryUsername $acrUser `
    -RegistryPassword $acrPass `
    -EnvironmentVariables @{
        BACKEND_URL = "https://$backendFqdn/"
        FRONTEND_URL = "https://$frontendFqdn/"
    }

Write-Host 'Deployment submitted successfully.'
