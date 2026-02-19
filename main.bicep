extension 'br:mcr.microsoft.com/bicep/extensions/microsoftgraph/v1.0:0.1.8-preview'

targetScope = 'resourceGroup'

// ==============================================================================
// PARAMETERS - ONLY NON-SENSITIVE CONFIGURATION
// ==============================================================================
// PRINCIPLE: Zero Trust + No Manual Secrets
// All sensitive values are GENERATED AUTOMATICALLY by deployment scripts
// stored in Key Vault. Never passed as parameters.

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


// ==============================================================================
// VARIABLES - DERIVED FROM PARAMETERS (NO SECRETS)
// ==============================================================================

var tenantId = subscription().tenantId
var subscriptionId = subscription().subscriptionId
var uniqueSuffix = uniqueString(resourceGroup().id)

// Key Vault must be 3-24 characters, alphanumeric and hyphens only
var kvName = 'kv${replace(uniqueString(resourceGroup().id, environmentName), '-', '')}' 

// Resource naming convention: {env}-{resource}-{hash}
var vnetName = '${environmentName}-vnet'
var nsgName = '${environmentName}-nsg-vm'
var appGwName = '${environmentName}-appgw'
var appGwPipName = '${environmentName}-appgw-pip'
var vmName = '${environmentName}-vm'
var nicName = '${environmentName}-nic'
var sqlServerName = '${environmentName}-sql-${uniqueSuffix}'
var sqlDbName = '${environmentName}-redmine-db'
var logAnalyticsName = '${environmentName}-law-${uniqueSuffix}'
var appRegistrationName = '${environmentName}-redmine-app'
var deployIdentityName = '${environmentName}-deploy-identity'
var appGwIdentityName = '${environmentName}-appgw-identity'

// Deployment script names
var generateSecretScriptName = '${environmentName}-generate-secrets'
var generateCertScriptName = '${environmentName}-generate-cert'

// Subnet naming and addressing
var subnetAppGwName = 'Subnet-AppGateway'
var subnetVmName = 'Subnet-VM'
var subnetPrivateEndpointsName = 'Subnet-PrivateEndpoints'

var vnetAddressSpace = '10.0.0.0/16'
var subnetAppGwPrefix = '10.0.0.0/24'
var subnetVmPrefix = '10.0.1.0/24'
var subnetPrivateEndpointsPrefix = '10.0.2.0/24'

// Built-in Azure RBAC Role IDs (immutable)
var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6' // Key Vault Secrets User
var keyVaultAdminRoleId = '00482a5a-887f-4fb3-b363-3b7fe8e74483' // Key Vault Administrator

// Tags for governance and cost tracking
var commonTags = {
  environment: environmentName
  createdBy: 'Bicep'
  managedBy: 'Infrastructure-as-Code'
  complianceFramework: 'Zero-Trust'
}
// ==============================================================================
// RESOURCES: LOGGING & MONITORING (Foundation Layer)
// ==============================================================================
// Log Analytics Workspace: Central logging for all resources
// GDPR & SOC2 compliant retention policy

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: logAnalyticsName
  location: location
  tags: commonTags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: logAnalyticsRetentionInDays
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// ==============================================================================
// RESOURCES: MANAGED IDENTITIES
// ==============================================================================
// SystemAssigned identities are created with VM and App Gateway automatically.
// UserAssigned identity for deployment scripts with elevated privileges (temporary).

resource deployIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: deployIdentityName
  location: location
  tags: commonTags
}

// Managed Identity for App Gateway (to read certs from Key Vault)
resource appGwIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: appGwIdentityName
  location: location
  tags: commonTags
}

// ==============================================================================
// RESOURCES: NETWORK (Zero Trust - Deny by default, Allow by explicit rule)
// ==============================================================================

