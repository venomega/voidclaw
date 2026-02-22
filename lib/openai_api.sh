#!/bin/bash
# lib/openai_api.sh - Módulo de conexión con API de OpenAI

# Usar VOIDCLAW_BASE_DIR si está definido, sino calcular desde SCRIPT_DIR
if [[ -n "$VOIDCLAW_BASE_DIR" ]]; then
    CONFIG_FILE="${VOIDCLAW_BASE_DIR}/config/settings.json"
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    CONFIG_FILE="${SCRIPT_DIR}/../config/settings.json"
fi

# Escapa caracteres especiales para JSON
json_escape() {
    local str="$1"
    str="${str//\\/\\\\}"    # Backslash
    str="${str//\"/\\\"}"    # Comillas dobles
    str="${str//$'\n'/\\n}"  # Newline
    str="${str//$'\r'/\\r}"  # Carriage return
    str="${str//$'\t'/\\t}"  # Tab
    echo "$str"
}

# Carga configuración desde settings.json
openai_get_config() {
    local key="$1"
    if command -v jq &>/dev/null; then
        jq -r ".openai.$key // empty" "$CONFIG_FILE" 2>/dev/null
    else
        # Fallback básico sin jq
        grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$CONFIG_FILE" | sed 's/.*: *"\([^"]*\)"/\1/'
    fi
}

# Obtiene API Key
openai_get_api_key() {
    openai_get_config "api_key"
}

# Obtiene modelo configurado
openai_get_model() {
    openai_get_config "model"
}

# Obtiene base URL
openai_get_base_url() {
    openai_get_config "base_url"
}

# Verifica si la API key está configurada
openai_is_configured() {
    local api_key
    api_key=$(openai_get_api_key)
    [[ -n "$api_key" && "$api_key" != "null" && "$api_key" != "" ]]
}

# Envía mensaje a la API de OpenAI
# Args: $1 = prompt, $2 = system_prompt (opcional), $3 = tools_json (opcional)
openai_chat() {
    local prompt="$1"
    local system_prompt="${2:-You are a helpful bash assistant.}"
    local tools_json="$3"
    
    local api_key
    local model
    local base_url
    
    api_key=$(openai_get_api_key)
    model=$(openai_get_model)
    base_url=$(openai_get_base_url)
    
    if ! openai_is_configured; then
        echo "ERROR: OpenAI API key not configured. Run --onboard first." >&2
        return 1
    fi
    
    # Construir mensajes
    local escaped_system_prompt
    local escaped_prompt
    escaped_system_prompt=$(json_escape "$system_prompt")
    escaped_prompt=$(json_escape "$prompt")
    
    local messages
    messages="[{\"role\": \"system\", \"content\": \"$escaped_system_prompt\"}"
    messages+=", {\"role\": \"user\", \"content\": \"$escaped_prompt\"}]"
    
    # Construir payload
    local payload
    payload="{\"model\": \"$model\", \"messages\": $messages"
    
    if [[ -n "$tools_json" ]]; then
        payload+=", \"tools\": $tools_json"
        payload+=", \"tool_choice\": \"auto\""
    fi
    
    payload+="}"
    
    # Hacer request
    local response
    response=$(curl -s -X POST "${base_url}/chat/completions" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${api_key}" \
        -d "$payload")
    
    # Extraer respuesta
    if command -v jq &>/dev/null; then
        # Primero verificar tool_calls (tienen prioridad sobre el contenido)
        local tool_calls
        tool_calls=$(echo "$response" | jq -c '.choices[0].message.tool_calls // empty' 2>/dev/null)
        
        if [[ -n "$tool_calls" && "$tool_calls" != "null" && "$tool_calls" != "[]" ]]; then
            echo "TOOL_CALLS:$tool_calls"
            return 0
        fi
        
        # Si no hay tool_calls, verificar contenido
        local content
        content=$(echo "$response" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
        if [[ -n "$content" ]]; then
            echo "$content"
            return 0
        fi

        # Verificar si hay error en la respuesta
        local has_error
        has_error=$(echo "$response" | jq 'has("error")' 2>/dev/null)
        if [[ "$has_error" == "true" ]]; then
            local error_msg
            error_msg=$(echo "$response" | jq -r '.error.message // "Unknown error"' 2>/dev/null)
            echo "ERROR: $error_msg" >&2
            return 1
        fi

        # Respuesta válida pero sin contenido
        return 0
    else
        # Fallback sin jq - respuesta básica
        echo "$response" | grep -o '"content"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/"content"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/'
    fi
}

# Envía mensaje y extrae tool_calls si existen
openai_chat_with_tools() {
    local prompt="$1"
    local system_prompt="${2:-You are a helpful assistant that can use tools to complete tasks.}"
    local tools_json="$3"
    
    openai_chat "$prompt" "$system_prompt" "$tools_json"
}

# Log de interacciones
openai_log() {
    local message="$1"
    local log_file="${SCRIPT_DIR}/../logs/openai.log"
    echo "[$(date -Iseconds)] $message" >> "$log_file"
}
