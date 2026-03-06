targetScope = 'resourceGroup'

@description('The location for all resources. Defaults to resource group location.')
param location string = resourceGroup().location

@description('The name of the environment (e.g. "prod", "dev", "staging").')
@minLength(3)
@maxLength(20)
param environmentName string

@description('The size of the VM. Defaults to Standard_B2s.')
param vmSku string = 'Standard_B2s'

@description('The SKU of the SQL Database. Defaults to Basic.')
param sqlSku string = 'Basic'

@description('IP Address range allowed for administrative access. CIDR format (e.g., 203.0.113.0/24).')
param adminIpAddress string

@description('Admin username for VM SSH access.')
param adminUsername string = 'azureuser'

@description('URL of the Redmine installation script. Must be publicly accessible.')
param installScriptUrl string = 'https://raw.githubusercontent.com/Santi9090/redmine-bicep-azure-Level2/main/redmine-bicepv2.sh'

@description('Enable WAF on Application Gateway for production deployments.')
param enableWaf bool = true

@description('Retention days for Log Analytics diagnostics.')
param logAnalyticsRetentionInDays int = 30

param tenantId string

@secure()
param entraClientId string
@secure()
param entraClientSecret string
@secure()
param sqlAdminPassword string
@secure()
param redmineSecretKey string
@secure()
param sshPublicKey string
@secure()
param sshPrivateKey string
@secure()
param appGwSslCertB64 string

param appGwDomainLabel string

var uniqueSuffix = substring(uniqueString(subscription().subscriptionId, resourceGroup().id), 0, 8)
var rawKvName = 'kv${uniqueString(resourceGroup().id, environmentName)}'
var kvName = length(rawKvName) > 24 ? substring(rawKvName, 0, 24) : rawKvName

var vnetName = '${environmentName}-vnet'
var nsgName = '${environmentName}-nsg-vm'
var appGwName = '${environmentName}-appgw'
var appGwPipName = '${environmentName}-appgw-pip'
var vmName = '${environmentName}-vm'
var nicName = '${environmentName}-nic'
var sqlServerName = '${environmentName}-sql-${uniqueSuffix}'
var sqlDbName = '${environmentName}-redmine-db'
var logAnalyticsName = '${environmentName}-law-${uniqueSuffix}'

var subnetAppGwName = 'Subnet-AppGateway'
var subnetVmName = 'Subnet-VM'
var subnetPrivateEndpointsName = 'Subnet-PrivateEndpoints'

var vnetAddressSpace = '10.0.0.0/16'
var subnetAppGwPrefix = '10.0.0.0/24'
var subnetVmPrefix = '10.0.1.0/24'
var subnetPrivateEndpointsPrefix = '10.0.2.0/24'

var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

var commonTags = {
  environment: environmentName
  createdBy: 'Bicep'
  managedBy: 'Infrastructure-as-Code'
  complianceFramework: 'Zero-Trust'
}