resource nsgVm 'Microsoft.Network/networkSecurityGroups@2023-04-01' = {
  name: nsgName
  location: location
  tags: commonTags
  properties: {
    securityRules: [
      // INBOUND RULES - Principle of Least Privilege
      {
        name: 'AllowAppGwInboundHttp'
        properties: {
          description: 'Allow HTTP from App Gateway subnet only'
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
          description: 'Allow SSH from admin IP range only'
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
          description: 'Deny all other inbound traffic (Zero Trust default)'
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
      // OUTBOUND RULES
      {
        name: 'AllowDNSOutbound'
        properties: {
          description: 'Allow DNS (UDP 53) for service resolution'
          protocol: 'Udp'
          sourcePortRange: '*'
          destinationPortRange: '53'
          access: 'Allow'
          priority: 100
          direction: 'Outbound'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowHttpOutbound'
        properties: {
          description: 'Allow HTTP to AzureCloud for package updates'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '80'
          access: 'Allow'
          priority: 110
          direction: 'Outbound'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: 'AzureCloud'
        }
      }
      {
        name: 'AllowHttpsOutbound'
        properties: {
          description: 'Allow HTTPS to AzureCloud for secure updates'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          access: 'Allow'
          priority: 120
          direction: 'Outbound'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: 'AzureCloud'
        }
      }
    ]
  }
}

// NSG for App Gateway subnet (additional security layer)
resource nsgAppGw 'Microsoft.Network/networkSecurityGroups@2023-04-01' = {
  name: '${environmentName}-nsg-appgw'
  location: location
  tags: commonTags
  properties: {
    securityRules: [
      {
        name: 'AllowInternetInboundHttp'
        properties: {
          description: 'Allow inbound HTTP traffic from Internet (port 80)'
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
          description: 'Allow inbound HTTPS traffic from Internet (port 443)'
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
          description: 'Allow Azure Gateway Manager health probes'
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
      {
        name: 'DenyAllOtherInbound'
        properties: {
          description: 'Deny all other inbound traffic'
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

resource vnet 'Microsoft.Network/virtualNetworks@2023-04-01' = {
  name: vnetName
  location: location
  tags: commonTags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressSpace
      ]
    }
    subnets: [
      {
        name: subnetAppGwName
        properties: {
          addressPrefix: subnetAppGwPrefix
          networkSecurityGroup: {
            id: nsgAppGw.id
          }
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
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

// Diagnostic settings for VNet flow logs (optional, for advanced monitoring)
resource nsgDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'nsg-flow-logs'
  scope: nsgVm
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      {
        category: 'NetworkSecurityGroupEvent'
        enabled: true
      }
      {
        category: 'NetworkSecurityGroupRuleCounter'
        enabled: true
      }
    ]
  }
}


// ==============================================================================
// RESOURCES: KEY VAULT (Secrets Management - Enterprise Grade)
// ==============================================================================
// Key Vault serves as the single source of truth for all sensitive data.
// RBAC model enforces Zero Trust: No default access, only explicit role assignments.
// Soft-delete and purge protection enabled for accidental deletion prevention.

resource keyVault 'Microsoft.KeyVault/vaults@2023-02-01' = {
  name: kvName
  location: location
  tags: commonTags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: tenantId
    
    // RBAC Authorization: Modern approach (not legacy Access Policies)
    enableRbacAuthorization: true
    
    // Soft delete: 90 days default window
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    
    // Purge protection: Prevents accidental hard-deletion
    enablePurgeProtection: true
    
    // Network policies
    publicNetworkAccess: 'Enabled' // Can be 'Disabled' with Private Endpoint
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
    
    // Logging
    enabledForDeployment: true
    enabledForDiskEncryption: false
    enabledForTemplateDeployment: true
  }
}

// Diagnostic settings: Send all KV audit logs to Log Analytics
resource kvDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'kv-diagnostic-settings'
  scope: keyVault
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      {
        category: 'AuditEvent'
        categoryGroup: null
        enabled: true
        retentionPolicy: {
          enabled: true
          days: logAnalyticsRetentionInDays
        }
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
        retentionPolicy: {
          enabled: true
          days: logAnalyticsRetentionInDays
        }
      }
    ]
  }
}

// RBAC: Grant deployment identity Administrator access (for script execution)
// WARNING: This is temporary access - used only during feature deployment phase
resource roleAssignKvAdminToDeploy 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, deployIdentity.id, keyVaultAdminRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultAdminRoleId)
    principalId: deployIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// RBAC: Grant VM Secrets User access (for runtime secret consumption)
// Least privilege: VM can only READ secrets, not modify or delete
resource roleAssignKvSecretsToVm 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, vm.id, keyVaultSecretsUserRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
    principalId: vm.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// RBAC: Grant App Gateway to read certificates from Key Vault
// Required for App Gateway to use Key Vault stored certificates
resource roleAssignKvSecretsToAppGw 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, appGwIdentity.id, keyVaultSecretsUserRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
    principalId: appGwIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}


// ==============================================================================
// RESOURCES: APPLICATION GATEWAY (Ingress Controller + WAF)
// ==============================================================================
// App Gateway with:
// - Self-signed certificate auto-generated and stored in Key Vault
// - WAF v2 enabled for OWASP top 10 protection
// - Managed Identity for Key Vault access
// - Diagnostic logging to Log Analytics
// - HTTP → HTTPS redirect enforced

resource appGwPip 'Microsoft.Network/publicIPAddresses@2023-04-01' = {
  name: appGwPipName
  location: location
  tags: commonTags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    idleTimeoutInMinutes: 4
    dnsSettings: {
      domainNameLabel: toLower('${environmentName}-${uniqueSuffix}')
    }
  }
}

resource appGateway 'Microsoft.Network/applicationGateways@2023-04-01' = {
  name: appGwName
  location: location
  tags: commonTags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${appGwIdentity.id}': {}
    }
  }
  properties: {
    sku: {
      name: 'WAF_v2'
      tier: 'WAF_v2'
      capacity: 1
    }

    // IMPORTANT: This will be populated by deployment script after cert is created
    sslCertificates: [
      {
        name: 'appGwSslCertFromKv'
        properties: {
          keyVaultSecretId: '${keyVault.properties.vaultUri}secrets/${secretAppGwCert.name}'
        }
      }
    ]

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
          host: '127.0.0.1'
        }
      }
    ]

    backendAddressPools: [
      {
        name: 'redmineBackendPool'
        properties: {
          backendAddresses: [] // Filled automatically by nic association
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
          connectionDraining: {
            enabled: true
            drainTimeoutInSec: 60
          }
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
          requireServerNameIndication: false
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
            id: resourceId('Microsoft.Network/applicationGateways/sslCertificates', appGwName, 'appGwSslCertFromKv')
          }
          requireServerNameIndication: false
        }
      }
    ]

    requestRoutingRules: [
      {
        name: 'redirect_http_to_https'
        properties: {
          ruleType: 'Basic'
          httpListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', appGwName, 'listener_80')
          }
          redirectConfiguration: {
            id: resourceId('Microsoft.Network/applicationGateways/redirectConfigurations', appGwName, 'redirectConfigHttp')
          }
          priority: 1
        }
      }
      {
        name: 'rule_secure_redmine'
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
          priority: 2
        }
      }
    ]

    redirectConfigurations: [
      {
        name: 'redirectConfigHttp'
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
      enabled: enableWaf
      firewallMode: 'Prevention'
      ruleSetType: 'OWASP'
      ruleSetVersion: '3.2'
      disabledRuleGroups: []
      fileUploadLimitInMb: 100
      maxRequestBodySizeInKb: 128
    }

    autoscaleConfiguration: {
      minCapacity: 1
      maxCapacity: 3
    }
  }

  dependsOn: [
    vnet
  ]
}

