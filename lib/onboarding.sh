#!/bin/bash
# lib/onboarding.sh - Asistente de configuración inicial

# Usar VOIDCLAW_BASE_DIR si está definido
if [[ -n "$VOIDCLAW_BASE_DIR" ]]; then
    SCRIPT_DIR="${VOIDCLAW_BASE_DIR}/lib"
    CONFIG_FILE="${VOIDCLAW_BASE_DIR}/config/settings.json"
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    CONFIG_FILE="${SCRIPT_DIR}/../config/settings.json"
fi

# Variables globales para resultados
ONBOARD_API_KEY=""
ONBOARD_MODEL=""
ONBOARD_LOOP_ENABLED=""
ONBOARD_LOOP_INTERVAL=""
ONBOARD_LOOP_MAX_ITER=""
ONBOARD_DAEMON_ENABLED=""
ONBOARD_SKILLS=""

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Muestra mensaje de bienvenida
onboarding_welcome() {
    clear
    echo -e "${BLUE}"
    cat << 'EOF'
  ___  ____  ___  ___________ _____ ______ 
 / _ \/ __ \/ _ \/ __/ __/ //_/ _ / __/ / 
/ ___/ /_/ / ___/ _// _// ,< / __/\ \/_/  
/_/  \____/_/  /___/___/_/|_/_/  /___(_)   
                                           
         CONFIGURACIÓN INICIAL
EOF
    echo -e "${NC}"
    echo "Bienvenido a OpenClaw - Tu asistente AI de código abierto"
    echo ""
    echo "Este asistente te ayudará a configurar tu entorno."
    echo ""
}

# Pregunta por API Key
onboarding_ask_api_key() {
    echo -e "${YELLOW}=== Configuración de OpenAI ===${NC}"
    echo ""
    echo "Necesitas una API Key de OpenAI para usar OpenClaw."
    echo ""
    echo "Puedes obtener una en: https://platform.openai.com/api-keys"
    echo ""
    read -p "Ingresa tu API Key de OpenAI: " ONBOARD_API_KEY
    
    if [[ -z "$ONBOARD_API_KEY" ]]; then
        echo -e "${RED}Error: La API Key no puede estar vacía${NC}"
        return 1
    fi
    
    # Validar formato (sk-...)
    if [[ ! "$ONBOARD_API_KEY" =~ ^sk-[a-zA-Z0-9]+ ]]; then
        echo -e "${YELLOW}Advertencia: El formato de la API Key parece incorrecto${NC}"
        read -p "¿Continuar de todos modos? (y/n): " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            return 1
        fi
    fi
    
    return 0
}

# Pregunta por modelo
onboarding_ask_model() {
    echo ""
    echo -e "${YELLOW}=== Selección de Modelo ===${NC}"
    echo ""
    echo "Modelos disponibles:"
    echo "  1) gpt-4o-mini (recomendado - económico y rápido)"
    echo "  2) gpt-4o (más potente)"
    echo "  3) gpt-3.5-turbo (más económico)"
    echo "  4) Personalizado"
    echo ""
    read -p "Selecciona una opción [1-4]: " model_option

    case "$model_option" in
        1) ONBOARD_MODEL="gpt-4o-mini" ;;
        2) ONBOARD_MODEL="gpt-4o" ;;
        3) ONBOARD_MODEL="gpt-3.5-turbo" ;;
        4) 
            read -p "Ingresa el nombre del modelo: " ONBOARD_MODEL
            ;;
        *) ONBOARD_MODEL="gpt-4o-mini" ;;
    esac
    
    return 0
}

