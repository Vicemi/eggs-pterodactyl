#!/bin/bash
# ===========================================================
# AI API v1 - Script de inicio para Pterodactyl
# Yolk      : ghcr.io/vicemi/yolks:ai-api_latest
# Python    : 3.11 | llama-cpp-python (CPU) | FastAPI
# Repositorio: https://github.com/Vicemi/planka-egg
# ===========================================================

set -euo pipefail

cd /home/container || { echo "ERROR: No se pudo acceder a /home/container"; exit 1; }

echo "=========================================="
echo "   AI API v1 — Iniciando"
echo "   Yolk: ghcr.io/vicemi/yolks:ai-api_latest"
echo "=========================================="

# ── Colores ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "${GREEN}  ✓ $*${NC}"; }
warn() { echo -e "${YELLOW}  ⚠ $*${NC}"; }
info() { echo -e "${CYAN}  → $*${NC}"; }
die()  { echo -e "${RED}  ✗ FATAL: $*${NC}"; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
# PASO 0: Variables obligatorias y por defecto
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "[0/4] Verificando configuración..."

MODEL_NAME="${MODEL_NAME:-qwen2.5-uncensored}"
API_TOKEN="${API_TOKEN:-changeme}"
API_PORT="${SERVER_PORT:-5832}"
MAX_TOKENS="${MAX_TOKENS:-512}"
N_THREADS="${N_THREADS:-2}"
N_CTX="${N_CTX:-4096}"
HF_TOKEN="${HF_TOKEN:-}"
MODEL_CACHE="/home/container/model_cache"

[ -n "$API_TOKEN" ] || die "API_TOKEN no puede estar vacío"
[ "$API_TOKEN" != "changeme" ] || warn "API_TOKEN es el valor por defecto — cámbialo en el panel"

ok "Modelo   : $MODEL_NAME"
ok "Puerto   : $API_PORT"
ok "Threads  : $N_THREADS"
ok "MaxTok   : $MAX_TOKENS"
ok "Ctx Len  : $N_CTX"

# ─────────────────────────────────────────────────────────────────────────────
# PASO 1: Registro de modelos
# Debe estar sincronizado con MODEL_REGISTRY en /app/app.py
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "[1/4] Verificando modelo seleccionado..."

declare -A MTYPE MREPO MFILE MLABEL

# Modelo 1: Qwen2.5 0.5B Uncensored (usuario especificó)
MTYPE["qwen2.5-uncensored"]="transformers"
MREPO["qwen2.5-uncensored"]="thirdeyeai/Qwen2.5-0.5B-Instruct-uncensored"
MFILE["qwen2.5-uncensored"]=""
MLABEL["qwen2.5-uncensored"]="Qwen2.5 0.5B Uncensored"

# Modelo 2: Qwen3.5 0.8B GGUF (usuario especificó)
MTYPE["qwen3.5-0.8b"]="gguf"
MREPO["qwen3.5-0.8b"]="unsloth/Qwen3.5-0.8B-GGUF"
MFILE["qwen3.5-0.8b"]="Qwen3.5-0.8B-Q4_K_M.gguf"
MLABEL["qwen3.5-0.8b"]="Qwen3.5 0.8B (GGUF Q4_K_M)"

# Modelo 3: Llama 3.2 1B (adicional)
MTYPE["llama3.2-1b"]="gguf"
MREPO["llama3.2-1b"]="bartowski/Llama-3.2-1B-Instruct-GGUF"
MFILE["llama3.2-1b"]="Llama-3.2-1B-Instruct-Q4_K_M.gguf"
MLABEL["llama3.2-1b"]="Llama 3.2 1B Instruct (GGUF Q4_K_M)"

# Modelo 4: SmolLM2 1.7B (adicional)
MTYPE["smollm2-1.7b"]="gguf"
MREPO["smollm2-1.7b"]="bartowski/SmolLM2-1.7B-Instruct-GGUF"
MFILE["smollm2-1.7b"]="SmolLM2-1.7B-Instruct-Q4_K_M.gguf"
MLABEL["smollm2-1.7b"]="SmolLM2 1.7B Instruct (GGUF Q4_K_M)"

# Modelo 5: Qwen2.5 1.5B (adicional)
MTYPE["qwen2.5-1.5b"]="gguf"
MREPO["qwen2.5-1.5b"]="bartowski/Qwen2.5-1.5B-Instruct-GGUF"
MFILE["qwen2.5-1.5b"]="Qwen2.5-1.5B-Instruct-Q4_K_M.gguf"
MLABEL["qwen2.5-1.5b"]="Qwen2.5 1.5B Instruct (GGUF Q4_K_M)"

# Validar nombre de modelo
if [ -z "${MTYPE[$MODEL_NAME]+_}" ]; then
    die "Modelo desconocido: '$MODEL_NAME'
  Modelos válidos:
    • qwen2.5-uncensored  — Qwen2.5 0.5B Uncensored (0.5B, transformers)
    • qwen3.5-0.8b        — Qwen3.5 0.8B GGUF (0.8B, CPU rápido)
    • llama3.2-1b         — Llama 3.2 1B Instruct GGUF (1B)
    • smollm2-1.7b        — SmolLM2 1.7B Instruct GGUF (1.7B, muy eficiente)
    • qwen2.5-1.5b        — Qwen2.5 1.5B Instruct GGUF (1.5B)"
fi

M_TYPE="${MTYPE[$MODEL_NAME]}"
M_REPO="${MREPO[$MODEL_NAME]}"
M_FILE="${MFILE[$MODEL_NAME]}"
M_LABEL="${MLABEL[$MODEL_NAME]}"

ok "Seleccionado: $M_LABEL ($M_TYPE)"

# ─────────────────────────────────────────────────────────────────────────────
# PASO 2: Crear context.txt si no existe
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "[2/4] Configurando personalidad de la IA..."

CONTEXT_FILE="/home/container/context.txt"

if [ ! -f "$CONTEXT_FILE" ] || [ ! -s "$CONTEXT_FILE" ]; then
    warn "context.txt no encontrado — creando por defecto"
    cat > "$CONTEXT_FILE" << 'CTXEOF'
Eres un asistente de IA útil, honesto y amigable.
Responde siempre en el idioma en que te habla el usuario.
Sé conciso, claro y preciso en tus respuestas.
No revelar que eres un modelo de lenguaje a menos que se te pregunte directamente.
CTXEOF
    warn "Edita /home/container/context.txt en el gestor de archivos para personalizar la IA."
else
    ok "context.txt cargado: $(wc -c < "$CONTEXT_FILE") bytes"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PASO 3: Descargar modelo si no está en caché
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "[3/4] Verificando modelo en caché..."

mkdir -p "$MODEL_CACHE"

# Login en HuggingFace si hay token
if [ -n "$HF_TOKEN" ]; then
    info "Autenticando en HuggingFace..."
    huggingface-cli login --token "$HF_TOKEN" --add-to-git-credential >/dev/null 2>&1 || \
        warn "No se pudo autenticar en HuggingFace (continuando sin token)"
    HF_EXTRA="--token $HF_TOKEN"
else
    HF_EXTRA=""
fi

if [ "$M_TYPE" = "gguf" ]; then
    # ── GGUF: descargar solo el archivo .gguf ──────────────────────────────
    GGUF_PATH="$MODEL_CACHE/$M_FILE"
    if [ -f "$GGUF_PATH" ] && [ -s "$GGUF_PATH" ]; then
        ok "GGUF en caché: $GGUF_PATH ($(du -sh "$GGUF_PATH" | cut -f1))"
    else
        info "Descargando: $M_REPO / $M_FILE"
        info "Esto puede tardar varios minutos dependiendo del tamaño del modelo..."
        huggingface-cli download "$M_REPO" "$M_FILE" \
            --local-dir "$MODEL_CACHE" \
            --local-dir-use-symlinks False \
            $HF_EXTRA \
            || die "Fallo al descargar el modelo GGUF '$M_REPO/$M_FILE'"
        [ -f "$GGUF_PATH" ] || die "El archivo GGUF no se encontró tras la descarga: $GGUF_PATH"
        ok "GGUF descargado: $(du -sh "$GGUF_PATH" | cut -f1)"
    fi

elif [ "$M_TYPE" = "transformers" ]; then
    # ── Transformers: descargar todos los pesos del repo ──────────────────
    TF_DIR="$MODEL_CACHE/$MODEL_NAME"
    if [ -d "$TF_DIR" ] && [ -n "$(ls -A "$TF_DIR" 2>/dev/null)" ]; then
        ok "Modelo en caché: $TF_DIR ($(du -sh "$TF_DIR" | cut -f1))"
    else
        info "Descargando modelo completo: $M_REPO"
        info "Esto puede tardar varios minutos..."
        huggingface-cli download "$M_REPO" \
            --local-dir "$TF_DIR" \
            --local-dir-use-symlinks False \
            $HF_EXTRA \
            || die "Fallo al descargar el modelo transformers '$M_REPO'"
        ok "Modelo descargado: $(du -sh "$TF_DIR" | cut -f1)"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# PASO 4: Exportar variables e iniciar API
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "[4/4] Iniciando servidor API..."
echo ""
echo "  Modelo  : $M_LABEL"
echo "  Puerto  : $API_PORT"
echo "  Threads : $N_THREADS"
echo ""
echo "=========================================="

export MODEL_NAME MODEL_CACHE API_TOKEN API_PORT MAX_TOKENS N_THREADS N_CTX CONTEXT_FILE

# Limpieza al parar el servidor
cleanup() {
    echo ""
    echo "Señal recibida — deteniendo AI API..."
    exit 0
}
trap cleanup SIGTERM SIGINT

exec python /app/app.py
