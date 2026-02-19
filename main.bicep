extension 'br:mcr.microsoft.com/bicep/extensions/microsoftgraph/v1.0:0.1.8-preview'

targetScope = 'resourceGroup'

// ==============================================================================
// PARAMETERS
// ==============================================================================

@description('The location for all resources. Defaults to resource group location.')
param location string = resourceGroup().location

@description('The name of the environment (e.g. "prod", "dev").')
param environmentName string

@description('The size of the VM. Defaults to Standard_B2s.')
param vmSku string = 'Standard_B2s'

@description('The SKU of the SQL Database. Defaults to Basic.')
param sqlSku string = 'Basic'

@description('SSH Public Key for the VM Admin.')
@secure()
param adminPublicKey string

@description('IP Address allowed to SSH to the VM. Must be a valid CIDR range (e.g. 1.2.3.4/32).')
param adminIpAddress string

@description('SQL Admin Password. Must be secure and persistent.')
@secure()
param sqlAdminPassword string

@description('Redmine Secret Key base (hex string). Must be generated once and persistent.')
@secure()
param redmineSecretKey string

@description('Entra App Client Secret. Must be valid for the App Registration created/used.')
@secure()
param entraClientSecret string

@description('Admin username for the VM.')
param adminUsername string = 'azureuser'

@description('URL of the install script to execute on the VM.')
param installScriptUrl string = 'https://github.com/Santi9090/redmine-bicep-azure-Level2/blob/main/redmine-bicepv2.sh'

@description('Base64 encoded SSL Certificate data for App Gateway. PFX format.')
@secure()
param appGatewayCertData string = ''

@description('Password for the SSL Certificate.')
@secure()
param appGatewayCertPassword string = ''

// ==============================================================================
// VARIABLES
// ==============================================================================

var tenantId = subscription().tenantId
var uniqueSuffix = uniqueString(resourceGroup().id) // Deterministic, not time-based

// Resource Names
var vnetName = '${environmentName}-vnet'
var nsgName = '${environmentName}-nsg-vm'
var appGwName = '${environmentName}-appgw'
var appGwPipName = '${environmentName}-appgw-pip'
var vmName = '${environmentName}-vm'
var nicName = '${environmentName}-nic'
var sqlServerName = '${environmentName}-sql-${uniqueSuffix}'
var sqlDbName = '${environmentName}-redmine-db'
var kvName = 'kv-${uniqueString(resourceGroup().id, environmentName)}' // Max 24 chars
var logAnalyticsName = '${environmentName}-law-${uniqueSuffix}'
var appRegistrationName = '${environmentName}-redmine-app'

// Subnets
var subnetAppGwName = 'Subnet-AppGateway'
var subnetVmName = 'Subnet-VM'
var subnetPrivateEndpointsName = 'Subnet-PrivateEndpoints'

var subnetAppGwPrefix = '10.0.0.0/24'
var subnetVmPrefix = '10.0.1.0/24'
var subnetPrivateEndpointsPrefix = '10.0.2.0/24'

// ==============================================================================
// RESOURCES: LOGGING & MONITORING
// ==============================================================================

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: logAnalyticsName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// ==============================================================================
// RESOURCES: NETWORK
// ==============================================================================

resource nsgVm 'Microsoft.Network/networkSecurityGroups@2023-04-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowAppGwHTTP'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '80'
          sourceAddressPrefix: subnetAppGwPrefix
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowSSHAuthenticated'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: adminIpAddress
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'DenyAllInbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-04-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: subnetAppGwName
        properties: {
          addressPrefix: subnetAppGwPrefix
        }
      }
      {
        name: subnetVmName
        properties: {
          addressPrefix: subnetVmPrefix
          networkSecurityGroup: {
            id: nsgVm.id
          }
        }
      }
      {
        name: subnetPrivateEndpointsName
        properties: {
          addressPrefix: subnetPrivateEndpointsPrefix
        }
      }
    ]
  }
}