# Pregunta por configuración del loop
onboarding_ask_loop() {
    echo ""
    echo -e "${YELLOW}=== Configuración del Loop Automático ===${NC}"
    echo ""
    echo "OpenClaw puede ejecutar tareas automáticamente en segundo plano."
    echo ""
    
    # Detectar sistema de init disponible
    local init_system="none"
    if command -v systemctl &>/dev/null; then
        if systemctl --user daemon-reexec &>/dev/null 2>&1; then
            init_system="systemd"
        fi
    elif command -v sv &>/dev/null && command -v runsvdir &>/dev/null; then
        init_system="runit"
    fi
    
    if [[ "$init_system" != "none" ]]; then
        echo "Sistema de init detectado: ${init_system}"
        echo ""
        echo "Puedes habilitar el daemon para que el loop se inicie automáticamente"
        echo "al iniciar sesión o arrancar el sistema."
        echo ""
        read -p "¿Deseas habilitar el daemon automático? (y/n): " loop_enabled

        if [[ "$loop_enabled" == "y" || "$loop_enabled" == "Y" ]]; then
            ONBOARD_LOOP_ENABLED="true"
            ONBOARD_DAEMON_ENABLED="true"
            read -p "Intervalo entre tareas (segundos) [5]: " ONBOARD_LOOP_INTERVAL
            ONBOARD_LOOP_INTERVAL="${ONBOARD_LOOP_INTERVAL:-5}"

            read -p "Máximo de iteraciones por sesión [0=ilimitado]: " ONBOARD_LOOP_MAX_ITER
            ONBOARD_LOOP_MAX_ITER="${ONBOARD_LOOP_MAX_ITER:-0}"
        else
            ONBOARD_LOOP_ENABLED="false"
            ONBOARD_DAEMON_ENABLED="false"
            ONBOARD_LOOP_INTERVAL=5
            ONBOARD_LOOP_MAX_ITER=50
        fi
    else
        echo -e "${YELLOW}No se detectó un sistema de init (systemd/runit)${NC}"
        echo "El loop se podrá ejecutar manualmente con: ./voidclaw.sh --loop"
        echo ""
        read -p "¿Configurar loop para ejecución manual? (y/n): " loop_enabled

        if [[ "$loop_enabled" == "y" || "$loop_enabled" == "Y" ]]; then
            ONBOARD_LOOP_ENABLED="false"  # No daemon
            ONBOARD_DAEMON_ENABLED="false"
            read -p "Intervalo entre tareas (segundos) [5]: " ONBOARD_LOOP_INTERVAL
            ONBOARD_LOOP_INTERVAL="${ONBOARD_LOOP_INTERVAL:-5}"

            read -p "Máximo de iteraciones por sesión [50]: " ONBOARD_LOOP_MAX_ITER
            ONBOARD_LOOP_MAX_ITER="${ONBOARD_LOOP_MAX_ITER:-50}"
        else
            ONBOARD_LOOP_ENABLED="false"
            ONBOARD_DAEMON_ENABLED="false"
            ONBOARD_LOOP_INTERVAL=5
            ONBOARD_LOOP_MAX_ITER=50
        fi
    fi

    return 0
}

# Pregunta por skills a habilitar
onboarding_ask_skills() {
    echo ""
    echo -e "${YELLOW}=== Habilidades (Skills) ===${NC}"
    echo ""
    echo "Skills disponibles:"
    echo "  - task_manager: Gestión de tareas"
    echo "  - file_ops: Operaciones con archivos"
    echo "  - system_ops: Operaciones del sistema"
    echo ""
    read -p "¿Habilitar todas las skills? (y/n): " all_skills
    
    if [[ "$all_skills" == "y" || "$all_skills" == "Y" ]]; then
        ONBOARD_SKILLS="task_manager,file_ops,system_ops"
    else
        ONBOARD_SKILLS="task_manager"
    fi
    
    return 0
}

