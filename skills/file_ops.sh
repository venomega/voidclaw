#!/bin/bash
# skills/file_ops.sh - Skill de operaciones con archivos

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SKILL_NAME="file_ops"
SKILL_DESCRIPTION="Operaciones con archivos - copiar, mover, leer, escribir, eliminar"

# Registra herramientas para OpenAI
file_ops_register() {
    source "${SCRIPT_DIR}/../lib/tools.sh"
    
    # Copiar archivo
    tools_register "file_ops.copy" \
        "Copia un archivo o directorio de una ubicación a otra" \
        '{"type": "object", "properties": {"src": {"type": "string", "description": "Ruta de origen"}, "dst": {"type": "string", "description": "Ruta de destino"}, "recursive": {"type": "boolean", "description": "Copiar recursivamente para directorios"}}, "required": ["src", "dst"]}'
    
    # Mover archivo
    tools_register "file_ops.move" \
        "Mueve o renombra un archivo o directorio" \
        '{"type": "object", "properties": {"src": {"type": "string", "description": "Ruta de origen"}, "dst": {"type": "string", "description": "Ruta de destino"}}, "required": ["src", "dst"]}'
    
    # Eliminar archivo
    tools_register "file_ops.delete" \
        "Elimina un archivo o directorio" \
        '{"type": "object", "properties": {"path": {"type": "string", "description": "Ruta del archivo/directorio"}, "recursive": {"type": "boolean", "description": "Eliminar recursivamente para directorios"}}, "required": ["path"]}'
    
    # Leer archivo
    tools_register "file_ops.read" \
        "Lee el contenido de un archivo de texto" \
        '{"type": "object", "properties": {"path": {"type": "string", "description": "Ruta del archivo a leer"}}, "required": ["path"]}'
    
    # Escribir archivo
    tools_register "file_ops.write" \
        "Escribe contenido a un archivo" \
        '{"type": "object", "properties": {"path": {"type": "string", "description": "Ruta del archivo"}, "content": {"type": "string", "description": "Contenido a escribir"}, "append": {"type": "boolean", "description": "Agregar al final en lugar de sobrescribir"}}, "required": ["path", "content"]}'
    
    # Listar directorio
    tools_register "file_ops.list" \
        "Lista el contenido de un directorio" \
        '{"type": "object", "properties": {"path": {"type": "string", "description": "Ruta del directorio"}}, "required": ["path"]}'
}

# Copia archivo
file_ops_copy() {
    local src="$1"
    local dst="$2"
    local recursive="${3:-false}"
    
    if [[ ! -e "$src" ]]; then
        echo "ERROR: Origen no existe: $src"
        return 1
    fi
    
    local opts=""
    if [[ "$recursive" == "true" ]] || [[ -d "$src" ]]; then
        opts="-r"
    fi
    
    cp $opts "$src" "$dst" 2>&1
    local result=$?
    
    if [[ $result -eq 0 ]]; then
        echo "Archivo copiado: $src -> $dst"
        log_info "file_ops.copy: $src -> $dst"
    else
        echo "ERROR al copiar: $src -> $dst"
        log_error "file_ops.copy failed: $src -> $dst"
    fi
    
    return $result
}

# Mueve archivo
file_ops_move() {
    local src="$1"
    local dst="$2"
    
    if [[ ! -e "$src" ]]; then
        echo "ERROR: Origen no existe: $src"
        return 1
    fi
    
    mv "$src" "$dst" 2>&1
    local result=$?
    
    if [[ $result -eq 0 ]]; then
        echo "Archivo movido: $src -> $dst"
        log_info "file_ops.move: $src -> $dst"
    else
        echo "ERROR al mover: $src -> $dst"
        log_error "file_ops.move failed: $src -> $dst"
    fi
    
    return $result
}

# Elimina archivo
file_ops_delete() {
    local path="$1"
    local recursive="${2:-false}"
    
    if [[ ! -e "$path" ]]; then
        echo "ERROR: Ruta no existe: $path"
        return 1
    fi
    
    local opts=""
    if [[ "$recursive" == "true" ]] || [[ -d "$path" ]]; then
        opts="-r"
    fi
    
    rm $opts "$path" 2>&1
    local result=$?
    
    if [[ $result -eq 0 ]]; then
        echo "Archivo eliminado: $path"
        log_info "file_ops.delete: $path"
    else
        echo "ERROR al eliminar: $path"
        log_error "file_ops.delete failed: $path"
    fi
    
    return $result
}

# Lee archivo
file_ops_read() {
    local path="$1"
    
    if [[ ! -f "$path" ]]; then
        echo "ERROR: Archivo no existe o no es regular: $path"
        return 1
    fi
    
    cat "$path" 2>&1
}

# Escribe archivo
file_ops_write() {
    local path="$1"
    local content="$2"
    local append="${3:-false}"

    # Expandir tilde (~) a home directory - manejar varios formatos
    path="${path//\\~/$HOME}"  # ~ escapado
    path="${path/#\~/$HOME}"   # ~ al inicio
    path="${path/#\"~/$HOME}"  # "~ al inicio (con comilla)
    
    # Remover comillas si existen
    path="${path//\"/}"

    # Crear directorio padre si no existe
    local dir
    dir=$(dirname "$path")
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
    fi

    if [[ "$append" == "true" ]]; then
        echo "$content" >> "$path"
    else
        echo "$content" > "$path"
    fi

    local result=$?

    if [[ $result -eq 0 ]]; then
        echo "Archivo escrito: $path"
        log_info "file_ops.write: $path"
    else
        echo "ERROR al escribir: $path"
        log_error "file_ops.write failed: $path"
    fi
    
    return $result
}

# Lista directorio
file_ops_list() {
    local path="$1"
    
    if [[ ! -d "$path" ]]; then
        echo "ERROR: Directorio no existe: $path"
        return 1
    fi
    
    echo "Contenido de: $path"
    echo "---"
    ls -la "$path" 2>&1
}

# Ejecuta acción de skill
skill_execute() {
    local action="$1"
    local params="$2"
    
    local src dst path content recursive append
    
    if command -v jq &>/dev/null; then
        src=$(echo "$params" | jq -r '.src // empty' 2>/dev/null)
        dst=$(echo "$params" | jq -r '.dst // empty' 2>/dev/null)
        path=$(echo "$params" | jq -r '.path // empty' 2>/dev/null)
        content=$(echo "$params" | jq -r '.content // empty' 2>/dev/null)
        recursive=$(echo "$params" | jq -r '.recursive // false' 2>/dev/null)
        append=$(echo "$params" | jq -r '.append // false' 2>/dev/null)
    fi
    
    case "$action" in
        "copy")
            file_ops_copy "$src" "$dst" "$recursive"
            ;;
        "move")
            file_ops_move "$src" "$dst"
            ;;
        "delete")
            file_ops_delete "$path" "$recursive"
            ;;
        "read")
            file_ops_read "$path"
            ;;
        "write")
            file_ops_write "$path" "$content" "$append"
            ;;
        "list")
            file_ops_list "$path"
            ;;
        *)
            echo "Acción desconocida: $action"
            return 1
            ;;
    esac
}
