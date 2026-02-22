#!/bin/bash
# lib/tools.sh - Sistema de registro y ejecución de herramientas

# Usar VOIDCLAW_BASE_DIR si está definido
if [[ -n "$VOIDCLAW_BASE_DIR" ]]; then
    SCRIPT_DIR="${VOIDCLAW_BASE_DIR}/lib"
    SKILLS_DIR="${VOIDCLAW_BASE_DIR}/skills"
    CONFIG_FILE="${VOIDCLAW_BASE_DIR}/config/settings.json"
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    SKILLS_DIR="${SCRIPT_DIR}/../skills"
    CONFIG_FILE="${SCRIPT_DIR}/../config/settings.json"
fi

# Array global de herramientas registradas
# Solo inicializar si no existe
if [[ ${#REGISTERED_TOOLS[@]} -eq 0 ]] 2>/dev/null; then
    REGISTERED_TOOLS=()
fi

# Registra una herramienta
# Args: $1 = nombre, $2 = descripción, $3 = parámetros (JSON schema)
tools_register() {
    local name="$1"
    local description="$2"
    local parameters="$3"
    
    local tool_json
    tool_json="{\"type\": \"function\", \"function\": {\"name\": \"$name\", \"description\": \"$description\", \"parameters\": $parameters}}"
    
    REGISTERED_TOOLS+=("$tool_json")
}

# Obtiene todas las herramientas como JSON array
tools_get_all_json() {
    local result="["
    local first=true
    
    for tool in "${REGISTERED_TOOLS[@]}"; do
        if [[ "$first" == true ]]; then
            first=false
        else
            result+=","
        fi
        result+="$tool"
    done
    
    result+="]"
    echo "$result"
}

# Carga todas las skills disponibles
tools_load_skills() {
    if [[ ! -d "$SKILLS_DIR" ]]; then
        return 1
    fi
    
    for skill_file in "$SKILLS_DIR"/*.sh; do
        if [[ -f "$skill_file" ]]; then
            source "$skill_file"
            
            # Llamar a función de registro si existe
            if declare -f "${skill_file##*/}_register" &>/dev/null; then
                "${skill_file##*/}_register"
            fi
        fi
    done
}

# Ejecuta una herramienta por nombre
# Args: $1 = nombre, $2 = argumentos (JSON)
tools_execute() {
    local name="$1"
    local args="$2"

    # Separar skill y acción (ej: task_manager.create)
    local skill_name="${name%%.*}"
    local action="${name#*.}"

    local skill_file="${SKILLS_DIR}/${skill_name}.sh"

    if [[ ! -f "$skill_file" ]]; then
        echo "ERROR: Skill '$skill_name' not found" >&2
        return 1
    fi

    source "$skill_file"

    # Ejecutar acción
    if declare -f "skill_execute" &>/dev/null; then
        skill_execute "$action" "$args"
    else
        echo "ERROR: skill_execute not defined in $skill_name" >&2
        return 1
    fi
}

# Parsea tool_call response de OpenAI
# Args: $1 = tool_calls JSON
tools_parse_and_execute() {
    local tool_calls="$1"

    if command -v jq &>/dev/null; then
        local count
        count=$(echo "$tool_calls" | jq 'length' 2>/dev/null)

        for ((i=0; i<count; i++)); do
            local func_name
            local func_args

            func_name=$(echo "$tool_calls" | jq -r ".[$i].function.name" 2>/dev/null)
            # Usar jq -r para obtener el string raw (remueve escapes)
            func_args=$(echo "$tool_calls" | jq -r ".[$i].function.arguments" 2>/dev/null)

            echo "Ejecutando: $func_name con args: $func_args" >&2
            tools_execute "$func_name" "$func_args"
        done
    else
        echo "ERROR: jq required for tool parsing" >&2
        return 1
    fi
}

# Lista herramientas disponibles
tools_list() {
    echo "Herramientas registradas:"
    for tool in "${REGISTERED_TOOLS[@]}"; do
        if command -v jq &>/dev/null; then
            local name desc
            name=$(echo "$tool" | jq -r '.function.name' 2>/dev/null)
            desc=$(echo "$tool" | jq -r '.function.description' 2>/dev/null)
            echo "  - $name: $desc"
        else
            echo "  - $tool"
        fi
    done
}
