#!/bin/bash
set -euo pipefail

##################################################
# ARGUMENTS AND VARIABLES
##################################################
if [ "$#" -ne 6 ]; then
  echo "Usage: $0 KEY_VAULT_NAME SQL_FQDN DB_NAME TENANT_ID CLIENT_ID APPGW_FQDN" >&2
  exit 1
fi

KEY_VAULT_NAME="$1"
SQL_FQDN="$2"
DB_NAME="$3"
TENANT_ID="$4"
CLIENT_ID="$5"
APPGW_FQDN="$6"

export DEBIAN_FRONTEND=noninteractive

##################################################
# STEP 1 – SYSTEM PREPARATION
##################################################
apt-get update && apt-get upgrade -y

apt-get install -y \
  curl \
  git \
  build-essential \
  libssl-dev \
  libreadline-dev \
  zlib1g-dev \
  libyaml-dev \
  libxml2-dev \
  libxslt1-dev \
  libffi-dev \
  libpq-dev \
  nodejs \
  nginx \
  ruby-full \
  ruby-dev \
  gnupg \
  lsb-release

# Install yarn (via npm if not available or ensuring latest)
if ! command -v yarn &> /dev/null; then
    npm install --global yarn
fi

gem install bundler

##################################################
# STEP 2 – AZURE CLI
##################################################
if ! command -v az &> /dev/null; then
    mkdir -p /etc/apt/keyrings
    curl -sLS https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | tee /etc/apt/keyrings/microsoft.gpg > /dev/null
    chmod go+r /etc/apt/keyrings/microsoft.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/azure-cli.list
    apt-get update
    apt-get install -y azure-cli
fi

az login --identity --output none

##################################################
# STEP 3 – RETRIEVE SECRETS FROM KEY VAULT
##################################################
SQL_PASSWORD=$(az keyvault secret show --name "$KEY_VAULT_NAME" --secret-name "sql-admin-password" --query "value" -o tsv)
REDMINE_SECRET_KEY=$(az keyvault secret show --name "$KEY_VAULT_NAME" --secret-name "redmine-secret-key" --query "value" -o tsv)
ENTRA_CLIENT_SECRET=$(az keyvault secret show --name "$KEY_VAULT_NAME" --secret-name "entra-client-secret" --query "value" -o tsv)

##################################################
# STEP 4 – INSTALL MICROSOFT SQL DRIVER
##################################################
if ! dpkg -l | grep -q msodbcsql17; then
    curl https://packages.microsoft.com/keys/microsoft.asc | apt-key add -
    curl https://packages.microsoft.com/config/ubuntu/22.04/prod.list > /etc/apt/sources.list.d/mssql-release.list
    apt-get update
    ACCEPT_EULA=Y apt-get install -y msodbcsql17 mssql-tools unixodbc-dev
fi

##################################################
# STEP 5 – INSTALL REDMINE & PLUGINS
##################################################
if [ ! -d "/opt/redmine" ]; then
    # Checkout Redmine 5.1-stable (compatible with Ubuntu 22.04 Ruby 3.0)
    git clone -b 5.1-stable https://github.com/redmine/redmine.git /opt/redmine
    
    # Create user if not exists
    if ! id -u redmine > /dev/null 2>&1; then
        useradd -r -d /opt/redmine -s /bin/bash redmine
    fi
    
    chown -R redmine:redmine /opt/redmine
fi

# Clone OIDC Plugin (redmine_omniauth_openid_connect) logic
if [ ! -d "/opt/redmine/plugins/redmine_omniauth_openid_connect" ]; then
    git clone https://github.com/ale/redmine_omniauth_openid_connect.git /opt/redmine/plugins/redmine_omniauth_openid_connect
fi

cd /opt/redmine

# Create/Update Gemfile.local for additional gems
cat <<EOF > Gemfile.local
gem 'tiny_tds'
gem 'activerecord-sqlserver-adapter'
gem 'omniauth-openid-connect'
EOF

# Install gems
bundle config set --local without 'development test'
bundle install

##################################################
# STEP 6 – DATABASE CONFIGURATION
##################################################
cat <<EOF > config/database.yml
production:
  adapter: sqlserver
  mode: dblib
  host: "${SQL_FQDN}"
  database: "${DB_NAME}"
  username: sqladmin
  password: "${SQL_PASSWORD}"
  encoding: utf8
EOF
chmod 600 config/database.yml
chown redmine:redmine config/database.yml

# Set secret key base
if [ ! -f config/secrets.yml ]; then
    echo "production:" > config/secrets.yml
    echo "  secret_key_base: \"${REDMINE_SECRET_KEY}\"" >> config/secrets.yml
else
    # Update secret_key_base if needed, or assume it's set. 
    # For idempotency, we can overwrite or regex replace. 
    # Here we overwrite to ensure it matches Key Vault.
    sed -i "/secret_key_base:/d" config/secrets.yml || true
    if grep -q "production:" config/secrets.yml; then
        sed -i "/production:/a \  secret_key_base: \"${REDMINE_SECRET_KEY}\"" config/secrets.yml
    else
        echo "production:" >> config/secrets.yml
        echo "  secret_key_base: \"${REDMINE_SECRET_KEY}\"" >> config/secrets.yml
    fi
fi
chmod 600 config/secrets.yml
chown redmine:redmine config/secrets.yml

# Run migrations (DB and Plugins)
bundle exec rake db:migrate RAILS_ENV=production
bundle exec rake redmine:plugins:migrate RAILS_ENV=production

##################################################
# STEP 7 – CONFIGURE OPENID CONNECT
##################################################
# Configure initializer
cat <<EOF > config/initializers/01_openid_connect.rb
require 'omniauth/openid_connect'

Rails.application.config.middleware.use OmniAuth::Builder do
  provider :openid_connect, {
    issuer: "https://login.microsoftonline.com/${TENANT_ID}/v2.0",
    discovery: true,
    client_auth_method: :jwks,
    scope: [:openid, :profile, :email],
    client_options: {
      identifier: "${CLIENT_ID}",
      secret: "${ENTRA_CLIENT_SECRET}",
      redirect_uri: "https://${APPGW_FQDN}/auth/oidc/callback"
    }
  }
end
EOF
chmod 600 config/initializers/01_openid_connect.rb
chown redmine:redmine config/initializers/01_openid_connect.rb

##################################################
# STEP 8 – CONFIGURE PUMA
##################################################
# Create puma config file if not exists (using Redmine default or custom)
# We will create a basic valid puma.rb for production
cat <<EOF > config/puma.rb
environment 'production'
threads 0, 5
workers 2
preload_app!
port 3000, '127.0.0.1'
EOF

cat <<EOF > /etc/systemd/system/puma.service
[Unit]
Description=Puma HTTP Server for Redmine
After=network.target

[Service]
Type=simple
User=redmine
WorkingDirectory=/opt/redmine
ExecStart=/usr/bin/env bundle exec puma -C config/puma.rb
Restart=always
RestartSec=1
Environment=RAILS_ENV=production

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable puma
systemctl restart puma

##################################################
# STEP 9 – CONFIGURE NGINX
##################################################
cat <<EOF > /etc/nginx/sites-available/redmine
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
EOF

# Enable site
ln -sf /etc/nginx/sites-available/redmine /etc/nginx/sites-enabled/default

# Test and restart
nginx -t
systemctl restart nginx

##################################################
# POST-INSTALL CLEANUP & PERMISSIONS
##################################################
chown -R redmine:redmine /opt/redmine

echo "Redmine Bicep V2 Deployment Complete."
