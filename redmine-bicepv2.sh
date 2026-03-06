#!/bin/bash
# =============================================================================
# redmine-bicepv2.sh
# Script de despliegue automatizado de Redmine en Azure (Level 2)
#
# Propósito:
#   Instalar y configurar Redmine con:
#     - Nginx como proxy inverso
#     - Azure SQL Database (via adaptador SQL Server)
#     - Autenticación con Microsoft Entra ID (OIDC)
#     - Secretos recuperados desde Azure Key Vault con Managed Identity
#
# Requisitos:
#   - VM de Azure con Managed Identity asignada
#   - Key Vault accesible desde la VM
#   - Ubuntu 22.04 LTS
#
# Idempotencia:
#   - Cada sección verifica si el recurso ya existe antes de actuar.
#   - Esto permite re-ejecutar el script sin efectos destructivos.
# =============================================================================

set -euo pipefail

#############################################
# SECCIÓN 0 – VALIDACIÓN DE ARGUMENTOS
#############################################
# Se validan los 6 argumentos obligatorios antes de ejecutar cualquier paso.
# Un error temprano evita ejecuciones parciales con variables vacías.

if [ "$#" -ne 6 ]; then
  echo "ERROR: Número incorrecto de argumentos. Se requieren exactamente 6." >&2
  echo "" >&2
  echo "Uso: $0 KEY_VAULT_NAME SQL_FQDN DB_NAME TENANT_ID CLIENT_ID APPGW_FQDN" >&2
  echo "" >&2
  echo "  KEY_VAULT_NAME  : Nombre del Key Vault de Azure" >&2
  echo "  SQL_FQDN        : FQDN del servidor Azure SQL (debe contener .database.windows.net)" >&2
  echo "  DB_NAME         : Nombre de la base de datos" >&2
  echo "  TENANT_ID       : ID del tenant de Microsoft Entra ID (no puede estar vacío)" >&2
  echo "  CLIENT_ID       : Client ID de la App Registration de Entra ID (no puede estar vacío)" >&2
  echo "  APPGW_FQDN      : FQDN público del Application Gateway (no puede estar vacío)" >&2
  exit 1
fi

KEY_VAULT_NAME="$1"
SQL_FQDN="$2"
DB_NAME="$3"
TENANT_ID="$4"
CLIENT_ID="$5"
APPGW_FQDN="$6"

# --- Validación de formato de argumentos ---

if [[ -z "${KEY_VAULT_NAME}" ]]; then
  echo "ERROR: KEY_VAULT_NAME no puede estar vacío." >&2
  exit 1
fi

if [[ "${SQL_FQDN}" != *".database.windows.net"* ]]; then
  echo "ERROR: SQL_FQDN ('${SQL_FQDN}') no parece ser un FQDN de Azure SQL válido." >&2
  echo "       Debe contener '.database.windows.net'." >&2
  exit 1
fi

if [[ -z "${DB_NAME}" ]]; then
  echo "ERROR: DB_NAME no puede estar vacío." >&2
  exit 1
fi

if [[ -z "${TENANT_ID}" ]]; then
  echo "ERROR: TENANT_ID no puede estar vacío. Se requiere para la autenticación OIDC con Entra ID." >&2
  exit 1
fi

if [[ -z "${CLIENT_ID}" ]]; then
  echo "ERROR: CLIENT_ID no puede estar vacío. Se requiere para la autenticación OIDC con Entra ID." >&2
  exit 1
fi

if [[ -z "${APPGW_FQDN}" ]]; then
  echo "ERROR: APPGW_FQDN no puede estar vacío. Se requiere para construir el callback OIDC." >&2
  exit 1
fi

# Evitar interacciones manuales durante instalaciones de paquetes
export DEBIAN_FRONTEND=noninteractive

echo "======================================================"
echo "  Inicio del despliegue de Redmine Bicep V2"
echo "  Key Vault: ${KEY_VAULT_NAME}"
echo "  SQL FQDN : ${SQL_FQDN}"
echo "  DB       : ${DB_NAME}"
echo "  FQDN GW  : ${APPGW_FQDN}"
echo "======================================================"