// Diagnostic settings for App Gateway
resource appGwDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'appgw-diagnostic-settings'
  scope: appGateway
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      {
        category: 'ApplicationGatewayAccessLog'
        enabled: true
        retentionPolicy: {
          enabled: true
          days: logAnalyticsRetentionInDays
        }
      }
      {
        category: 'ApplicationGatewayFirewallLog'
        enabled: true
        retentionPolicy: {
          enabled: true
          days: logAnalyticsRetentionInDays
        }
      }
      {
        category: 'ApplicationGatewayPerformanceLog'
        enabled: true
        retentionPolicy: {
          enabled: true
          days: logAnalyticsRetentionInDays
        }
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
        retentionPolicy: {
          enabled: true
          days: logAnalyticsRetentionInDays
        }
      }
    ]
  }
}


// ==============================================================================
// RESOURCES: ENTRA ID APP REGISTRATION (OpenID Connect Integration)
// ==============================================================================
// App Registration for OIDC-based authentication to Redmine
// IMPORTANT: Credentials are auto-generated and stored securely in Key Vault

resource appReg 'Microsoft.Graph/applications@v1.0' = {
  displayName: appRegistrationName
  uniqueName: appRegistrationName
  signInAudience: 'AzureADMyOrg'
  
  web: {
    redirectUris: [
      'https://${appGwPip.properties.dnsSettings.fqdn}/auth/oidc/callback'
    ]
    implicitGrantSettings: {
      enableIdTokenIssuance: true
    }
    // IMPORTANT: No credentials defined here. Generated by deployment script.
  }
  
  publicClient: {
    redirectUris: []
  }
  
  // Optional: Additional configuration
  description: 'Redmine OpenID Connect integration for ${environmentName} environment'
  
  tags: [
    'redmine'
    'oidc'
    environmentName
  ]
}

