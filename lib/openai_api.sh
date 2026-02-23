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

# Verifica si streaming está habilitado
openai_is_stream_enabled() {
    local stream_config
    if command -v jq &>/dev/null; then
        stream_config=$(jq -r '.openai.stream // false' "$CONFIG_FILE" 2>/dev/null)
    else
        stream_config=$(grep -o '"stream"[[:space:]]*:[[:space:]]*true' "$CONFIG_FILE" 2>/dev/null)
        [[ -n "$stream_config" ]] && stream_config="true" || stream_config="false"
    fi
    [[ "$stream_config" == "true" ]]
}

# Envía mensaje a la API con streaming (Server-Sent Events)
# Args: $1 = prompt, $2 = system_prompt, $3 = tools_json, $4 = archivo_temporal
# Imprime streaming a stderr, guarda respuesta en archivo
openai_chat_stream() {
    local prompt="$1"
    local system_prompt="${2:-You are a helpful assistant.}"
    local tools_json="$3"
    local temp_file="$4"

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

    # Construir payload con stream: true
    local payload
    payload="{\"model\": \"$model\", \"messages\": $messages, \"stream\": true"

    if [[ -n "$tools_json" ]]; then
        payload+=", \"tools\": $tools_json"
        payload+=", \"stream_options\": {\"include_usage\": true}"
    fi

    payload+="}"

    # Variable para acumular respuesta completa
    local full_response=""
    local tool_calls_accumulator=""

    # Usar Python para procesar el stream SSE correctamente
    # Esto evita el problema de bash con newlines en el contenido JSON
    if command -v python3 &>/dev/null; then
        local result_file
        result_file=$(mktemp)

        export RESULT_FD=3

        # Streaming con manejo de errores
        curl -s --no-buffer -X POST "${base_url}/chat/completions" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${api_key}" \
            -H "Accept: text/event-stream" \
            -d "$payload" 2>/dev/null | python3 -c '
import sys
import json
import os

result_fd = int(os.environ["RESULT_FD"])

buffer = ""
full_content = ""
tool_calls = []

for chunk in sys.stdin.buffer:
    buffer += chunk.decode("utf-8")
    while "\n\n" in buffer:
        event, buffer = buffer.split("\n\n", 1)
        if event.startswith("data: "):
            data = event[6:]
            if data == "[DONE]":
                if tool_calls:
                    os.write(result_fd, ("TOOL_CALLS:" + ",".join(tool_calls)).encode())
                else:
                    os.write(result_fd, full_content.encode())
                sys.exit(0)
            try:
                obj = json.loads(data)
                delta = obj.get("choices", [{}])[0].get("delta", {})
                content = delta.get("content", "")
                if content:
                    sys.stderr.write(content)
                    sys.stderr.flush()
                    full_content += content
                tc = delta.get("tool_calls", [])
                if tc:
                    tool_calls.extend([json.dumps(t) for t in tc])
            except json.JSONDecodeError:
                pass
' 2>&1 3>"$result_file"

        full_response=$(cat "$result_file")
        rm -f "$result_file"

        if [[ "$full_response" == TOOL_CALLS:* ]]; then
            tool_calls_accumulator="${full_response#TOOL_CALLS:}"
            full_response=""
        fi
    else
        # Fallback: método original con bash (puede tener problemas con newlines)
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            if [[ "$line" == data:* ]]; then
                local data="${line#data: }"
                if [[ "$data" == "[DONE]" ]]; then
                    break
                fi
                if command -v jq &>/dev/null; then
                    local delta_content
                    delta_content=$(echo "$data" | jq -r '.choices[0].delta.content // empty' 2>/dev/null)
                    local delta_tool_calls
                    delta_tool_calls=$(echo "$data" | jq -c '.choices[0].delta.tool_calls // empty' 2>/dev/null)
                    if [[ -n "$delta_content" && "$delta_content" != "null" ]]; then
                        full_response+="$delta_content"
                        printf "%s" "$delta_content" >&2
                    fi
                    if [[ -n "$delta_tool_calls" && "$delta_tool_calls" != "null" && "$delta_tool_calls" != "[]" ]]; then
                        tool_calls_accumulator+="$delta_tool_calls"
                    fi
                fi
            fi
        done < <(curl -s --no-buffer -X POST "${base_url}/chat/completions" \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${api_key}" \
            -H "Accept: text/event-stream" \
            -d "$payload" 2>/dev/null)
    fi

    # Imprimir newline final a stderr
    echo "" >&2

    # Guardar respuesta en archivo temporal
    if [[ -n "$tool_calls_accumulator" ]]; then
        echo "TOOL_CALLS:$tool_calls_accumulator" > "$temp_file"
    else
        printf "%s" "$full_response" > "$temp_file"
    fi

    return 0
}
# Wrapper que decide si usar streaming o no
# Args: $1 = prompt, $2 = system_prompt, $3 = tools_json
# Retorna: respuesta (usa archivo temporal para streaming)
openai_chat_with_tools() {
    local prompt="$1"
    local system_prompt="${2:-You are a helpful assistant that can use tools.}"
    local tools_json="$3"

    if openai_is_stream_enabled; then
        local temp_file
        temp_file=$(mktemp)
        openai_chat_stream "$prompt" "$system_prompt" "$tools_json" "$temp_file"
        cat "$temp_file"
        rm -f "$temp_file"
    else
        openai_chat "$prompt" "$system_prompt" "$tools_json"
    fi
}
