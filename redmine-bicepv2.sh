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
#   - Ubuntu 22.04 LTS (Jammy Jellyfish)
#
# Idempotencia:
#   - Cada sección verifica si el recurso ya existe antes de actuar.
#   - Esto permite re-ejecutar el script sin efectos destructivos.
#
# Compatibilidad Azure CSE:
#   - El Azure Custom Script Extension ejecuta el script como root en un
#     entorno de shell restringido sin PATH enriquecido ni cache APT.
#     Este script aplica todas las mitigaciones necesarias.
# =============================================================================

# -----------------------------------------------------------------------------
# CONFIGURACIÓN DE BASH SEGURO
# set -e   : aborta en cualquier error no capturado
# set -o pipefail : propaga errores dentro de pipes (ej: curl | gpg)
# DEBIAN_FRONTEND : evita prompts interactivos de debconf durante apt-get
# PATH enriquecido: Azure CSE puede no incluir /usr/local/bin en el PATH
# -----------------------------------------------------------------------------
set -e
set -o pipefail
export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Logging con timestamp para diagnóstico en Azure CSE
log() {
  echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] $*"
}
log_error() {
  echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] ERROR: $*" >&2
}

log "======================================================="
log "  Inicio del despliegue de Redmine Bicep V2"
log "  Ubuntu: $(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2)"
log "  Kernel : $(uname -r)"
log "  User   : $(whoami)"
log "======================================================="

#############################################
# SECCIÓN 0 – VALIDACIÓN DE ARGUMENTOS
#############################################
# Se validan los 6 argumentos obligatorios antes de ejecutar cualquier paso.
# Un error temprano evita ejecuciones parciales con variables vacías.

if [ "$#" -ne 6 ]; then
  log_error "Número incorrecto de argumentos. Se requieren exactamente 6."
  log_error ""
  log_error "Uso: $0 KEY_VAULT_NAME SQL_FQDN DB_NAME TENANT_ID CLIENT_ID APPGW_FQDN"
  log_error ""
  log_error "  KEY_VAULT_NAME  : Nombre del Key Vault de Azure"
  log_error "  SQL_FQDN        : FQDN del servidor Azure SQL (debe contener .database.windows.net)"
  log_error "  DB_NAME         : Nombre de la base de datos"
  log_error "  TENANT_ID       : ID del tenant de Microsoft Entra ID (no puede estar vacío)"
  log_error "  CLIENT_ID       : Client ID de la App Registration de Entra ID (no puede estar vacío)"
  log_error "  APPGW_FQDN      : FQDN público del Application Gateway (no puede estar vacío)"
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
  log_error "KEY_VAULT_NAME no puede estar vacío."
  exit 1
fi

if [[ "${SQL_FQDN}" != *".database.windows.net"* ]]; then
  log_error "SQL_FQDN ('${SQL_FQDN}') no parece ser un FQDN de Azure SQL válido."
  log_error "       Debe contener '.database.windows.net'."
  exit 1
fi

if [[ -z "${DB_NAME}" ]]; then
  log_error "DB_NAME no puede estar vacío."
  exit 1
fi

if [[ -z "${TENANT_ID}" ]]; then
  log_error "TENANT_ID no puede estar vacío. Se requiere para la autenticación OIDC con Entra ID."
  exit 1
fi

if [[ -z "${CLIENT_ID}" ]]; then
  log_error "CLIENT_ID no puede estar vacío. Se requiere para la autenticación OIDC con Entra ID."
  exit 1
fi

if [[ -z "${APPGW_FQDN}" ]]; then
  log_error "APPGW_FQDN no puede estar vacío. Se requiere para construir el callback OIDC."
  exit 1
fi

log "  Key Vault: ${KEY_VAULT_NAME}"
log "  SQL FQDN : ${SQL_FQDN}"
log "  DB       : ${DB_NAME}"
log "  FQDN GW  : ${APPGW_FQDN}"