// ==============================================================================
// RESOURCES: KEY VAULT
// ==============================================================================

resource keyVault 'Microsoft.KeyVault/vaults@2023-02-01' = {
  name: kvName
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    enablePurgeProtection: true
  }
}

resource kvDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'kv-diag'
  scope: keyVault
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      {
        category: 'AuditEvent'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// ==============================================================================
// RESOURCES: APP GATEWAY
// ==============================================================================

resource appGwPip 'Microsoft.Network/publicIPAddresses@2023-04-01' = {
  name: appGwPipName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: toLower('${environmentName}-${uniqueSuffix}')
    }
  }
}

resource appGateway 'Microsoft.Network/applicationGateways@2023-04-01' = {
  name: appGwName
  location: location
  properties: {
    sku: {
      name: 'WAF_v2'
      tier: 'WAF_v2'
    }
    sslCertificates: !empty(appGatewayCertData)
      ? [
          {
            name: 'appGwSslCert'
            properties: {
              data: appGatewayCertData
              password: appGatewayCertPassword
            }
          }
        ]
      : []
    gatewayIPConfigurations: [
      {
        name: 'appGatewayIpConfig'
        properties: {
          subnet: {
            id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, subnetAppGwName)
          }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'appGatewayFrontendIP'
        properties: {
          publicIPAddress: {
            id: appGwPip.id
          }
        }
      }
    ]
    frontendPorts: [
      {
        name: 'port_80'
        properties: {
          port: 80
        }
      }
      {
        name: 'port_443'
        properties: {
          port: 443
        }
      }
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
          backendAddresses: [] // Empty, filled by NIC association
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
          requestTimeout: 20
          probe: {
            id: resourceId('Microsoft.Network/applicationGateways/probes', appGwName, 'redmineProbe')
          }
        }
      }
    ]
    httpListeners: [
      {
        name: 'listener_80'
        properties: {
          frontendIPConfiguration: {
            id: resourceId(
              'Microsoft.Network/applicationGateways/frontendIPConfigurations',
              appGwName,
              'appGatewayFrontendIP'
            )
          }
          frontendPort: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', appGwName, 'port_80')
          }
          protocol: 'Http'
        }
      }
      {
        name: 'listener_443'
        properties: {
          frontendIPConfiguration: {
            id: resourceId(
              'Microsoft.Network/applicationGateways/frontendIPConfigurations',
              appGwName,
              'appGatewayFrontendIP'
            )
          }
          frontendPort: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', appGwName, 'port_443')
          }
          protocol: 'Https'
          sslCertificate: {
            id: resourceId('Microsoft.Network/applicationGateways/sslCertificates', appGwName, 'appGwSslCert')
          }
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'redirect_80_to_443'
        properties: {
          ruleType: 'Basic'
          httpListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', appGwName, 'listener_80')
          }
          redirectConfiguration: {
            id: resourceId('Microsoft.Network/applicationGateways/redirectConfigurations', appGwName, 'redirectconfig')
          }
        }
      }
      {
        name: 'rule_443'
        properties: {
          ruleType: 'Basic'
          httpListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', appGwName, 'listener_443')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', appGwName, 'redmineBackendPool')
          }
          backendHttpSettings: {
            id: resourceId(
              'Microsoft.Network/applicationGateways/backendHttpSettingsCollection',
              appGwName,
              'redmineHttpSettings'
            )
          }
        }
      }
    ]
    redirectConfigurations: [
      {
        name: 'redirectconfig'
        properties: {
          redirectType: 'Permanent'
          targetListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', appGwName, 'listener_443')
          }
          includePath: true
          includeQueryString: true
        }
      }
    ]
    webApplicationFirewallConfiguration: {
      enabled: true
      firewallMode: 'Prevention'
      ruleSetType: 'OWASP'
      ruleSetVersion: '3.2'
    }
    autoscaleConfiguration: {
      minCapacity: 1
      maxCapacity: 2
    }
  }
  dependsOn: [
    vnet
  ]
}