#############################################
# SECCIÓN 1 – PREPARACIÓN DEL SISTEMA
#############################################
# Se actualiza el sistema operativo y se instalan todas las dependencias
# necesarias para compilar y ejecutar Redmine, incluyendo Ruby, Node.js,
# Nginx y las librerías de desarrollo de sistema.

echo "[1/9] Actualizando sistema e instalando dependencias..."

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
  npm \
  nginx \
  ruby-full \
  ruby-dev \
  gnupg \
  lsb-release

# Instalar yarn globalmente si no está disponible
if ! command -v yarn &> /dev/null; then
  echo "  -> Instalando yarn..."
  npm install --global yarn
fi

# Instalar bundler para gestión de gemas de Ruby (idempotente)
if ! command -v bundle &> /dev/null; then
  echo "  -> Instalando bundler..."
  gem install bundler
else
  echo "  -> bundler ya está instalado: $(bundle --version)"
fi

echo "  -> Dependencias instaladas correctamente."

#############################################
# SECCIÓN 2 – INSTALACIÓN DE AZURE CLI
#############################################
# Se instala Azure CLI si no está disponible.
# Esto es necesario para interactuar con Key Vault mediante Managed Identity.
#
# Por qué Managed Identity:
#   Se usa Managed Identity (--identity) en lugar de credenciales explícitas
#   para evitar almacenar secretos en el script o en variables de entorno.
#   Azure asigna una identidad a la VM y Key Vault la valida automáticamente.

echo "[2/9] Verificando instalación de Azure CLI..."

if ! command -v az &> /dev/null; then
  echo "  -> Azure CLI no encontrado. Instalando..."
  mkdir -p /etc/apt/keyrings
  curl -sLS https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor \
    | tee /etc/apt/keyrings/microsoft.gpg > /dev/null
  chmod go+r /etc/apt/keyrings/microsoft.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] \
https://packages.microsoft.com/repos/azure-cli/ $(lsb_release -cs) main" \
    | tee /etc/apt/sources.list.d/azure-cli.list
  apt-get update
  apt-get install -y azure-cli
  echo "  -> Azure CLI instalado correctamente."
else
  echo "  -> Azure CLI ya está instalado."
fi

# Autenticarse con Managed Identity ANTES de cualquier operación con Key Vault.
# Si esto falla, el script se detiene inmediatamente (set -e lo garantiza).
echo "  -> Autenticando con Managed Identity..."
if ! az login --identity --output none; then
  echo "ERROR: No se pudo autenticar con Managed Identity." >&2
  echo "       Verificar que la VM tiene una identidad asignada y tiene acceso al Key Vault." >&2
  exit 1
fi
echo "  -> Autenticación con Managed Identity completada."

#############################################
# SECCIÓN 3 – RECUPERACIÓN DE SECRETOS DESDE KEY VAULT
#############################################
# Se recuperan los tres secretos necesarios desde Azure Key Vault.
# Se utiliza --query value -o tsv para obtener únicamente el valor del secreto
# sin metadatos adicionales en formato JSON.
#
# Por qué no hardcodear credenciales:
#   Almacenar contraseñas en el script o en archivos de código representa
#   un riesgo crítico de seguridad. Key Vault garantiza rotación, auditoría
#   y acceso controlado por IAM.

echo "[3/9] Recuperando secretos desde Azure Key Vault: ${KEY_VAULT_NAME}..."

get_secret_with_retry() {
  local secret_name=$1
  local max_retries=60 # 60 * 10s = 600s = 10 minutes
  local wait_sec=10
  local secret_val=""

  echo "  -> Obteniendo secreto: $secret_name (esperando propagación RBAC si es necesario)..." >&2
  for i in $(seq 1 $max_retries); do
    secret_val=$(az keyvault secret show --vault-name "${KEY_VAULT_NAME}" --name "${secret_name}" --query "value" -o tsv 2>/dev/null) || true
    if [[ -n "$secret_val" ]]; then
      echo "$secret_val"
      return 0
    fi
    sleep $wait_sec
  done
  echo "ERROR: Fallo al obtener el secreto $secret_name después de $((max_retries * wait_sec)) segundos." >&2
  return 1
}

# Contraseña del administrador de Azure SQL
SQL_PASSWORD=$(get_secret_with_retry "sql-admin-password") || exit 1
echo "  -> sql-admin-password recuperado correctamente."