#############################################
# SECCIÓN 1 – PREPARACIÓN DEL SISTEMA
#############################################
# Se actualiza el sistema operativo y se instalan todas las dependencias
# necesarias para compilar y ejecutar Redmine, incluyendo Ruby, Node.js,
# Nginx y las librerías de desarrollo de sistema.
#
# CAUSA RAÍZ DE LOS ERRORES APT:
#   El Azure Custom Script Extension ejecuta el script en un entorno de shell
#   mínimo donde la cache de APT puede estar vacía o corrupta, y los
#   repositorios "universe" y "multiverse" de Ubuntu pueden no estar habilitados.
#   Los paquetes build-essential, libssl-dev, ruby-full, nginx, nodejs,
#   entre otros, requieren el repositorio "universe" en Ubuntu 22.04.
#
# SOLUCIÓN:
#   1. Limpiar cache APT para forzar descarga de índices frescos
#   2. Habilitar repositorios universe y multiverse explícitamente
#   3. Actualizar índices de paquetes forzando descarga completa
#   4. Instalar dependencias con apt-get (más robusto que apt en scripts)

log "[1/9] Preparando sistema APT y habilitando repositorios Ubuntu..."

# Instalar software-properties-common si no está presente
# (requerido para add-apt-repository)
if ! command -v add-apt-repository &>/dev/null; then
  log "  -> Instalando software-properties-common para add-apt-repository..."
  # Primer apt-get update mínimo para poder instalar el tool
  apt-get update -qq -o Acquire::CompressionTypes::Order::=gz || true
  apt-get install -y -qq software-properties-common
fi

# Habilitar repositorios universe y multiverse
# (requeridos para build-essential, ruby-full, libssl-dev, nodejs, nginx, etc.)
log "  -> Habilitando repositorios universe y multiverse de Ubuntu..."
add-apt-repository universe -y
add-apt-repository multiverse -y