resource appGwDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'appgw-diag'
  scope: appGateway
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      {
        category: 'ApplicationGatewayAccessLog'
        enabled: true
      }
      {
        category: 'ApplicationGatewayFirewallLog'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// ==============================================================================
// RESOURCES: MICROSOFT GRAPH (ENTRA ID)
// ==============================================================================
// Se usa la extensión de Microsoft Graph desde el registry público de Bicep.
// Requiere que el principal que ejecuta el deploy tenga el rol
// 'Application Administrator' en Microsoft Entra ID.

resource appReg 'Microsoft.Graph/applications@v1.0' = {
  displayName: appRegistrationName
  uniqueName: appRegistrationName
  web: {
    redirectUris: [
      'https://${appGwPip.properties.dnsSettings.fqdn}/auth/oidc/callback'
    ]
    implicitGrantSettings: {
      enableIdTokenIssuance: true
    }
  }
  passwordCredentials: [
    {
      displayName: 'redmine-secret'
      endDateTime: '2099-12-31T23:59:59Z'
    }
  ]
}

resource sp 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: appReg.appId
}

// ==============================================================================
// RESOURCES: DEPLOYMENT IDENTITY + SCRIPT (CONFIGURA EL SECRET AUTOMÁTICAMENTE)
// ==============================================================================
// La Graph API no permite asignar el texto del secreto declarativamente.
// Este deploymentScript corre 'az ad app credential reset' después de que
// el App Registration es creado, configurando el secreto exacto en Microsoft.
//
// REQUISITO PREVIO (una sola vez, antes del primer deploy):
//   az identity create --name <deployIdentityName> --resource-group <RG>
//   az role assignment create --assignee <principalId> \
//     --role "Application Administrator" --scope /
//   (o en el portal: Entra ID > Roles > Application Administrator > Assign)

resource deployIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${environmentName}-deploy-identity'
  location: location
}

resource configureAppSecret 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: '${environmentName}-configure-app-secret'
  location: location
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${deployIdentity.id}': {}
    }
  }
  properties: {
    azCliVersion: '2.52.0'
    retentionInterval: 'P1D'
    timeout: 'PT10M'
    cleanupPreference: 'OnSuccess'
    environmentVariables: [
      { name: 'APP_ID', value: appReg.appId }
      { name: 'APP_SECRET', secureValue: entraClientSecret }
    ]
    scriptContent: '''
      set -e
      az ad app credential reset \
        --id "$APP_ID" \
        --password "$APP_SECRET" \
        --display-name "redmine-secret" \
        --end-date "2099-12-31" \
        --append
      echo "Secreto configurado correctamente para App ID: $APP_ID"
    '''
  }
  dependsOn: [
    sp
  ]
}

// ==============================================================================
// RESOURCES: SQL DATABASE
// ==============================================================================

resource sqlServer 'Microsoft.Sql/servers@2022-11-01-preview' = {
  name: sqlServerName
  location: location
  properties: {
    administratorLogin: 'sqladmin'
    administratorLoginPassword: sqlAdminPassword
    publicNetworkAccess: 'Disabled'
  }
}

resource sqlDb 'Microsoft.Sql/servers/databases@2022-11-01-preview' = {
  parent: sqlServer
  name: sqlDbName
  location: location
  sku: {
    name: sqlSku
  }
}

resource sqlDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'sql-diag'
  scope: sqlDb
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      {
        category: 'SQLSecurityAuditEvents'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'Basic'
        enabled: true
      }
    ]
  }
}

resource privateEndpointSql 'Microsoft.Network/privateEndpoints@2023-04-01' = {
  name: '${environmentName}-sql-pe'
  location: location
  properties: {
    subnet: {
      id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, subnetPrivateEndpointsName)
    }
    privateLinkServiceConnections: [
      {
        name: '${environmentName}-sql-plsc'
        properties: {
          privateLinkServiceId: sqlServer.id
          groupIds: [
            'sqlServer'
          ]
        }
      }
    ]
  }
  dependsOn: [
    vnet
  ]
}