// ==============================================================================
// LOGGING & MONITORING
// ==============================================================================
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: logAnalyticsName
  location: location
  tags: commonTags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: logAnalyticsRetentionInDays
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// ==============================================================================
// STEP 4: INFRASTRUCTURE (Network, NSG, PIP, Key Vault)
// ==============================================================================
resource nsgVm 'Microsoft.Network/networkSecurityGroups@2023-04-01' = {
  name: nsgName
  location: location
  tags: commonTags
  properties: {
    securityRules: [
      {
        name: 'AllowAppGwInboundHttp'
        properties: {
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '80'
          access: 'Allow'
          priority: 100
          direction: 'Inbound'
          sourceAddressPrefix: subnetAppGwPrefix
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowSSHFromAdminIp'
        properties: {
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          access: 'Allow'
          priority: 110
          direction: 'Inbound'
          sourceAddressPrefix: adminIpAddress
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'DenyAllOtherInbound'
        properties: {
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          access: 'Deny'
          priority: 4096
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource nsgAppGw 'Microsoft.Network/networkSecurityGroups@2023-04-01' = {
  name: '${environmentName}-nsg-appgw'
  location: location
  tags: commonTags
  properties: {
    securityRules: [
      {
        name: 'AllowInternetInboundHttp'
        properties: {
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '80'
          access: 'Allow'
          priority: 100
          direction: 'Inbound'
          sourceAddressPrefix: 'Internet'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowInternetInboundHttps'
        properties: {
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          access: 'Allow'
          priority: 105
          direction: 'Inbound'
          sourceAddressPrefix: 'Internet'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowGatewayManager'
        properties: {
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '65200-65535'
          access: 'Allow'
          priority: 110
          direction: 'Inbound'
          sourceAddressPrefix: 'GatewayManager'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-04-01' = {
  name: vnetName
  location: location
  tags: commonTags
  properties: {
    addressSpace: { addressPrefixes: [ vnetAddressSpace ] }
    subnets: [
      {
        name: subnetAppGwName
        properties: {
          addressPrefix: subnetAppGwPrefix
          networkSecurityGroup: { id: nsgAppGw.id }
        }
      }
      {
        name: subnetVmName
        properties: {
          addressPrefix: subnetVmPrefix
          networkSecurityGroup: { id: nsgVm.id }
        }
      }
      {
        name: subnetPrivateEndpointsName
        properties: {
          addressPrefix: subnetPrivateEndpointsPrefix
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

resource appGwPip 'Microsoft.Network/publicIPAddresses@2023-04-01' = {
  name: appGwPipName
  location: location
  tags: commonTags
  sku: { name: 'Standard', tier: 'Regional' }
  properties: {
    publicIPAllocationMethod: 'Static'
    idleTimeoutInMinutes: 4
    dnsSettings: {
      domainNameLabel: appGwDomainLabel
    }
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-02-01' = {
  name: kvName
  location: location
  tags: commonTags
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: true
    publicNetworkAccess: 'Enabled'
    networkAcls: { defaultAction: 'Allow', bypass: 'AzureServices' }
  }
}

// ==============================================================================
// STEP 5: GENERATE KEY VAULT SECRETS
// ==============================================================================
resource kvAppGwCert 'Microsoft.KeyVault/vaults/secrets@2023-02-01' = {
  parent: keyVault
  name: 'appgw-ssl-cert'
  properties: {
    value: appGwSslCertB64
    contentType: 'application/x-pkcs12'
  }
}
resource kvSqlPwd 'Microsoft.KeyVault/vaults/secrets@2023-02-01' = {
  parent: keyVault
  name: 'sql-admin-password'
  properties: { value: sqlAdminPassword }
}
resource kvRedmineKey 'Microsoft.KeyVault/vaults/secrets@2023-02-01' = {
  parent: keyVault
  name: 'redmine-secret-key'
  properties: { value: redmineSecretKey }
}
resource kvEntraClientId 'Microsoft.KeyVault/vaults/secrets@2023-02-01' = {
  parent: keyVault
  name: 'entra-client-id'
  properties: { value: entraClientId }
}
resource kvEntraClientSecret 'Microsoft.KeyVault/vaults/secrets@2023-02-01' = {
  parent: keyVault
  name: 'entra-client-secret'
  properties: { value: entraClientSecret }
}
resource kvSshPub 'Microsoft.KeyVault/vaults/secrets@2023-02-01' = {
  parent: keyVault
  name: 'ssh-public-key'
  properties: { value: sshPublicKey }
}
resource kvSshPriv 'Microsoft.KeyVault/vaults/secrets@2023-02-01' = {
  parent: keyVault
  name: 'ssh-private-key'
  properties: { value: sshPrivateKey }
}

// ==============================================================================
// STEP 6: SQL DATABASE
// ==============================================================================
resource sqlServer 'Microsoft.Sql/servers@2022-11-01-preview' = {
  name: sqlServerName
  location: location
  tags: commonTags
  identity: { type: 'SystemAssigned' }
  properties: {
    administratorLogin: 'sqladmin'
    administratorLoginPassword: sqlAdminPassword // Secure param injection
    publicNetworkAccess: 'Disabled'
    minimalTlsVersion: '1.2'
  }
  dependsOn: [ kvSqlPwd ]
}

resource sqlDb 'Microsoft.Sql/servers/databases@2022-11-01-preview' = {
  parent: sqlServer
  name: sqlDbName
  location: location
  tags: commonTags
  sku: { name: sqlSku }
  properties: {
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    requestedBackupStorageRedundancy: 'Geo'
  }
}

// ==============================================================================
// STEP 7: PRIVATE ENDPOINT AND DNS
// ==============================================================================
resource privateEndpointSql 'Microsoft.Network/privateEndpoints@2023-04-01' = {
  name: '${environmentName}-sql-pe'
  location: location
  tags: commonTags
  properties: {
    subnet: {
      id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, subnetPrivateEndpointsName)
    }
    privateLinkServiceConnections: [
      {
        name: '${environmentName}-sql-plsc'
        properties: {
          privateLinkServiceId: sqlServer.id
          groupIds: [ 'sqlServer' ]
          requestMessage: 'Please approve this connection'
        }
      }
    ]
  }
  dependsOn: [ vnet ]
}

#disable-next-line no-hardcoded-env-urls
resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.database.windows.net'
  location: 'global'
  tags: commonTags
}

resource privateDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: '${vnetName}-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnet.id }
  }
}

resource privateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-04-01' = {
  parent: privateEndpointSql
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink.database.windows.net'
        properties: {
          privateDnsZoneId: privateDnsZone.id
        }
      }
    ]
  }
  dependsOn: [ privateDnsZoneLink ]
}

// ==============================================================================
// STEP 8: VM & INSTALL REDMINE
// ==============================================================================
resource nic 'Microsoft.Network/networkInterfaces@2023-04-01' = {
  name: nicName
  location: location
  tags: commonTags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, subnetVmName)
          }
        }
      }
    ]
    networkSecurityGroup: { id: nsgVm.id }
  }
  dependsOn: [ vnet ]
}

resource vm 'Microsoft.Compute/virtualMachines@2023-03-01' = {
  name: vmName
  location: location
  tags: commonTags
  identity: { type: 'SystemAssigned' }
  properties: {
    hardwareProfile: { vmSize: vmSku }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'Premium_LRS' }
        deleteOption: 'Delete'
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: { deleteOption: 'Detach', primary: true }
        }
      ]
    }
  }
  dependsOn: [ privateDnsZoneGroup, kvSshPub ]
}