# Clave secreta de la sesión de Redmine
REDMINE_SECRET_KEY=$(get_secret_with_retry "redmine-secret-key") || exit 1
echo "  -> redmine-secret-key recuperado correctamente."

# Secreto del cliente de la App Registration de Entra ID (para OIDC)
ENTRA_CLIENT_SECRET=$(get_secret_with_retry "entra-client-secret") || exit 1
echo "  -> entra-client-secret recuperado correctamente."

echo "  -> Todos los secretos recuperados exitosamente."

#############################################
# SECCIÓN 4 – DRIVER ODBC DE MICROSOFT SQL
#############################################
# Se instala el driver ODBC de Microsoft para conectarse a Azure SQL Database.
# Esto es requerido por el adaptador activerecord-sqlserver-adapter.
# La verificación de idempotencia evita reinstalaciones innecesarias.

echo "[4/9] Verificando driver Microsoft ODBC para SQL Server..."

if ! dpkg -l | grep -q msodbcsql17; then
  echo "  -> Instalando driver msodbcsql17..."
  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor \
    | tee /etc/apt/keyrings/microsoft-prod.gpg > /dev/null
  curl -fsSL https://packages.microsoft.com/config/ubuntu/22.04/prod.list \
    | tee /etc/apt/sources.list.d/mssql-release.list > /dev/null
  apt-get update
  ACCEPT_EULA=Y apt-get install -y msodbcsql17 mssql-tools unixodbc-dev
  echo "  -> Driver ODBC instalado correctamente."
else
  echo "  -> Driver msodbcsql17 ya está instalado."
fi

#############################################
# SECCIÓN 5 – INSTALACIÓN DE REDMINE Y PLUGINS
#############################################
# Se clona Redmine desde el repositorio oficial si no existe.
# Se instala el plugin redmine_omniauth_openid_connect para autenticación OIDC.
#
# Por qué idempotencia en instalación de plugins:
#   Re-clonar un plugin existente causaría un error fatal. La verificación
#   del directorio garantiza que el script pueda ejecutarse múltiples veces.
#
# Por qué se usa redmine_omniauth_openid_connect:
#   Es el plugin oficial compatible con Redmine para integración con
#   proveedores OpenID Connect como Microsoft Entra ID.

echo "[5/9] Instalando Redmine y plugins..."

if [ ! -d "/opt/redmine" ]; then
  echo "  -> Clonando Redmine 5.1-stable..."
  git clone -b 5.1-stable https://github.com/redmine/redmine.git /opt/redmine
  echo "  -> Redmine clonado correctamente."
else
  echo "  -> Directorio /opt/redmine ya existe. Omitiendo clonado."
fi

# Crear usuario de sistema para Redmine si no existe
if ! id -u redmine > /dev/null 2>&1; then
  echo "  -> Creando usuario del sistema 'redmine'..."
  useradd -r -d /opt/redmine -s /bin/bash redmine
  echo "  -> Usuario 'redmine' creado."
else
  echo "  -> Usuario 'redmine' ya existe."
fi

# Garantizar propiedad del directorio en todos los casos
chown -R redmine:redmine /opt/redmine

# Instalar plugin OIDC si no está presente (idempotente)
OIDC_PLUGIN_DIR="/opt/redmine/plugins/redmine_omniauth_openid_connect"
if [ ! -d "${OIDC_PLUGIN_DIR}" ]; then
  echo "  -> Clonando plugin redmine_omniauth_openid_connect..."
  mkdir -p /opt/redmine/plugins
  git clone https://github.com/ale/redmine_omniauth_openid_connect.git \
    "${OIDC_PLUGIN_DIR}"
  echo "  -> Plugin OIDC instalado."
else
  echo "  -> Plugin redmine_omniauth_openid_connect ya existe. Omitiendo clonado."
fi

cd /opt/redmine

# Gemfile.local: gemas adicionales para Azure SQL y OIDC
# Se sobreescribe cada vez para asegurar consistencia con los requerimientos
cat <<'EOF' > Gemfile.local
gem 'tiny_tds'
gem 'activerecord-sqlserver-adapter'
gem 'omniauth-openid-connect'
gem 'puma'
EOF