#disable-next-line no-hardcoded-env-urls
resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  #disable-next-line no-hardcoded-env-urls
  name: 'privatelink.database.windows.net'
  location: 'global'
}

resource privateDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: '${vnetName}-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

resource privateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-04-01' = {
  parent: privateEndpointSql
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        #disable-next-line no-hardcoded-env-urls
        name: 'privatelink.database.windows.net'
        properties: {
          privateDnsZoneId: privateDnsZone.id
        }
      }
    ]
  }
}

// ==============================================================================
// RESOURCES: SECRETS (STORED IN KEY VAULT)
// ==============================================================================

resource secretSqlAdmin 'Microsoft.KeyVault/vaults/secrets@2023-02-01' = {
  parent: keyVault
  name: 'sql-admin-password'
  properties: {
    value: sqlAdminPassword
  }
}

resource secretRedmineKey 'Microsoft.KeyVault/vaults/secrets@2023-02-01' = {
  parent: keyVault
  name: 'redmine-secret-key'
  properties: {
    value: redmineSecretKey
  }
}

resource secretClientId 'Microsoft.KeyVault/vaults/secrets@2023-02-01' = {
  parent: keyVault
  name: 'entra-client-id'
  properties: {
    value: appReg.appId
  }
}

resource secretClientSecret 'Microsoft.KeyVault/vaults/secrets@2023-02-01' = {
  parent: keyVault
  name: 'entra-client-secret'
  properties: {
    value: entraClientSecret
  }
}

resource secretTenantId 'Microsoft.KeyVault/vaults/secrets@2023-02-01' = {
  parent: keyVault
  name: 'tenant-id'
  properties: {
    value: tenantId
  }
}

// ==============================================================================
// RESOURCES: VIRTUAL MACHINE
// ==============================================================================

resource nic 'Microsoft.Network/networkInterfaces@2023-04-01' = {
  name: nicName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, subnetVmName)
          }
          applicationGatewayBackendAddressPools: [
            {
              id: resourceId(
                'Microsoft.Network/applicationGateways/backendAddressPools',
                appGwName,
                'redmineBackendPool'
              )
            }
          ]
        }
      }
    ]
  }
  dependsOn: [
    vnet
    appGateway
  ]
}

resource vm 'Microsoft.Compute/virtualMachines@2023-03-01' = {
  name: vmName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSku
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/azureuser/.ssh/authorized_keys'
              keyData: adminPublicKey
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
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
  dependsOn: [
    keyVault
  ]
}

// Role Assignment: VM Identity -> Key Vault Secrets User
resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, vm.id, 'KeyVaultSecretsUser')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '4633458b-17de-408a-b874-0445c86b69e6'
    ) // Key Vault Secrets User
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
    settings: {
      fileUris: [
        installScriptUrl
      ]
    }
    protectedSettings: {
      // Pass arguments: KeyVaultName, SQLFQDN, DBName, TenantID, ClientID
      // Validated against requirement: Only pass Key Vault name, SQL FQDN, DB name, Tenant ID, Client ID
      commandToExecute: 'sh install.sh ${kvName} ${sqlServer.properties.fullyQualifiedDomainName} ${sqlDbName} ${tenantId} ${appReg.appId}'
    }
  }
  dependsOn: [
    roleAssignment
    secretSqlAdmin
    secretRedmineKey
    secretClientSecret
    secretClientId
    secretTenantId
    sqlDb
    sp
  ]
}

// ==============================================================================
// OUTPUTS
// ==============================================================================

output appGatewayPublicUrl string = 'https://${appGwPip.properties.dnsSettings.fqdn}'
output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName
output keyVaultName string = keyVault.name
output tenantId string = tenantId
output appClientId string = appReg.appId
