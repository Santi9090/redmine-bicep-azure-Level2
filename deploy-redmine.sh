#!/bin/bash
# ==============================================================================
# Redmine Azure Deployment Orchestrator
# Automates the execution of Entra ID App Registration, Secrets, and Bicep
# ==============================================================================
set -euo pipefail

# Configuration
ENVIRONMENT_NAME=${1:-redminedemo}
LOCATION=${2:-eastus}
RESOURCE_GROUP="rg-${ENVIRONMENT_NAME}-${LOCATION}"
ENTRA_APP_NAME="Redmine-SSO-${ENVIRONMENT_NAME}"
ADMIN_IP=$(curl -s https://api.ipify.org)/32

echo "==================================================================="
echo " Starting Fully Automated Redmine Infrastructure Deployment"
echo " Environment        : $ENVIRONMENT_NAME"
echo " Location           : $LOCATION"
echo " Resource Group     : $RESOURCE_GROUP"
echo " Entra App Name     : $ENTRA_APP_NAME"
echo " Admin IP (for SSH) : $ADMIN_IP"
echo "==================================================================="

# 0. Validate prerequisites
if ! az account show > /dev/null 2>&1; then
    echo "ERROR: Not logged into Azure. Please run 'az login' first."
    exit 1
fi
if ! command -v jq &> /dev/null; then
    echo "ERROR: 'jq' is not installed."
    exit 1
fi

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)