echo "  -> Instalando gemas de Ruby (bundle install)..."
sudo -u redmine bundle config set --local without 'development test'

# Crear directorios requeridos por Rails antes de bundle/rake
mkdir -p log tmp/pids tmp/sockets tmp/cache public/plugin_assets
chown -R redmine:redmine /opt/redmine

# Ejecutar bundle install como usuario redmine para evitar archivos propiedad de root
sudo -u redmine bundle install
echo "  -> Gemas instaladas correctamente."

#############################################
# SECCIÓN 6 – CONFIGURACIÓN DE BASE DE DATOS
#############################################
# Se crea el archivo database.yml solo si no existe.
#
# Por qué NO se sobreescribe database.yml:
#   Si el archivo ya existe con configuración válida, sobreescribirlo
#   podría romper una instancia en producción. Se prefiere advertir al
#   operador para que lo revise manualmente.
#
# Por qué chmod 600:
#   database.yml contiene la contraseña de la base de datos en texto plano.
#   El permiso 600 garantiza que solo el propietario (redmine) pueda leerlo,
#   evitando filtraciones a otros procesos o usuarios del sistema.

echo "[6/9] Configurando database.yml..."

DATABASE_YML="config/database.yml"

if [ ! -f "${DATABASE_YML}" ]; then
  echo "  -> Creando ${DATABASE_YML}..."
  cat <<EOF > "${DATABASE_YML}"
production:
  adapter: sqlserver
  mode: dblib
  host: "${SQL_FQDN}"
  database: "${DB_NAME}"
  username: sqladmin
  password: "${SQL_PASSWORD}"
  encoding: utf8
EOF
  # chmod 600: solo lectura/escritura para el propietario (sin acceso mundial)
  chmod 600 "${DATABASE_YML}"
  chown redmine:redmine "${DATABASE_YML}"
  echo "  -> ${DATABASE_YML} creado con permisos seguros (600)."
else
  echo "  -> ${DATABASE_YML} ya existe. Validando contenido..."
  VALIDATION_FAILED=0

  if ! grep -q "${SQL_FQDN}" "${DATABASE_YML}"; then
    echo "ADVERTENCIA: ${DATABASE_YML} no contiene el host esperado ('${SQL_FQDN}')." >&2
    VALIDATION_FAILED=1
  fi

  if ! grep -q "${DB_NAME}" "${DATABASE_YML}"; then
    echo "ADVERTENCIA: ${DATABASE_YML} no contiene la base de datos esperada ('${DB_NAME}')." >&2
    VALIDATION_FAILED=1
  fi

  if [ "${VALIDATION_FAILED}" -eq 1 ]; then
    echo "ERROR: El archivo ${DATABASE_YML} existe pero su contenido no coincide con los" >&2
    echo "       parámetros proporcionados. NO se sobreescribe para evitar pérdida de datos." >&2
    echo "       Revisar manualmente el archivo antes de continuar." >&2
    exit 1
  fi

  echo "  -> Contenido de ${DATABASE_YML} validado correctamente."
  # Reforzar permisos seguros en cualquier caso
  chmod 600 "${DATABASE_YML}"
  chown redmine:redmine "${DATABASE_YML}"
fi

# Configuración de la clave secreta de sesión de Redmine
SECRETS_YML="config/secrets.yml"
echo "  -> Configurando ${SECRETS_YML}..."

if [ ! -f "${SECRETS_YML}" ]; then
  cat <<EOF > "${SECRETS_YML}"
production:
  secret_key_base: "${REDMINE_SECRET_KEY}"
EOF
else
  # Actualizar la clave secreta de forma segura sin sobreescribir todo el archivo
  sed -i "/secret_key_base:/d" "${SECRETS_YML}" || true
  if grep -q "production:" "${SECRETS_YML}"; then
    sed -i "/production:/a\\  secret_key_base: \"${REDMINE_SECRET_KEY}\"" "${SECRETS_YML}"
  else
    printf "\nproduction:\n  secret_key_base: \"%s\"\n" "${REDMINE_SECRET_KEY}" >> "${SECRETS_YML}"
  fi
fi