# Limpiar cache APT y listas obsoletas para forzar una descarga limpia
# Esto resuelve el problema de listas corruptas o incompletas en Azure CSE
log "  -> Limpiando cache APT para garantizar listas de paquetes frescas..."
apt-get clean
rm -rf /var/lib/apt/lists/*

# Actualizar índices de paquetes (con reintento para resiliencia de red)
log "  -> Actualizando índices de paquetes (apt-get update)..."
for attempt in 1 2 3; do
  if apt-get update -y; then
    log "  -> apt-get update completado exitosamente (intento ${attempt})."
    break
  fi
  log "  -> apt-get update falló (intento ${attempt}/3). Reintentando en 10s..."
  sleep 10
  if [ "$attempt" -eq 3 ]; then
    log_error "apt-get update falló después de 3 intentos. Abortando."
    exit 1
  fi
done

# Instalar dependencias del sistema usando apt-get
# Se usa apt-get (en lugar de apt) porque es la herramienta diseñada
# para uso en scripts: salida predecible, sin prompts interactivos.
log "  -> Instalando dependencias del sistema..."
apt-get install -y \
  curl \
  git \
  gnupg \
  lsb-release \
  build-essential \
  libssl-dev \
  libreadline-dev \
  zlib1g-dev \
  libyaml-dev \
  libxml2-dev \
  libxslt1-dev \
  libffi-dev \
  libpq-dev \
  nginx \
  ruby-full \
  ruby-dev

if [ $? -ne 0 ]; then
  log_error "Falló la instalación de dependencias del sistema. Abortando."
  exit 1
fi
log "  -> Dependencias del sistema instaladas correctamente."

# Instalar Node.js desde NodeSource para Ubuntu 22.04 (Jammy)
# MOTIVO: El paquete nodejs del repositorio universe de Ubuntu 22.04 es la
# versión 12.x, que es demasiado antigua para Redmine y puede fallar.
# NodeSource provee la LTS actual (18.x o 20.x) directamente.
log "  -> Instalando Node.js 18.x desde NodeSource..."
if ! command -v node &>/dev/null || ! node --version | grep -qE '^v1[89]\.|^v2[0-9]\.'; then
  curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
  apt-get install -y nodejs
  log "  -> Node.js $(node --version) instalado correctamente."
else
  log "  -> Node.js $(node --version) ya está instalado y es compatible."
fi

# Instalar npm global packages
if ! command -v yarn &>/dev/null; then
  log "  -> Instalando yarn..."
  npm install --global yarn
fi

# Instalar bundler para gestión de gemas de Ruby (idempotente)
if ! command -v bundle &>/dev/null; then
  log "  -> Instalando bundler..."
  gem install bundler
else
  log "  -> bundler ya está instalado: $(bundle --version)"
fi

log "  -> [1/9] Preparación del sistema completada."

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

log "[2/9] Verificando instalación de Azure CLI..."

if ! command -v az &>/dev/null; then
  log "  -> Azure CLI no encontrado. Instalando..."
  mkdir -p /etc/apt/keyrings
  curl -sLS https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor \
    | tee /etc/apt/keyrings/microsoft.gpg > /dev/null
  chmod go+r /etc/apt/keyrings/microsoft.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] \
https://packages.microsoft.com/repos/azure-cli/ $(lsb_release -cs) main" \
    | tee /etc/apt/sources.list.d/azure-cli.list
  apt-get update -y
  apt-get install -y azure-cli
  log "  -> Azure CLI instalado correctamente."
else
  log "  -> Azure CLI ya está instalado: $(az version --query '\"azure-cli\"' -o tsv 2>/dev/null || echo 'versión desconocida')"
fi

# Autenticarse con Managed Identity ANTES de cualquier operación con Key Vault.
# Si esto falla, el script se detiene inmediatamente (set -e lo garantiza).
log "  -> Autenticando con Managed Identity..."
if ! az login --identity --output none 2>/dev/null; then
  log_error "No se pudo autenticar con Managed Identity."
  log_error "       Verificar que la VM tiene una identidad asignada y tiene acceso al Key Vault."
  exit 1
fi
log "  -> Autenticación con Managed Identity completada."
log "  -> [2/9] Azure CLI listo."

#############################################
# SECCIÓN 3 – RECUPERACIÓN DE SECRETOS DESDE KEY VAULT
#############################################
# Se recuperan los tres secretos necesarios desde Azure Key Vault.
# Se utiliza --query value -o tsv para obtener únicamente el valor del secreto
# sin metadatos adicionales en formato JSON.
#
# Por qué no hardcodear credenciales:
#   Almacenar contraseñas en el script representa un riesgo crítico de seguridad.
#   Key Vault garantiza rotación, auditoría y acceso controlado por IAM.
#
# Por qué reintentos con retardo (get_secret_with_retry):
#   Las asignaciones RBAC en Azure tienen propagación eventual de hasta 10 minutos.
#   El intento inmediato después del despliegue del rol puede fallar con 403.

log "[3/9] Recuperando secretos desde Azure Key Vault: ${KEY_VAULT_NAME}..."

get_secret_with_retry() {
  local secret_name=$1
  local max_retries=60 # 60 * 10s = 600s = 10 minutos
  local wait_sec=10
  local secret_val=""

  log "  -> Obteniendo secreto: $secret_name (esperando propagación RBAC si es necesario)..."
  for i in $(seq 1 $max_retries); do
    secret_val=$(az keyvault secret show --vault-name "${KEY_VAULT_NAME}" --name "${secret_name}" --query "value" -o tsv 2>/dev/null) || true
    if [[ -n "$secret_val" ]]; then
      echo "$secret_val"
      return 0
    fi
    log "  -> Secreto '${secret_name}' no disponible aún (intento ${i}/${max_retries}). Esperando ${wait_sec}s..."
    sleep $wait_sec
  done
  log_error "Fallo al obtener el secreto $secret_name después de $((max_retries * wait_sec)) segundos."
  return 1
}

SQL_PASSWORD=$(get_secret_with_retry "sql-admin-password") || exit 1
log "  -> sql-admin-password recuperado correctamente."

REDMINE_SECRET_KEY=$(get_secret_with_retry "redmine-secret-key") || exit 1
log "  -> redmine-secret-key recuperado correctamente."

ENTRA_CLIENT_SECRET=$(get_secret_with_retry "entra-client-secret") || exit 1
log "  -> entra-client-secret recuperado correctamente."

log "  -> Todos los secretos recuperados exitosamente."
log "  -> [3/9] Secretos de Key Vault obtenidos."

#############################################
# SECCIÓN 4 – DRIVER ODBC DE MICROSOFT SQL
#############################################
# Se instala el driver ODBC de Microsoft para conectarse a Azure SQL Database.
# Esto es requerido por el adaptador activerecord-sqlserver-adapter.
# La verificación de idempotencia evita reinstalaciones innecesarias.

log "[4/9] Verificando driver Microsoft ODBC para SQL Server..."

if ! dpkg -l | grep -q msodbcsql17; then
  log "  -> Instalando driver msodbcsql17..."
  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor \
    | tee /etc/apt/keyrings/microsoft-prod.gpg > /dev/null
  curl -fsSL https://packages.microsoft.com/config/ubuntu/22.04/prod.list \
    | tee /etc/apt/sources.list.d/mssql-release.list > /dev/null
  apt-get update -y
  ACCEPT_EULA=Y apt-get install -y msodbcsql17 mssql-tools unixodbc-dev
  log "  -> Driver ODBC instalado correctamente."
else
  log "  -> Driver msodbcsql17 ya está instalado."
fi
log "  -> [4/9] Driver ODBC verificado."

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

log "[5/9] Instalando Redmine y plugins..."

if [ ! -d "/opt/redmine" ]; then
  log "  -> Clonando Redmine 5.1-stable..."
  git clone -b 5.1-stable https://github.com/redmine/redmine.git /opt/redmine
  log "  -> Redmine clonado correctamente."
else
  log "  -> Directorio /opt/redmine ya existe. Omitiendo clonado."
fi

# Crear usuario de sistema para Redmine si no existe
if ! id -u redmine > /dev/null 2>&1; then
  log "  -> Creando usuario del sistema 'redmine'..."
  useradd -r -d /opt/redmine -s /bin/bash redmine
  log "  -> Usuario 'redmine' creado."
else
  log "  -> Usuario 'redmine' ya existe."
fi

# Garantizar propiedad del directorio en todos los casos
chown -R redmine:redmine /opt/redmine

# Instalar plugin OIDC si no está presente (idempotente)
OIDC_PLUGIN_DIR="/opt/redmine/plugins/redmine_omniauth_openid_connect"
if [ ! -d "${OIDC_PLUGIN_DIR}" ]; then
  log "  -> Clonando plugin redmine_omniauth_openid_connect..."
  mkdir -p /opt/redmine/plugins
  git clone https://github.com/ale/redmine_omniauth_openid_connect.git \
    "${OIDC_PLUGIN_DIR}"
  log "  -> Plugin OIDC instalado."
else
  log "  -> Plugin redmine_omniauth_openid_connect ya existe. Omitiendo clonado."
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

log "  -> Instalando gemas de Ruby (bundle install)..."
sudo -u redmine bundle config set --local without 'development test'

# Crear directorios requeridos por Rails antes de bundle/rake
mkdir -p log tmp/pids tmp/sockets tmp/cache public/plugin_assets
chown -R redmine:redmine /opt/redmine

# Ejecutar bundle install como usuario redmine para evitar archivos propiedad de root
sudo -u redmine bundle install
log "  -> Gemas instaladas correctamente."
log "  -> [5/9] Redmine y plugins instalados."

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

log "[6/9] Configurando database.yml..."

DATABASE_YML="config/database.yml"

if [ ! -f "${DATABASE_YML}" ]; then
  log "  -> Creando ${DATABASE_YML}..."
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
  log "  -> ${DATABASE_YML} creado con permisos seguros (600)."
else
  log "  -> ${DATABASE_YML} ya existe. Validando contenido..."
  VALIDATION_FAILED=0

  if ! grep -q "${SQL_FQDN}" "${DATABASE_YML}"; then
    log_error "ADVERTENCIA: ${DATABASE_YML} no contiene el host esperado ('${SQL_FQDN}')."
    VALIDATION_FAILED=1
  fi

  if ! grep -q "${DB_NAME}" "${DATABASE_YML}"; then
    log_error "ADVERTENCIA: ${DATABASE_YML} no contiene la base de datos esperada ('${DB_NAME}')."
    VALIDATION_FAILED=1
  fi

  if [ "${VALIDATION_FAILED}" -eq 1 ]; then
    log_error "El archivo ${DATABASE_YML} existe pero su contenido no coincide con los parámetros proporcionados."
    log_error "       NO se sobreescribe para evitar pérdida de datos."
    log_error "       Revisar manualmente el archivo antes de continuar."
    exit 1
  fi

  log "  -> Contenido de ${DATABASE_YML} validado correctamente."
  # Reforzar permisos seguros en cualquier caso
  chmod 600 "${DATABASE_YML}"
  chown redmine:redmine "${DATABASE_YML}"
fi

# Configuración de la clave secreta de sesión de Redmine
SECRETS_YML="config/secrets.yml"
log "  -> Configurando ${SECRETS_YML}..."

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
log "  -> ${SECRETS_YML} configurado con permisos seguros (600)."

# --- Verificación de conectividad con la base de datos antes de migrar ---
log "  -> Verificando conectividad con Azure SQL antes de ejecutar migraciones..."

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
  log_error "No se pudo establecer conexión con la base de datos Azure SQL."
  log_error "       Host    : ${SQL_FQDN}"
  log_error "       Base de datos: ${DB_NAME}"
  log_error "       Detalle : ${DB_CONNECT_CHECK}"
  log_error "       Verificar que el servidor SQL está activo, el firewall permite la VM,"
  log_error "       y las credenciales en Key Vault son correctas."
  exit 1
fi
log "  -> Conectividad con Azure SQL verificada correctamente."

# Ejecutar migraciones de base de datos como usuario redmine
log "  -> Ejecutando migraciones de base de datos..."
sudo -u redmine bundle exec rake db:migrate RAILS_ENV=production
log "  -> Migraciones de base de datos completadas."

# Por qué ejecutar migraciones de plugins:
#   Los plugins de Redmine pueden requerir cambios en el esquema de la base
#   de datos. Si no se ejecuta esta migración, las tablas del plugin OIDC
#   no existirán y la autenticación fallará en tiempo de ejecución.
log "  -> Ejecutando migraciones de plugins..."
sudo -u redmine bundle exec rake redmine:plugins:migrate RAILS_ENV=production
log "  -> Migraciones de plugins completadas."
log "  -> [6/9] Base de datos configurada."

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

log "[7/9] Configurando autenticación OIDC con Microsoft Entra ID..."

OIDC_INITIALIZER="config/initializers/01_openid_connect.rb"

if [ ! -f "${OIDC_INITIALIZER}" ]; then
  log "  -> Creando initializer OIDC..."
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
  log "  -> Initializer OIDC creado con permisos seguros (600)."
else
  log "  -> Verificando contenido del initializer OIDC existente..."

  OIDC_ISSUE=0

  if ! grep -q "client_secret_post" "${OIDC_INITIALIZER}"; then
    log_error "ADVERTENCIA: El initializer OIDC existe pero no contiene 'client_secret_post'."
    OIDC_ISSUE=1
  fi

  if ! grep -q "${APPGW_FQDN}/auth/oidc/callback" "${OIDC_INITIALIZER}"; then
    log_error "ADVERTENCIA: El initializer OIDC existe pero el callback no coincide con APPGW_FQDN '${APPGW_FQDN}'."
    OIDC_ISSUE=1
  fi

  if ! grep -q "${TENANT_ID}" "${OIDC_INITIALIZER}"; then
    log_error "ADVERTENCIA: El initializer OIDC existe pero no contiene TENANT_ID '${TENANT_ID}'."
    OIDC_ISSUE=1
  fi

  if ! grep -q "${CLIENT_ID}" "${OIDC_INITIALIZER}"; then
    log_error "ADVERTENCIA: El initializer OIDC existe pero no contiene CLIENT_ID '${CLIENT_ID}'."
    OIDC_ISSUE=1
  fi

  if [ "${OIDC_ISSUE}" -eq 1 ]; then
    log_error "El initializer OIDC '${OIDC_INITIALIZER}' existe pero contiene valores inconsistentes."
    log_error "       NO se sobreescribe automáticamente para evitar romper la autenticación en curso."
    log_error "       Revisar manualmente el archivo y reejecutar el script si es necesario borrarlo primero."
    exit 1
  fi

  log "  -> Initializer OIDC validado correctamente. Omitiendo creación (idempotente)."
  # Reforzar permisos seguros sin importar el origen del archivo
  chmod 600 "${OIDC_INITIALIZER}"
  chown redmine:redmine "${OIDC_INITIALIZER}"
fi

# Configurar configuration.yml para habilitar omniauth en Redmine
CONFIG_YML="config/configuration.yml"
if ! grep -q "omniauth" "${CONFIG_YML}" 2>/dev/null; then
  log "  -> Habilitando omniauth en ${CONFIG_YML}..."
  cat <<'EOF' >> "${CONFIG_YML}"

production:
  omniauth_enabled: true
  omniauth_login_selector: true
  omniauth_auto_register: true
  omniauth_auto_login: false
EOF
  log "  -> Omniauth habilitado en configuración."
else
  log "  -> Configuración omniauth ya presente en ${CONFIG_YML}."
fi

log "  -> [7/9] Configuración OIDC completada."

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

log "[8/9] Configurando servicio Redmine Puma (systemd)..."

# Validar que bundle esté disponible antes de configurar el servicio
if ! command -v bundle &>/dev/null; then
  log_error "No se encontró el comando 'bundle'. Bundler no está correctamente instalado."
  log_error "       Verificar la instalación de Ruby y Bundler antes de continuar."
  exit 1
fi
log "  -> bundler disponible: $(bundle --version)"

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

log "  -> Recargando daemon de systemd..."
systemctl daemon-reload

log "  -> Habilitando servicio redmine para inicio automático..."
systemctl enable redmine

log "  -> Reiniciando servicio redmine..."
systemctl restart redmine

# Verificar que el servicio quedó activo tras el reinicio (con reintentos)
MAX_WAIT=15
for i in $(seq 1 $MAX_WAIT); do
  if systemctl is-active --quiet redmine; then
    log "  -> Servicio 'redmine' activo y funcionando correctamente."
    break
  fi
  if [ "$i" -eq "$MAX_WAIT" ]; then
    log_error "El servicio 'redmine' no está activo después de ${MAX_WAIT}s de espera."
    log_error "       Estado actual:"
    systemctl status redmine --no-pager >&2
    exit 1
  fi
  sleep 1
done
log "  -> [8/9] Servicio Puma configurado."

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

log "[9/9] Configurando Nginx como proxy inverso..."

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

log "  -> Validando configuración de Nginx antes de reiniciar..."
if ! nginx -t; then
  log_error "La configuración de Nginx contiene errores. Se aborta el reinicio."
  log_error "       Revisar el archivo /etc/nginx/sites-available/redmine."
  exit 1
fi

log "  -> Configuración de Nginx válida. Reiniciando..."
systemctl restart nginx
log "  -> Nginx configurado y activo."
log "  -> [9/9] Nginx configurado."

#############################################
# SECCIÓN FINAL – PERMISOS Y RESULTADO
#############################################
# Se aplican permisos finales sobre el directorio completo de Redmine.
# Esto garantiza que el usuario 'redmine' tenga acceso correcto a todos
# los archivos generados durante la configuración.

log "Aplicando permisos finales sobre /opt/redmine..."
chown -R redmine:redmine /opt/redmine

log ""
log "======================================================="
log "  Despliegue de Redmine Bicep V2 completado."
log ""
log "  Acceso: https://${APPGW_FQDN}"
log "  Login OIDC: https://${APPGW_FQDN}/auth/oidc"
log "======================================================="
