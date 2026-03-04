#!/bin/bash
# ==============================================================================
# Redmine Azure Deployment Orchestrator
# Automates the execution of Entra ID App Registration and Bicep Deployment
# ==============================================================================
set -euo pipefail

# Configuration
ENVIRONMENT_NAME=${1:-redmine-demo}
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

# 0. Validate Azure Login
if ! az account show > /dev/null 2>&1; then
    echo "ERROR: Not logged into Azure. Please run 'az login' first."
    exit 1
fi
SUBSCRIPTION_ID=$(az account show --query id -o tsv)

# ==============================================================================
# STEP 1: Entra ID App Registration Configuration
# ==============================================================================
echo "[1/4] Checking/Creating Microsoft Entra ID App Registration..."

# Check if application already exists
EXISTING_APP_ID=$(az ad app list --display-name "$ENTRA_APP_NAME" --query "[0].appId" -o tsv 2>/dev/null || true)

if [ -z "$EXISTING_APP_ID" ]; then
    echo "  -> Creating App Registration: $ENTRA_APP_NAME..."
    APP_INFO=$(az ad app create --display-name "$ENTRA_APP_NAME" --sign-in-audience "AzureADMyOrg")
    ENTRA_CLIENT_ID=$(echo "$APP_INFO" | jq -r '.appId')
    OBJECT_ID=$(echo "$APP_INFO" | jq -r '.id')
    echo "  -> Generated Client ID: $ENTRA_CLIENT_ID"

    # Important: Ensure service principal is created for the app
    echo "  -> Creating Service Principal for App..."
    az ad sp create --id "$ENTRA_CLIENT_ID" > /dev/null
else
    echo "  -> App Registration '$ENTRA_APP_NAME' already exists. Using existing Client ID: $EXISTING_APP_ID"
    ENTRA_CLIENT_ID=$EXISTING_APP_ID
    OBJECT_ID=$(az ad app list --display-name "$ENTRA_APP_NAME" --query "[0].id" -o tsv)
fi

echo "  -> Checking/Generating Entra ID Client Secret..."
# Warning: OIDC requires a valid secret. We will reset/create a new one to guarantee we have the value.
# Name the credential specifically for this deployment
CRED_INFO=$(az ad app credential reset --id "$OBJECT_ID" --display-name "Redmine-OIDC-Secret" --append --years 2)
ENTRA_CLIENT_SECRET=$(echo "$CRED_INFO" | jq -r '.password')

if [ -z "$ENTRA_CLIENT_SECRET" ]; then
    echo "ERROR: Failed to generate Entra ID Client Secret."
    exit 1
fi

echo "  -> Entra ID OIDC credentials generated successfully (Secret hidden for security)."

# ==============================================================================
# STEP 2: Pre-deployment Resource Group Setup
# ==============================================================================
echo "[2/4] Ensuring Resource Group exists..."
if [ "$(az group exists --name "$RESOURCE_GROUP")" = false ]; then
    az group create --name "$RESOURCE_GROUP" --location "$LOCATION" > /dev/null
    echo "  -> Custom Resource Group '$RESOURCE_GROUP' created."
else
    echo "  -> Custom Resource Group '$RESOURCE_GROUP' already exists."
fi

# ==============================================================================
# STEP 3: Execute Bicep Deployment
# ==============================================================================
echo "[3/4] Validating and Executing Bicep Deployment..."
# Generate a secure SQL Admin password dynamically
SQL_ADMIN_PASSWORD=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9!#_+' | head -c 24)

# Bicep Deployment
DEPLOYMENT_NAME="redmine-deploy-$(date +%s)"
az deployment group create \
    --name "$DEPLOYMENT_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --template-file main.bicep \
    --parameters \
        environmentName="$ENVIRONMENT_NAME" \
        adminIpAddress="$ADMIN_IP" \
        entraClientId="$ENTRA_CLIENT_ID" \
        entraClientSecret="$ENTRA_CLIENT_SECRET" \
        sqlAdminPassword="$SQL_ADMIN_PASSWORD"

echo "  -> Bicep deployment completed successfully."

# ==============================================================================
# STEP 4: Post-deployment OIDC Callback URI configuration
# ==============================================================================
echo "[4/4] Finalizing Entra ID App configuration with deployed Gateway FQDN..."
APPGW_FQDN=$(az deployment group show -g "$RESOURCE_GROUP" -n "$DEPLOYMENT_NAME" --query "properties.outputs.appGatewayFqdn.value" -o tsv)
OIDC_CALLBACK_URI="https://${APPGW_FQDN}/auth/oidc/callback"

echo "  -> Setting Redirect URI: $OIDC_CALLBACK_URI"

# We use the REST API as the az CLI sometimes is clumsy with web.redirectUris modification without overwriting.
# First, construct the JSON body
cat <<EOF > /tmp/update-app.json
{
    "web": {
        "redirectUris": [
            "$OIDC_CALLBACK_URI"
        ]
    }
}
EOF

if az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/applications/$OBJECT_ID" --body @/tmp/update-app.json; then
    echo "  -> App Registration redirect URI updated successfully."
else
    echo "  -> WARNING: Failed to automatedly add the redirect URI. You may need to add '$OIDC_CALLBACK_URI' to '$ENTRA_APP_NAME' manually via the Azure Portal."
fi

# ==============================================================================
# SUMMARY
# ==============================================================================
echo ""
echo "==================================================================="
echo " ✅ DEPLOYMENT COMPLETE"
echo "==================================================================="
echo "Application URL: https://$APPGW_FQDN"
echo "Key Vault Name : $(az deployment group show -g "$RESOURCE_GROUP" -n "$DEPLOYMENT_NAME" --query "properties.outputs.keyVaultName.value" -o tsv)"
echo ""
echo "Note: It may take up to 20 minutes for Redmine VM extension scripts to"
echo "finish installing Ruby, Nginx, configuring DB, and starting Puma."
echo "You can check status by SSH-ing to the VM or checking the Gateway URL."