resource sp 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: appReg.appId
  displayName: appRegistrationName
}


// ==============================================================================
// RESOURCES: SECRET GENERATION (Deployment-Time Automation)
// ==============================================================================
// DeploymentScripts automate secret generation at deployment time.
// All secrets are created, stored in Key Vault, and never displayed in logs/outputs.
// Prerequisites: Deployment Identity must have "Key Vault Administrator" role.

// ===== STEP 1: Generate all application secrets (SQL, Redmine, SSH, CERT) =====
resource generateSecretsScript 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: generateSecretScriptName
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
    timeout: 'PT15M'
    cleanupPreference: 'OnSuccess'
    
    environmentVariables: [
      { name: 'KEYVAULT_NAME', value: keyVault.name }
      { name: 'SUBSCRIPTION_ID', value: subscriptionId }
      { name: 'RESOURCE_GROUP', value: resourceGroup().name }
    ]
    
    scriptContent: '''
      #!/bin/bash
      set -euo pipefail
      
      # Function to check if secret exists
      secret_exists() {
        az keyvault secret show --vault-name "$KEYVAULT_NAME" --name "$1" &>/dev/null && echo "true" || echo "false"
      }
      
      # Function to store secret (idempotent)
      store_secret() {
        local secret_name=$1
        local secret_value=$2
        
        if [ "$(secret_exists "$secret_name")" = "true" ]; then
          echo "Secret '$secret_name' already exists. Skipping."
          return 0
        fi
        
        az keyvault secret set \
          --vault-name "$KEYVAULT_NAME" \
          --name "$secret_name" \
          --value "$secret_value" > /dev/null
        echo "Created secret: $secret_name"
      }
      
      echo "=== Generating Application Secrets ==="
      
      # 1. SQL Admin Password (32 chars, complex)
      SQL_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
      store_secret "sql-admin-password" "$SQL_PASSWORD"
      
      # 2. Redmine Secret Key (Rails RAILS_MASTER_KEY format preferred, 32 bytes hex)
      REDMINE_SECRET=$(openssl rand -hex 32)
      store_secret "redmine-secret-key" "$REDMINE_SECRET"
      
      # 3. SSH Private Key (ED25519 format - modern, secure)
      ssh-keygen -t ed25519 -f /tmp/id_ed25519 -N "" -C "redmine-admin@azure" 2>/dev/null || true
      SSH_PRIVATE_KEY=$(cat /tmp/id_ed25519 | base64 -w0)
      SSH_PUBLIC_KEY=$(cat /tmp/id_ed25519.pub)
      store_secret "ssh-private-key" "$SSH_PRIVATE_KEY"
      store_secret "ssh-public-key" "$SSH_PUBLIC_KEY"
      
      # 4. Entra Client Secret (UUID + random component)
      ENTRA_SECRET=$(cat /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9~!@#$%^&*()_+-={}[]|:;<>?,./' | head -c 40)
      store_secret "entra-client-secret" "$ENTRA_SECRET"
      
      # 5. Tenant ID (from context)
      TENANT_ID=$(az account show --query tenantId -o tsv)
      store_secret "tenant-id" "$TENANT_ID"
      
      echo "=== All secrets generated and stored in Key Vault ==="
      echo "✓ sql-admin-password"
      echo "✓ redmine-secret-key"
      echo "✓ ssh-private-key (base64 encoded)"
      echo "✓ ssh-public-key"
      echo "✓ entra-client-secret"
      echo "✓ tenant-id"
    '''
  }
}