UNIQUE_SUFFIX=$(echo -n "${SUBSCRIPTION_ID}${RESOURCE_GROUP}" | sha256sum | head -c 10 | tr -d '\n')
APPGW_DOMAIN_LABEL=$(echo "${ENVIRONMENT_NAME}-${UNIQUE_SUFFIX}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')
APPGW_FQDN="${APPGW_DOMAIN_LABEL}.${LOCATION}.cloudapp.azure.com"

# ==============================================================================
# STEP 1: Entra ID App Registration
# ==============================================================================
echo "[1/10] Checking/Creating Microsoft Entra ID App Registration..."

EXISTING_APP_ID=$(az ad app list --display-name "$ENTRA_APP_NAME" --query "[0].appId" -o tsv 2>/dev/null || true)

if [ -z "$EXISTING_APP_ID" ]; then
    echo "  -> Creating App Registration: $ENTRA_APP_NAME..."
    APP_INFO=$(az ad app create --display-name "$ENTRA_APP_NAME" --sign-in-audience "AzureADMyOrg")
    ENTRA_CLIENT_ID=$(echo "$APP_INFO" | jq -r '.appId')
    OBJECT_ID=$(echo "$APP_INFO" | jq -r '.id')
else
    echo "  -> App Registration '$ENTRA_APP_NAME' already exists."
    ENTRA_CLIENT_ID=$EXISTING_APP_ID
    OBJECT_ID=$(az ad app list --display-name "$ENTRA_APP_NAME" --query "[0].id" -o tsv)
fi

echo "  -> Client ID: $ENTRA_CLIENT_ID"

# ==============================================================================
# STEP 2: Service Principal
# ==============================================================================
echo "[2/10] Creating Service Principal for App..."
az ad sp create --id "$ENTRA_CLIENT_ID" > /dev/null 2>&1 || true

# ==============================================================================
# STEP 3: Entra ID Client Secret
# ==============================================================================
echo "[3/10] Generating Entra ID Client Secret..."
CRED_INFO=$(az ad app credential reset --id "$OBJECT_ID" --display-name "Redmine-OIDC-Secret" --append --years 2)
ENTRA_CLIENT_SECRET=$(echo "$CRED_INFO" | jq -r '.password')

if [ -z "$ENTRA_CLIENT_SECRET" ] || [ "$ENTRA_CLIENT_SECRET" == "null" ]; then
    echo "ERROR: Failed to generate Entra ID Client Secret."
    exit 1
fi
echo "  -> Entra ID OIDC credentials generated successfully."

# ==============================================================================
# Pre-Bicep Secret Generation
# ==============================================================================
echo "[.../10] Generating secure configurations locally (SQL, SSH, Certificates)..."
SQL_ADMIN_PASSWORD=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9!#_+' | head -c 24)
REDMINE_SECRET_KEY=$(openssl rand -hex 32)

echo "  -> Generating ED25519 SSH Keypair..."
rm -f /tmp/id_ed25519 /tmp/id_ed25519.pub
ssh-keygen -t ed25519 -f /tmp/id_ed25519 -N "" -C "redmine-admin@azure" >/dev/null 2>&1
SSH_PRIVATE_KEY=$(cat /tmp/id_ed25519 | base64 -w0)
SSH_PUBLIC_KEY=$(cat /tmp/id_ed25519.pub)
rm -f /tmp/id_ed25519 /tmp/id_ed25519.pub

echo "  -> Generating App Gateway self-signed certificate for $APPGW_FQDN..."
rm -f /tmp/server.key /tmp/server.crt /tmp/server.pfx
openssl req -x509 -newkey rsa:2048 -keyout /tmp/server.key -out /tmp/server.crt -days 365 -nodes -subj "/CN=${APPGW_FQDN}/O=RedmineDeploy/C=US" 2>/dev/null
openssl pkcs12 -export -in /tmp/server.crt -inkey /tmp/server.key -out /tmp/server.pfx -name "appgw-cert" -passout pass:"" 2>/dev/null
APP_GW_CERT_B64=$(cat /tmp/server.pfx | base64 -w0)
rm -f /tmp/server.key /tmp/server.crt /tmp/server.pfx

# ==============================================================================
# STEP 4 to 9: Execute Bicep Deployment
# ==============================================================================
echo "[4-9/10] Ensuring Resource Group exists..."
if [ "$(az group exists --name "$RESOURCE_GROUP")" = false ]; then
    az group create --name "$RESOURCE_GROUP" --location "$LOCATION" > /dev/null
fi

DEPLOYMENT_NAME="redmine-deploy-$(date +%s)"

echo "  -> Validating Bicep deployment (What-If)..."
az deployment group what-if \
    --name "$DEPLOYMENT_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --template-file main.bicep \
    --parameters \
        environmentName="$ENVIRONMENT_NAME" \
        adminIpAddress="$ADMIN_IP" \
        tenantId="$TENANT_ID" \
        entraClientId="$ENTRA_CLIENT_ID" \
        entraClientSecret="$ENTRA_CLIENT_SECRET" \
        sqlAdminPassword="$SQL_ADMIN_PASSWORD" \
        redmineSecretKey="$REDMINE_SECRET_KEY" \
        sshPublicKey="$SSH_PUBLIC_KEY" \
        sshPrivateKey="$SSH_PRIVATE_KEY" \
        appGwSslCertB64="$APP_GW_CERT_B64" \
        appGwDomainLabel="$APPGW_DOMAIN_LABEL" \
    > /dev/null

echo "  -> Executing Bicep Deployment..."
az deployment group create \
    --name "$DEPLOYMENT_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --template-file main.bicep \
    --parameters \
        environmentName="$ENVIRONMENT_NAME" \
        adminIpAddress="$ADMIN_IP" \
        tenantId="$TENANT_ID" \
        entraClientId="$ENTRA_CLIENT_ID" \
        entraClientSecret="$ENTRA_CLIENT_SECRET" \
        sqlAdminPassword="$SQL_ADMIN_PASSWORD" \
        redmineSecretKey="$REDMINE_SECRET_KEY" \
        sshPublicKey="$SSH_PUBLIC_KEY" \
        sshPrivateKey="$SSH_PRIVATE_KEY" \
        appGwSslCertB64="$APP_GW_CERT_B64" \
        appGwDomainLabel="$APPGW_DOMAIN_LABEL"

echo "  -> Bicep deployment completed successfully."

# Retrieve Key Vault name dynamically if needed
KV_NAME=$(az deployment group show -g "$RESOURCE_GROUP" -n "$DEPLOYMENT_NAME" --query "properties.outputs.keyVaultName.value" -o tsv)

# ==============================================================================
# STEP 10: OIDC Callback URI configuration
# ==============================================================================
echo "[10/10] Finalizing Entra ID App configuration with deployed Gateway FQDN..."
OIDC_CALLBACK_URI="https://${APPGW_FQDN}/auth/oidc/callback"

echo "  -> Setting Redirect URI: $OIDC_CALLBACK_URI"

cat <<EOF > /tmp/update-app.json
{
    "web": {
        "redirectUris": [
            "$OIDC_CALLBACK_URI"
        ]
    }
}
EOF

az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/applications/$OBJECT_ID" --body @/tmp/update-app.json || true
rm -f /tmp/update-app.json

# ==============================================================================
# SUMMARY
# ==============================================================================
echo ""
echo "==================================================================="
echo " ✅ DEPLOYMENT COMPLETE"
echo "==================================================================="
echo "Application URL : https://$APPGW_FQDN"
echo "Key Vault Name  : $KV_NAME"
echo ""
echo "Note: It may take up to 20 minutes for Redmine VM extension scripts to"
echo "finish installing Ruby, Nginx, configuring DB, and starting Puma."
echo "You can check status by tracking the CustomScriptExtension deployment."
