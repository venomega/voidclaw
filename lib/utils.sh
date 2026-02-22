#!/bin/bash
# lib/utils.sh - Utilidades comunes

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/../logs/voidclaw.log"

# Log general
log_info() {
    echo "[$(date -Iseconds)] [INFO] $*" >> "$LOG_FILE"
}

log_error() {
    echo "[$(date -Iseconds)] [ERROR] $*" >> "$LOG_FILE"
    echo "[ERROR] $*" >&2
}

log_debug() {
    if [[ "${DEBUG:-0}" == "1" ]]; then
        echo "[$(date -Iseconds)] [DEBUG] $*" >> "$LOG_FILE"
        echo "[DEBUG] $*" >&2
    fi
}

# Genera ID único
generate_id() {
    local prefix="${1:-id}"
    echo "${prefix}_$(date +%s)_$$_$RANDOM"
}

# Obtiene timestamp ISO8601
get_timestamp() {
    date -Iseconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S%z
}

# Verifica si jq está disponible
has_jq() {
    command -v jq &>/dev/null
}

# Verifica si curl está disponible
has_curl() {
    command -v curl &>/dev/null
}

# Verifica dependencias
check_dependencies() {
    local missing=()
    
    if ! has_curl; then
        missing+=("curl")
    fi
    
    if ! has_jq; then
        missing+=("jq")
        log_debug "jq no disponible, usando fallbacks"
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Dependencias faltantes: ${missing[*]}"
        echo "WARNING: Missing dependencies: ${missing[*]}" >&2
        return 1
    fi
    
    return 0
}

# Lee valor de JSON (con o sin jq)
json_get() {
    local json="$1"
    local key="$2"
    
    if has_jq; then
        echo "$json" | jq -r ".$key // empty" 2>/dev/null
    else
        echo "$json" | grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed 's/.*: *"\([^"]*\)"/\1/'
    fi
}

# Color output
color_red() { echo -e "\033[0;31m$*\033[0m"; }
color_green() { echo -e "\033[0;32m$*\033[0m"; }
color_yellow() { echo -e "\033[0;33m$*\033[0m"; }
color_blue() { echo -e "\033[0;34m$*\033[0m"; }

# Banner
print_banner() {
    cat << 'EOF'
  ___  ____  ___  ___________ _____ ______ 
 / _ \/ __ \/ _ \/ __/ __/ //_/ _ / __/ / 
/ ___/ /_/ / ___/ _// _// ,< / __/\ \/_/  
/_/  \____/_/  /___/___/_/|_/_/  /___(_)   
                                           
EOF
}

# Help message
print_help() {
    cat << 'EOF'
Uso: voidclaw.sh [OPCIONES]

Opciones principales:
  --onboard, -o     Iniciar configuración inicial
  --chat, -c        Modo chat interactivo
  --loop, -l        Ejecutar loop manualmente (una sesión)
  --task, -t        Crear tarea directa (ej: --task "copiar archivo")
  --status, -s      Mostrar estado del sistema
  --tools           Listar herramientas disponibles

Opciones del Daemon:
  --daemon-enable   Habilitar daemon (auto-inicio con el sistema)
  --daemon-disable  Deshabilitar daemon
  --daemon-start    Iniciar daemon manualmente
  --daemon-stop     Detener daemon
  --daemon-status   Ver estado del daemon
  --daemon-info     Información del daemon

Opciones generales:
  --help, -h        Mostrar esta ayuda

Ejemplos:
  ./voidclaw.sh --onboard
  ./voidclaw.sh --chat
  ./voidclaw.sh --daemon-enable    # Auto-inicio con systemd/runit
  ./voidclaw.sh --daemon-status    # Ver estado del daemon
  ./voidclaw.sh --loop             # Ejecución manual (sin daemon)
  ./voidclaw.sh --task "crear recordatorio"
EOF
}
