#!/bin/bash
# voidclaw.sh - Script principal de OpenClaw
# Tu asistente AI autónomo de código abierto

set -e

# Directorio base del script (siempre apunta a voidclaw/, no importa desde donde se llame)
if [[ "${BASH_SOURCE[0]}" == /* ]]; then
    SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
SCRIPT_DIR="$(cd "$SCRIPT_DIR" && pwd)"

# Directorio base absoluto
BASE_DIR="$SCRIPT_DIR"
export VOIDCLAW_BASE_DIR="$BASE_DIR"

# Cargar librerías
source "${BASE_DIR}/lib/utils.sh"
source "${BASE_DIR}/lib/openai_api.sh"
source "${BASE_DIR}/lib/tools.sh"
source "${BASE_DIR}/lib/onboarding.sh"
source "${BASE_DIR}/lib/loop.sh"
source "${BASE_DIR}/lib/daemon.sh"

# Cargar skills
load_skills() {
    for skill_file in "${BASE_DIR}/skills/"*.sh; do
        if [[ -f "$skill_file" ]]; then
            source "$skill_file"
            
            # Llamar a función de registro si existe
            local skill_name
            skill_name=$(basename "$skill_file" .sh)
            if declare -f "${skill_name}_register" &>/dev/null; then
                "${skill_name}_register"
            fi
        fi
    done
}

# Modo chat interactivo
mode_chat() {
    clear
    print_banner
    echo ""
    echo "Modo Chat Interactivo"
    echo "====================="
    echo "Escribe tus instrucciones o 'salir' para terminar"
    echo ""

    # Verificar si streaming está habilitado
    local stream_status="desactivado"
    if openai_is_stream_enabled 2>/dev/null; then
        stream_status="activado"
    fi
    echo "[STREAM: $stream_status]"
    echo ""

    # Cargar herramientas
    load_skills
    local tools_json
    tools_json=$(tools_get_all_json)

    local system_prompt="Eres un asistente útil que puede ejecutar tareas mediante herramientas.
Analiza la solicitud del usuario y usa las herramientas disponibles para completarla.
Si necesitas crear una tarea para ejecutar después, usa crear_tarea.
Responde de forma concisa en español."

    while true; do
        echo -n "> "
        read -r user_input

        if [[ "$user_input" == "salir" || "$user_input" == "exit" || "$user_input" == "q" ]]; then
            echo "¡Hasta luego!"
            break
        fi

        if [[ -z "$user_input" ]]; then
            continue
        fi

        # Enviar a OpenAI
        if ! openai_is_stream_enabled 2>/dev/null; then
            echo "Pensando..."
            local response
            response=$(openai_chat_with_tools "$user_input" "$system_prompt" "$tools_json")
        else
            # En modo streaming, mostrar indicador y llamar directamente (sin capturar stderr)
            echo -n "  "
            local temp_file
            temp_file=$(mktemp)
            openai_chat_stream "$user_input" "$system_prompt" "$tools_json" "$temp_file"
            local response
            response=$(cat "$temp_file")
            rm -f "$temp_file"
        fi

        if [[ "$response" == TOOL_CALLS:* ]]; then
            # Hay tool_calls
            local tool_calls
            tool_calls="${response#TOOL_CALLS:}"
            tools_parse_and_execute "$tool_calls"

            # Enviar resultados de vuelta
            echo ""
        elif [[ "$response" == ERROR:* ]]; then
            # Error de la API
            echo ""
            echo "ERROR: ${response#ERROR: }" >&2
            echo ""
        else
            # Respuesta normal
            if ! openai_is_stream_enabled 2>/dev/null; then
                echo ""
                echo "$response"
                echo ""
            else
                # Con streaming, la respuesta ya se mostró, solo newline
                echo ""
            fi
        fi
    done
}

# Crear tarea directa
mode_task() {
    local task_description="$1"
    
    if [[ -z "$task_description" ]]; then
        echo "ERROR: Debes proporcionar una descripción de tarea"
        echo "Uso: $0 --task \"descripción de la tarea\""
        return 1
    fi
    
    # Cargar skill de task_manager
    source "${BASE_DIR}/skills/task_manager.sh"
    
    # Consultar a OpenAI para determinar acción
    load_skills
    local tools_json
    tools_json=$(tools_get_all_json)
    
    local prompt="El usuario quiere crear esta tarea: \"$task_description\"
Analiza qué acción se necesita y crea la tarea apropiada usando crear_tarea."
    
    local response
    response=$(openai_chat_with_tools "$prompt" "Eres un asistente que crea tareas. Usa crear_tarea con la acción y parámetros apropiados." "$tools_json")
    
    if [[ "$response" == TOOL_CALLS:* ]]; then
        local tool_calls
        tool_calls="${response#TOOL_CALLS:}"
        tools_parse_and_execute "$tool_calls"
    else
        # Fallback: crear tarea genérica
        echo "Creando tarea genérica..."
        local task_id
        task_id=$(task_generate_id)
        local timestamp
        timestamp=$(date -Iseconds)
        
        if command -v jq &>/dev/null; then
            local new_task="{\"id\": \"$task_id\", \"created_at\": \"$timestamp\", \"description\": \"$task_description\", \"action\": \"system_ops.run\", \"params\": {\"command\": \"echo 'Tarea pendiente: $task_description'\"}, \"status\": \"pending\", \"priority\": 3, \"retry_count\": 0}"
            local temp_file
            temp_file=$(mktemp)
            jq ".tasks += [$new_task]" "${BASE_DIR}/workspace/tasks/pending.json" > "$temp_file"
            mv "$temp_file" "${BASE_DIR}/workspace/tasks/pending.json"
            echo "Tarea creada: $task_id"
        fi
    fi
}

# Modo status mejorado
mode_status() {
    print_banner
    echo ""
    echo "=== Estado de OpenClaw ==="
    echo ""

    # Configuración
    echo "Configuración:"
    if openai_is_configured; then
        local model
        model=$(openai_get_model)
        echo "  ✓ OpenAI configurado (modelo: $model)"
    else
        echo "  ✗ OpenAI NO configurado"
    fi

    if onboarding_is_complete; then
        echo "  ✓ Onboarding completado"
    else
        echo "  ✗ Onboarding pendiente"
    fi

    echo ""

    # Tareas
    echo "Tareas:"
    local pending_count
    pending_count=$(loop_count_pending)
    echo "  Pendientes: $pending_count"

    local completed_file="${BASE_DIR}/workspace/tasks/completed.json"
    if [[ -f "$completed_file" ]] && command -v jq &>/dev/null; then
        local completed_count
        completed_count=$(jq '.tasks | length' "$completed_file" 2>/dev/null)
        echo "  Completadas: ${completed_count:-0}"
    fi

    echo ""

    # Loop
    loop_status

    echo ""

    # Daemon
    echo "Daemon:"
    daemon_status
    echo ""

    # Skills
    echo "Skills cargados:"
    for skill_file in "${BASE_DIR}/skills/"*.sh; do
        if [[ -f "$skill_file" ]]; then
            local skill_name
            skill_name=$(basename "$skill_file" .sh)
            echo "  - $skill_name"
        fi
    done

    echo ""
}

# Listar herramientas
mode_tools() {
    echo "=== Herramientas Disponibles ==="
    echo ""
    
    load_skills
    tools_list
}

# Función principal
main() {
    # Verificar dependencias
    check_dependencies

    # Parsear argumentos
    case "${1:-}" in
        --onboard|-o)
            onboarding_run
            ;;
        --chat|-c)
            if ! onboarding_is_complete; then
                echo "Primero debes completar la configuración"
                echo "Ejecuta: $0 --onboard"
                exit 1
            fi
            mode_chat
            ;;
        --loop|-l)
            if ! onboarding_is_complete; then
                echo "Primero debes completar la configuración"
                echo "Ejecuta: $0 --onboard"
                exit 1
            fi
            loop_start
            ;;
        --loop-daemon)
            # Modo daemon interno (no verificar onboarding)
            daemon_run
            ;;
        --daemon-enable)
            if ! onboarding_is_complete; then
                echo "Primero debes completar la configuración"
                echo "Ejecuta: $0 --onboard"
                exit 1
            fi
            daemon_enable
            ;;
        --daemon-disable)
            daemon_disable
            ;;
        --daemon-start)
            daemon_start
            ;;
        --daemon-stop)
            daemon_stop
            ;;
        --daemon-status)
            daemon_status
            ;;
        --daemon-info)
            daemon_info
            ;;
        --task|-t)
            if ! onboarding_is_complete; then
                echo "Primero debes completar la configuración"
                echo "Ejecuta: $0 --onboard"
                exit 1
            fi
            shift
            mode_task "$*"
            ;;
        --status|-s)
            mode_status
            ;;
        --tools)
            mode_tools
            ;;
        --help|-h|"")
            print_help
            ;;
        *)
            echo "Opción desconocida: $1"
            echo ""
            print_help
            exit 1
            ;;
    esac
}

# Ejecutar
main "$@"