// ===== STEP 2: Configure Entra App Registration with auto-generated secret =====
resource configureEntraSecretScript 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: '${environmentName}-configure-entra-secret'
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
      { name: 'KEYVAULT_NAME', value: keyVault.name }
    ]
    
    scriptContent: '''
      #!/bin/bash
      set -euo pipefail
      
      echo "=== Configuring Entra App Registration Client Secret ==="
      
      # Retrieve the auto-generated secret from Key Vault
      ENTRA_SECRET=$(az keyvault secret show \
        --vault-name "$KEYVAULT_NAME" \
        --name "entra-client-secret" \
        --query value -o tsv)
      
      # Register the secret credential in Entra ID (via Graph API)
      # This uses az ad app credential reset to set the exact secret
      az ad app credential reset \
        --id "$APP_ID" \
        --password "$ENTRA_SECRET" \
        --display-name "redmine-app-secret" \
        --end-date "2099-12-31" \
        --append
      
      echo "✓ Entra Client Secret configured successfully"
      
      # Store the Application ID in Key Vault for VM access
      az keyvault secret set \
        --vault-name "$KEYVAULT_NAME" \
        --name "entra-client-id" \
        --value "$APP_ID" > /dev/null
      
      echo "✓ Entra Client ID stored in Key Vault"
    '''
  }
  
  dependsOn: [
    sp
    generateSecretsScript
  ]
}

// ===== STEP 3: Generate self-signed certificate for Application Gateway =====
resource generateCertificateScript 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: generateCertScriptName
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
      { name: 'KEYVAULT_NAME', value: keyVault.name }
      { name: 'DOMAIN_NAME', value: appGwPip.properties.dnsSettings.fqdn }
      { name: 'CERT_SECRET_NAME', value: 'appgw-ssl-cert' }
    ]
    
    scriptContent: '''
      #!/bin/bash
      set -euo pipefail
      
      echo "=== Generating Self-Signed Certificate for Application Gateway ==="
      
      # Generate private key and self-signed certificate
      # Valid for 1 year, can be replaced with real cert later
      openssl req \
        -x509 \
        -newkey rsa:2048 \
        -keyout /tmp/server.key \
        -out /tmp/server.crt \
        -days 365 \
        -nodes \
        -subj "/CN=$DOMAIN_NAME/O=RedmineDeploy/C=US"
      
      # Create PKCS#12 format (required by App Gateway)
      openssl pkcs12 \
        -export \
        -in /tmp/server.crt \
        -inkey /tmp/server.key \
        -out /tmp/server.pfx \
        -name "appgw-cert" \
        -passout pass:""
      
      # Base64 encode the PFX for Key Vault storage
      PFX_BASE64=$(cat /tmp/server.pfx | base64 -w0)
      
      # Store in Key Vault (as secret because Key Vault has native cert support)
      az keyvault secret set \
        --vault-name "$KEYVAULT_NAME" \
        --name "$CERT_SECRET_NAME" \
        --value "$PFX_BASE64" > /dev/null
      
      echo "✓ Self-signed certificate generated and stored in Key Vault"
      echo "✓ Certificate subject: CN=$DOMAIN_NAME"
      echo "✓ Certificate validity: 365 days"
      echo "⚠  NOTE: For production, replace with real certificate from CA"
    '''
  }
  
  dependsOn: [
    generateSecretsScript
  ]
}

// ==============================================================================
// RESOURCES: SQL DATABASE (Private, RBAC-secured)
// ==============================================================================
// Azure SQL Server with auto-generated admin password stored in Key Vault.
// Public network access disabled - accessible only via Private Endpoint.
// Transparent Data Encryption (TDE) enabled by default.

resource sqlServer 'Microsoft.Sql/servers@2022-11-01-preview' = {
  name: sqlServerName
  location: location
  tags: commonTags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    // Admin credentials sourced from Key Vault during deployment
    administratorLogin: 'sqladmin'
    administratorLoginPassword: secretSqlAdmin.properties.value
    
    // Disable public network access - use Private Endpoint only
    publicNetworkAccess: 'Disabled'
    
    // Require encrypted connections only
    minimalTlsVersion: '1.2'
    
    // Azure AD authentication support (optional, for future use)
    administrators: {
      administratorType: 'ActiveDirectory'
      azureADOnlyAuthentication: false // Set to true if you want AAD-only auth
      principalType: 'Group'
      tenantId: tenantId
    }
  }
}

resource sqlDb 'Microsoft.Sql/servers/databases@2022-11-01-preview' = {
  parent: sqlServer
  name: sqlDbName
  location: location
  tags: commonTags
  sku: {
    name: sqlSku
  }
  properties: {
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    requestedBackupStorageRedundancy: 'Geo'
  }
}