// Role Assignment: VM to read Key Vault
resource roleAssignKvSecretsToVm 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, vm.id, keyVaultSecretsUserRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
    principalId: vm.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource vmExtension 'Microsoft.Compute/virtualMachines/extensions@2023-03-01' = {
  parent: vm
  name: 'install-redmine'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Extensions'
    type: 'CustomScript'
    typeHandlerVersion: '2.1'
    autoUpgradeMinorVersion: true
    protectedSettings: {
      fileUris: [ installScriptUrl ]
      commandToExecute: 'bash redmine-bicepv2.sh "${keyVault.name}" "${sqlServer.properties.fullyQualifiedDomainName}" "${sqlDbName}" "${tenantId}" "${entraClientId}" "${appGwPip.properties.dnsSettings.fqdn}"'
    }
  }
  dependsOn: [ roleAssignKvSecretsToVm ]
}

// ==============================================================================
// STEP 9: APPLICATION GATEWAY
// ==============================================================================
resource appGateway 'Microsoft.Network/applicationGateways@2023-04-01' = {
  name: appGwName
  location: location
  tags: commonTags
  properties: {
    sku: { name: 'WAF_v2', tier: 'WAF_v2' }
    sslCertificates: [
      {
        name: 'appGwSslCert'
        properties: {
          data: appGwSslCertB64 // Inject directly to bypass RBAC delay!
          password: ''
        }
      }
    ]
    gatewayIPConfigurations: [
      {
        name: 'appGatewayIpConfig'
        properties: {
          subnet: { id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, subnetAppGwName) }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'appGatewayFrontendIP'
        properties: {
          publicIPAddress: { id: appGwPip.id }
        }
      }
    ]
    frontendPorts: [
      { name: 'port_80', properties: { port: 80 } }
      { name: 'port_443', properties: { port: 443 } }
    ]
    probes: [
      {
        name: 'redmineProbe'
        properties: {
          protocol: 'Http'
          path: '/'
          interval: 30
          timeout: 30
          unhealthyThreshold: 3
          pickHostNameFromBackendHttpSettings: true
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'redmineBackendPool'
        properties: {
          backendAddresses: [
            { ipAddress: nic.properties.ipConfigurations[0].properties.privateIPAddress }
          ]
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'redmineHttpSettings'
        properties: {
          port: 80
          protocol: 'Http'
          cookieBasedAffinity: 'Disabled'
          connectionDraining: { enabled: true, drainTimeoutInSec: 60 }
          requestTimeout: 20
          probe: { id: resourceId('Microsoft.Network/applicationGateways/probes', appGwName, 'redmineProbe') }
        }
      }
    ]
    httpListeners: [
      {
        name: 'listener_80'
        properties: {
          frontendIPConfiguration: { id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', appGwName, 'appGatewayFrontendIP') }
          frontendPort: { id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', appGwName, 'port_80') }
          protocol: 'Http'
          requireServerNameIndication: false
        }
      }
      {
        name: 'listener_443'
        properties: {
          frontendIPConfiguration: { id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', appGwName, 'appGatewayFrontendIP') }
          frontendPort: { id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', appGwName, 'port_443') }
          protocol: 'Https'
          sslCertificate: { id: resourceId('Microsoft.Network/applicationGateways/sslCertificates', appGwName, 'appGwSslCert') }
          requireServerNameIndication: false
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'redirect_http_to_https'
        properties: {
          ruleType: 'Basic'
          httpListener: { id: resourceId('Microsoft.Network/applicationGateways/httpListeners', appGwName, 'listener_80') }
          redirectConfiguration: { id: resourceId('Microsoft.Network/applicationGateways/redirectConfigurations', appGwName, 'redirectConfigHttp') }
          priority: 1
        }
      }
      {
        name: 'rule_secure_redmine'
        properties: {
          ruleType: 'Basic'
          httpListener: { id: resourceId('Microsoft.Network/applicationGateways/httpListeners', appGwName, 'listener_443') }
          backendAddressPool: { id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', appGwName, 'redmineBackendPool') }
          backendHttpSettings: { id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', appGwName, 'redmineHttpSettings') }
          priority: 2
        }
      }
    ]
    redirectConfigurations: [
      {
        name: 'redirectConfigHttp'
        properties: {
          redirectType: 'Permanent'
          targetListener: { id: resourceId('Microsoft.Network/applicationGateways/httpListeners', appGwName, 'listener_443') }
          includePath: true
          includeQueryString: true
        }
      }
    ]
    webApplicationFirewallConfiguration: {
      enabled: enableWaf
      firewallMode: 'Prevention'
      ruleSetType: 'OWASP'
      ruleSetVersion: '3.2'
    }
  }
  dependsOn: [ vmExtension, vnet ]
}

// ==============================================================================
// OUTPUTS
// ==============================================================================
output appGatewayPublicUrl string = 'https://${appGwPip.properties.dnsSettings.fqdn}'
output appGatewayFqdn string = appGwPip.properties.dnsSettings.fqdn
output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName
output keyVaultName string = keyVault.name
output keyVaultId string = keyVault.id
output tenantId string = tenantId
output environmentName string = environmentName
output vmName string = vm.name
output redmineDbName string = sqlDbName