# Guarda configuración
onboarding_save_config() {
    local api_key="$1"
    local model="$2"
    local loop_enabled="$3"
    local loop_interval="$4"
    local loop_max_iter="$5"
    local skills="$6"
    local daemon_enabled="$7"

    # Crear directorio config si no existe
    local config_dir
    config_dir="$(dirname "$CONFIG_FILE")"
    if [[ ! -d "$config_dir" ]]; then
        mkdir -p "$config_dir"
        log_info "Directorio de configuración creado: $config_dir"
    fi

    # Convertir skills a array JSON
    local skills_json="["
    local first=true
    IFS=',' read -ra SKILL_ARRAY <<< "$skills"
    for skill in "${SKILL_ARRAY[@]}"; do
        if [[ "$first" == true ]]; then
            first=false
            skills_json+="\"$skill\""
        else
            skills_json+=", \"$skill\""
        fi
    done
    skills_json+="]"

    # Detectar si es API Key de OpenRouter y usar URL correspondiente
    local base_url="https://api.openai.com/v1"
    if [[ "$api_key" == sk-or-v1-* ]]; then
        base_url="https://openrouter.ai/api/v1"
    fi

    # Crear JSON de configuración
    cat > "$CONFIG_FILE" << EOF
{
  "openai": {
    "api_key": "$api_key",
    "model": "$model",
    "base_url": "$base_url",
    "stream": true
  },
  "workspace": {
    "path": "./workspace",
    "max_tasks": 100,
    "auto_execute": false
  },
  "skills": {
    "enabled": $skills_json,
    "path": "./skills"
  },
  "loop": {
    "enabled": $loop_enabled,
    "interval_seconds": $loop_interval,
    "max_iterations": $loop_max_iter,
    "daemon": $daemon_enabled
  },
  "onboarding_completed": true
}
EOF

    log_info "Configuración guardada exitosamente"
}

# Función principal de onboarding
onboarding_run() {
    onboarding_welcome

    # Paso 1: API Key
    onboarding_ask_api_key
    if [[ $? -ne 0 || -z "$ONBOARD_API_KEY" ]]; then
        echo -e "${RED}Configuración cancelada${NC}"
        return 1
    fi
    echo -e "${GREEN}✓ API Key guardada${NC}"

    # Paso 2: Modelo
    onboarding_ask_model
    echo -e "${GREEN}✓ Modelo seleccionado: $ONBOARD_MODEL${NC}"

    # Paso 3: Loop/Daemon
    onboarding_ask_loop
    echo -e "${GREEN}✓ Loop configurado${NC}"

    # Paso 4: Skills
    onboarding_ask_skills
    echo -e "${GREEN}✓ Skills configuradas: $ONBOARD_SKILLS${NC}"

    # Guardar
    echo ""
    echo "Guardando configuración..."
    onboarding_save_config "$ONBOARD_API_KEY" "$ONBOARD_MODEL" "$ONBOARD_LOOP_ENABLED" "$ONBOARD_LOOP_INTERVAL" "$ONBOARD_LOOP_MAX_ITER" "$ONBOARD_SKILLS" "$ONBOARD_DAEMON_ENABLED"

    # Si se habilitó daemon, configurarlo ahora
    if [[ "$ONBOARD_DAEMON_ENABLED" == "true" ]]; then
        echo ""
        echo "Configurando daemon..."
        source "${SCRIPT_DIR}/daemon.sh"
        daemon_enable
    fi

    echo ""
    echo -e "${GREEN}================================${NC}"
    echo -e "${GREEN}  ¡Configuración completada!   ${NC}"
    echo -e "${GREEN}================================${NC}"
    echo ""
    echo "Configuración guardada en: $(realpath "$CONFIG_FILE")"
    echo ""
    echo "Comandos disponibles:"
    if [[ "$ONBOARD_DAEMON_ENABLED" == "true" ]]; then
        echo "  ./voidclaw.sh --daemon-status   - Ver estado del daemon"
        echo "  ./voidclaw.sh --daemon-stop     - Detener daemon"
        echo "  ./voidclaw.sh --loop            - Ejecución manual (sin daemon)"
    else
        echo "  ./voidclaw.sh --loop            - Ejecución manual del loop"
    fi
    echo "  ./voidclaw.sh --chat            - Modo interactivo"
    echo "  ./voidclaw.sh --task            - Crear tareas"
    echo ""

    return 0
}

# Verifica si onboarding ya fue completado
onboarding_is_complete() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        return 1
    fi
    
    local completed
    if command -v jq &>/dev/null; then
        completed=$(jq -r '.onboarding_completed // false' "$CONFIG_FILE" 2>/dev/null)
    else
        completed=$(grep -o '"onboarding_completed"[[:space:]]*:[[:space:]]*true' "$CONFIG_FILE")
        [[ -n "$completed" ]] && completed="true" || completed="false"
    fi
    
    [[ "$completed" == "true" ]]
}