# chmod 600: secrets.yml contiene la clave de sesión; debe ser privado
chmod 600 "${SECRETS_YML}"
chown redmine:redmine "${SECRETS_YML}"
echo "  -> ${SECRETS_YML} configurado con permisos seguros (600)."

# --- Verificación de conectividad con la base de datos antes de migrar ---
echo "  -> Verificando conectividad con Azure SQL antes de ejecutar migraciones..."

DB_CONNECT_CHECK=$(bundle exec ruby -e "
require 'tiny_tds'
begin
  client = TinyTds::Client.new(
    username: 'sqladmin',
    password: '${SQL_PASSWORD}',
    host: '${SQL_FQDN}',
    database: '${DB_NAME}',
    timeout: 10
  )
  puts 'OK' if client.active?
  client.close
rescue => e
  puts \"ERROR: #{e.message}\"
  exit 1
end
" 2>&1) || true

if [[ "${DB_CONNECT_CHECK}" != "OK" ]]; then
  echo "ERROR: No se pudo establecer conexión con la base de datos Azure SQL." >&2
  echo "       Host    : ${SQL_FQDN}" >&2
  echo "       Base de datos: ${DB_NAME}" >&2
  echo "       Detalle : ${DB_CONNECT_CHECK}" >&2
  echo "       Verificar que el servidor SQL está activo, el firewall permite la VM," >&2
  echo "       y las credenciales en Key Vault son correctas." >&2
  exit 1
fi
echo "  -> Conectividad con Azure SQL verificada correctamente."

# Ejecutar migraciones de base de datos como usuario redmine
echo "  -> Ejecutando migraciones de base de datos..."
sudo -u redmine bundle exec rake db:migrate RAILS_ENV=production
echo "  -> Migraciones de base de datos completadas."

# Por qué ejecutar migraciones de plugins:
#   Los plugins de Redmine pueden requerir cambios en el esquema de la base
#   de datos. Si no se ejecuta esta migración, las tablas del plugin OIDC
#   no existirán y la autenticación fallará en tiempo de ejecución.
echo "  -> Ejecutando migraciones de plugins..."
sudo -u redmine bundle exec rake redmine:plugins:migrate RAILS_ENV=production
echo "  -> Migraciones de plugins completadas."

#############################################
# SECCIÓN 7 – CONFIGURACIÓN DE OIDC / ENTRA ID
#############################################
# Se configura la autenticación OpenID Connect con Microsoft Entra ID.
#
# Detalles técnicos:
#   - Plugin: redmine_omniauth_openid_connect (instalado en sección 5)
#   - Issuer: endpoint v2.0 de Microsoft (compatible con tokens Entra ID)
#   - client_auth_method: client_secret_post (requerido por Entra ID)
#   - redirect_uri: debe coincidir exactamente con el URI registrado en la App
#   - discovery: true (descarga automáticamente el metadata del endpoint OIDC)
#
# Por qué idempotencia en el initializer:
#   Sobreescribir el initializer en cada ejecución puede causar
#   duplicación de middleware o errores de configuración en caliente.

echo "[7/9] Configurando autenticación OIDC con Microsoft Entra ID..."

OIDC_INITIALIZER="config/initializers/01_openid_connect.rb"

if [ ! -f "${OIDC_INITIALIZER}" ]; then
  echo "  -> Creando initializer OIDC..."
  mkdir -p "$(dirname "${OIDC_INITIALIZER}")"
  cat <<EOF > "${OIDC_INITIALIZER}"
# Initializer de OmniAuth OpenID Connect para Microsoft Entra ID
# Generado automáticamente por redmine-bicepv2.sh
require 'omniauth'
require 'omniauth-openid-connect'

RedmineApp::Application.config.after_initialize do
  OmniAuth.config.allowed_request_methods = [:post, :get]

  Rails.application.config.middleware.use OmniAuth::Builder do
    provider :openid_connect, {
      name: :oidc,
      # Issuer v2.0 de Microsoft Entra ID: necesario para validación de tokens JWT
      issuer: "https://login.microsoftonline.com/${TENANT_ID}/v2.0",
      # Descarga automática del metadata OpenID del endpoint del proveedor
      discovery: true,
      # client_secret_post: método de autenticación requerido por Entra ID
      client_auth_method: :client_secret_post,
      scope: [:openid, :profile, :email],
      client_options: {
        identifier: "${CLIENT_ID}",
        secret: "${ENTRA_CLIENT_SECRET}",
        # El redirect_uri debe coincidir exactamente con el registrado en Entra ID
        redirect_uri: "https://${APPGW_FQDN}/auth/oidc/callback"
      }
    }
  end
end
EOF
  # chmod 600: el initializer contiene el client_secret de Entra ID
  chmod 600 "${OIDC_INITIALIZER}"
  chown redmine:redmine "${OIDC_INITIALIZER}"
  echo "  -> Initializer OIDC creado con permisos seguros (600)."
else
  echo "  -> Verificando contenido del initializer OIDC existente..."

  OIDC_ISSUE=0

  if ! grep -q "client_secret_post" "${OIDC_INITIALIZER}"; then
    echo "ADVERTENCIA: El initializer OIDC existe pero no contiene 'client_secret_post'." >&2
    OIDC_ISSUE=1
  fi

  if ! grep -q "${APPGW_FQDN}/auth/oidc/callback" "${OIDC_INITIALIZER}"; then
    echo "ADVERTENCIA: El initializer OIDC existe pero el callback no coincide con APPGW_FQDN '${APPGW_FQDN}'." >&2
    OIDC_ISSUE=1
  fi

  if ! grep -q "${TENANT_ID}" "${OIDC_INITIALIZER}"; then
    echo "ADVERTENCIA: El initializer OIDC existe pero no contiene TENANT_ID '${TENANT_ID}'." >&2
    OIDC_ISSUE=1
  fi

  if ! grep -q "${CLIENT_ID}" "${OIDC_INITIALIZER}"; then
    echo "ADVERTENCIA: El initializer OIDC existe pero no contiene CLIENT_ID '${CLIENT_ID}'." >&2
    OIDC_ISSUE=1
  fi

  if [ "${OIDC_ISSUE}" -eq 1 ]; then
    echo "ERROR: El initializer OIDC '${OIDC_INITIALIZER}' existe pero contiene valores inconsistentes." >&2
    echo "       NO se sobreescribe automáticamente para evitar romper la autenticación en curso." >&2
    echo "       Revisar manualmente el archivo y reejecutar el script si es necesario borrarlo primero." >&2
    exit 1
  fi

  echo "  -> Initializer OIDC validado correctamente. Omitiendo creación (idempotente)."
  # Reforzar permisos seguros sin importar el origen del archivo
  chmod 600 "${OIDC_INITIALIZER}"
  chown redmine:redmine "${OIDC_INITIALIZER}"
fi

# Configurar configuration.yml para habilitar omniauth en Redmine
CONFIG_YML="config/configuration.yml"
if ! grep -q "omniauth" "${CONFIG_YML}" 2>/dev/null; then
  echo "  -> Habilitando omniauth en ${CONFIG_YML}..."
  cat <<'EOF' >> "${CONFIG_YML}"

production:
  omniauth_enabled: true
  omniauth_login_selector: true
  omniauth_auto_register: true
  omniauth_auto_login: false
EOF
  echo "  -> Omniauth habilitado en configuración."
else
  echo "  -> Configuración omniauth ya presente en ${CONFIG_YML}."
fi

echo "  -> Configuración OIDC completada."

#############################################
# SECCIÓN 8 – SERVICIO PUMA Y SYSTEMD
#############################################
# Se configura Puma como servidor de aplicaciones Rails de Redmine.
# Se usa systemd para garantizar inicio automático y reinicio ante fallos.
#
# Por qué /usr/bin/env bundle exec puma:
#   Usar la ruta completa a env garantiza que el bundler encuentre las
#   gemas correctas del directorio de trabajo, independientemente del PATH.
#
# Por qué daemon-reload + enable + restart:
#   - daemon-reload: recarga las definiciones de unit de systemd tras cambios
#   - enable: asegura inicio automático al arrancar el sistema
#   - restart: aplica la configuración actual inmediatamente

echo "[8/9] Configurando servicio Redmine Puma (systemd)..."

# Validar que bundle esté disponible antes de configurar el servicio
if ! command -v bundle &>/dev/null; then
  echo "ERROR: No se encontró el comando 'bundle'. Bundler no está correctamente instalado." >&2
  echo "       Verificar la instalación de Ruby y Bundler antes de continuar." >&2
  exit 1
fi
echo "  -> bundler disponible: $(bundle --version)"

# Archivo de configuración de Puma
cat <<'EOF' > config/puma.rb
# Configuración de Puma para Redmine en producción
environment 'production'
threads 0, 5
workers 2
preload_app!
bind 'tcp://127.0.0.1:3000'
EOF

# Unit de systemd para el servicio Redmine
cat <<'EOF' > /etc/systemd/system/redmine.service
[Unit]
Description=Servidor HTTP Puma para Redmine
After=network.target

[Service]
Type=simple
User=redmine
WorkingDirectory=/opt/redmine
# Se usa /usr/bin/env para resolver bundler en el contexto correcto de la aplicación
ExecStart=/usr/bin/env bundle exec puma -C config/puma.rb
Restart=always
RestartSec=1
Environment=RAILS_ENV=production

[Install]
WantedBy=multi-user.target
EOF

echo "  -> Recargando daemon de systemd..."
systemctl daemon-reload

echo "  -> Habilitando servicio redmine para inicio automático..."
systemctl enable redmine

echo "  -> Reiniciando servicio redmine..."
systemctl restart redmine

# Verificar que el servicio quedó activo tras el reinicio (con reintentos)
MAX_WAIT=15
for i in $(seq 1 $MAX_WAIT); do
  if systemctl is-active --quiet redmine; then
    echo "  -> Servicio 'redmine' activo y funcionando correctamente."
    break
  fi
  if [ "$i" -eq "$MAX_WAIT" ]; then
    echo "ERROR: El servicio 'redmine' no está activo después de ${MAX_WAIT}s de espera." >&2
    echo "       Estado actual:" >&2
    systemctl status redmine --no-pager >&2
    exit 1
  fi
  sleep 1
done

#############################################
# SECCIÓN 9 – CONFIGURACIÓN DE NGINX
#############################################
# Nginx actúa como proxy inverso frente a Puma (puerto 3000).
# Recibe tráfico en el puerto 80 desde el Application Gateway.
#
# Por qué X-Forwarded-Proto: https (fijo):
#   El Application Gateway termina TLS y envía tráfico interno en HTTP.
#   Si Nginx reenvía $scheme, el valor sería "http", lo que causaría que
#   Redmine genere URLs con http://, rompiendo la redirección OIDC y los
#   links de la aplicación. Forzar el valor a "https" garantiza que Redmine
#   trate siempre la conexión como segura, independientemente del protocolo
#   interno entre el Gateway y la VM.

echo "[9/9] Configurando Nginx como proxy inverso..."

cat <<'EOF' > /etc/nginx/sites-available/redmine
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        # Se fuerza https porque el TLS lo termina el Application Gateway.
        # Usar $scheme devolvería 'http' y rompería Redmine y el callback OIDC.
        proxy_set_header X-Forwarded-Proto https;
    }
}
EOF

# Activar el sitio de Redmine como sitio por defecto
ln -sf /etc/nginx/sites-available/redmine /etc/nginx/sites-enabled/default

echo "  -> Validando configuración de Nginx antes de reiniciar..."
if ! nginx -t; then
  echo "ERROR: La configuración de Nginx contiene errores. Se aborta el reinicio." >&2
  echo "       Revisar el archivo /etc/nginx/sites-available/redmine." >&2
  exit 1
fi

echo "  -> Configuración de Nginx válida. Reiniciando..."
systemctl restart nginx
echo "  -> Nginx configurado y activo."

#############################################
# SECCIÓN FINAL – PERMISOS Y RESULTADO
#############################################
# Se aplican permisos finales sobre el directorio completo de Redmine.
# Esto garantiza que el usuario 'redmine' tenga acceso correcto a todos
# los archivos generados durante la configuración.

echo "Aplicando permisos finales sobre /opt/redmine..."
chown -R redmine:redmine /opt/redmine

echo ""
echo "======================================================"
echo "  Despliegue de Redmine Bicep V2 completado."
echo ""
echo "  Acceso: https://${APPGW_FQDN}"
echo "  Login OIDC: https://${APPGW_FQDN}/auth/oidc"
echo "======================================================"