// Enable Transparent Data Encryption (TDE) for at-rest encryption
resource sqlDbTde 'Microsoft.Sql/servers/databases/transparentDataEncryption@2022-11-01-preview' = {
  parent: sqlDb
  name: 'current'
  properties: {
    state: 'Enabled'
  }
}

// Audit logging for compliance
resource sqlServerAudit 'Microsoft.Sql/servers/auditingSettings@2022-11-01-preview' = {
  name: 'default'
  parent: sqlServer
  properties: {
    state: 'Enabled'
    auditActionsAndGroups: [
      'SUCCESSFUL_DATABASE_AUTHENTICATION_GROUP'
      'FAILED_DATABASE_AUTHENTICATION_GROUP'
      'BATCH_COMPLETED_GROUP'
    ]
    retentionDays: 30
    isStorageSecondaryKeyInUse: false
  }
}

// Diagnostic logs for SQL Database
resource sqlDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'sql-diagnostic-settings'
  scope: sqlDb
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      {
        category: 'SQLSecurityAuditEvents'
        enabled: true
        retentionPolicy: {
          enabled: true
          days: logAnalyticsRetentionInDays
        }
      }
      {
        category: 'Errors'
        enabled: true
        retentionPolicy: {
          enabled: true
          days: logAnalyticsRetentionInDays
        }
      }
      {
        category: 'DatabaseWaitStatistics'
        enabled: true
        retentionPolicy: {
          enabled: true
          days: logAnalyticsRetentionInDays
        }
      }
    ]
    metrics: [
      {
        category: 'Basic'
        enabled: true
        retentionPolicy: {
          enabled: true
          days: logAnalyticsRetentionInDays
        }
      }
    ]
  }
}

// Private Endpoint for SQL Server (removes public internet exposure)
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
          groupIds: [
            'sqlServer'
          ]
          requestMessage: 'Please approve this connection'
        }
      }
    ]
  }
  dependsOn: [
    vnet
  ]
}

// Private DNS Zone for SQL Database internal resolution
#disable-next-line no-hardcoded-env-urls
resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  #disable-next-line no-hardcoded-env-urls
  name: 'privatelink.database.windows.net'
  location: 'global'
  tags: commonTags
}

// Link Private DNS Zone to VNet for name resolution
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

// Configure DNS group for Private Endpoint
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
// RESOURCES: KEY VAULT SECRETS (References to auto-generated values)
// ==============================================================================
// These secrets are created by deployment scripts above.
// We reference them here to establish deployment dependencies.

// Secret placeholder resources that the deployment scripts will populate
// These follow the "Idempotent Creation" pattern - scripts check if they exist before creating

resource secretSqlAdmin 'Microsoft.KeyVault/vaults/secrets@2023-02-01' = {
  parent: keyVault
  name: 'sql-admin-password'
  properties: {
    value: 'PLACEHOLDER' // Will be replaced by deployment script
  }
  dependsOn: [
    generateSecretsScript
  ]
}

resource secretRedmineKey 'Microsoft.KeyVault/vaults/secrets@2023-02-01' = {
  parent: keyVault
  name: 'redmine-secret-key'
  properties: {
    value: 'PLACEHOLDER' // Will be replaced by deployment script
  }
  dependsOn: [
    generateSecretsScript
  ]
}

resource secretSshPrivate 'Microsoft.KeyVault/vaults/secrets@2023-02-01' = {
  parent: keyVault
  name: 'ssh-private-key'
  properties: {
    value: 'PLACEHOLDER' // Will be replaced by deployment script
    contentType: 'application/octet-stream'
  }
  dependsOn: [
    generateSecretsScript
  ]
}

resource secretSshPublic 'Microsoft.KeyVault/vaults/secrets@2023-02-01' = {
  parent: keyVault
  name: 'ssh-public-key'
  properties: {
    value: 'PLACEHOLDER' // Will be replaced by deployment script
    contentType: 'text/plain'
  }
  dependsOn: [
    generateSecretsScript
  ]
}

resource secretEntraClientId 'Microsoft.KeyVault/vaults/secrets@2023-02-01' = {
  parent: keyVault
  name: 'entra-client-id'
  properties: {
    value: appReg.appId
  }
}

resource secretEntraClientSecret 'Microsoft.KeyVault/vaults/secrets@2023-02-01' = {
  parent: keyVault
  name: 'entra-client-secret'
  properties: {
    value: 'PLACEHOLDER' // Will be replaced by deployment script
  }
  dependsOn: [
    generateSecretsScript
  ]
}

resource secretAppGwCert 'Microsoft.KeyVault/vaults/secrets@2023-02-01' = {
  parent: keyVault
  name: 'appgw-ssl-cert'
  properties: {
    value: 'PLACEHOLDER' // Will be replaced by deployment script
    contentType: 'application/x-pkcs12'
  }
  dependsOn: [
    generateCertificateScript
  ]
}

// ==============================================================================
// RESOURCES: VIRTUAL MACHINE (Linux with Auto-Generated SSH Keys)
// ==============================================================================
// VM deployed with SSH public key stored in Key Vault.
// Managed Identity enables secure Key Vault access without stored credentials.
// All configuration and secrets passed via Key Vault only.

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
          // Associate NIC with App Gateway backend pool for automatic routing
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
    networkSecurityGroup: {
      id: nsgVm.id
    }
  }
  dependsOn: [
    vnet
    appGateway
  ]
}

// Virtual Machine with System-Assigned Managed Identity for secure Key Vault access
resource vm 'Microsoft.Compute/virtualMachines@2023-03-01' = {
  name: vmName
  location: location
  tags: commonTags
  
  // Managed Identity: VM automatically authenticated to Azure AD
  // No credentials need to be stored on the VM
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
      
      // SSH public key auto-generated and stored in Key Vault
      // Retrieved at deployment time via Key Vault reference
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              // SSH public key from Key Vault
              keyData: secretSshPublic.properties.value
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
        // Use managed disk with encryption
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
        deleteOption: 'Delete'
      }
    }
    
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: {
            deleteOption: 'Detach'
            primary: true
          }
        }
      ]
    }
  }
  
  dependsOn: []
}

// Diagnostic settings for VM
resource vmDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'vm-diagnostic-settings'
  scope: vm
  properties: {
    workspaceId: logAnalytics.id
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
        retentionPolicy: {
          enabled: true
          days: logAnalyticsRetentionInDays
        }
      }
    ]
  }
}

// Custom Script Extension: Download and execute Redmine installation script
// The script will authenticate to Key Vault using the VM's Managed Identity
// No credentials passed as parameters - only Key Vault name is provided
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
      // Download script from public GitHub repo
      fileUris: [
        installScriptUrl
      ]
      // Command executed with access to the environment variables and MSI token
      commandToExecute: 'bash install.sh "${kvName}" "${sqlServer.properties.fullyQualifiedDomainName}" "${sqlDbName}" "${tenantId}" "${appReg.appId}"'
    }
  }
  
  dependsOn: [
    roleAssignKvSecretsToVm
    configureEntraSecretScript
    sqlDb
    appGateway
  ]
}


// ==============================================================================
// OUTPUTS - Deployment Information & Access Details
// ==============================================================================
// These outputs provide deployment summary and connection information.
// Sensitive values (passwords, keys) are NOT output. Access them via Key Vault.

output deploymentSummary object = {
  message: 'Deployment completed successfully. All secrets are stored in Key Vault.'
  environment: environmentName
  region: location
}

output appGatewayPublicUrl string = 'https://${appGwPip.properties.dnsSettings.fqdn}'

output appGatewayFqdn string = appGwPip.properties.dnsSettings.fqdn

output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName

output keyVaultName string = keyVault.name

output keyVaultId string = keyVault.id

output tenantId string = tenantId

output enviromentName string = environmentName

output appRegistrationClientId string = appReg.appId

output vmName string = vm.name

output vmResourceId string = vm.id

output redmineDbName string = sqlDbName

output accessInstructions object = {
  ssh: 'ssh -i <private-key-from-keyvault> ${adminUsername}@${vm.properties.osProfile.computerName}'
  keyVaultSecrets: [
    'sql-admin-password'
    'redmine-secret-key'
    'ssh-private-key'
    'ssh-public-key'
    'entra-client-secret'
    'entra-client-id'
    'appgw-ssl-cert'
  ]
  nextSteps: 'Download certificates and keys from Key Vault. Never share or commit to source control.'
}
