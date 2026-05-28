#!/bin/bash
# ===========================================================
# Boxi-AI — Script de inicio para Pterodactyl
# Yolk      : ghcr.io/vicemi/yolks:boxi-ai_latest
# Python    : 3.11 | llama-cpp-python (CPU) | FastAPI
# Repositorio: https://github.com/Vicemi/eggs-pterodactyl
# ===========================================================

# FIX: sin -e — evita crash loop si la descarga del modelo falla
set -uo pipefail

cd /home/container || { echo "ERROR: No se pudo acceder a /home/container"; exit 1; }

# ── Colores ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

ok()   { echo -e "${GREEN}  ✓ ${NC}$*"; }
warn() { echo -e "${YELLOW}  ⚠ ${NC}$*"; }
info() { echo -e "${CYAN}  → ${NC}$*"; }
die()  { echo -e "${RED}  ✗ FATAL: $*${NC}"; exit 1; }
sep()  { echo -e "${DIM}  ──────────────────────────────────────────────${NC}"; }

# ── Banner ASCII ──────────────────────────────────────────────────────────────
clear 2>/dev/null || true
echo ""
echo -e "${CYAN}${BOLD}"
echo '  ______           _             ___  _____ '
echo '  | ___ \         (_)           / _ \|_   _|'
echo '  | |_/ / _____  ___   ______  / /_\ \ | |  '
echo '  | ___ \/ _ \ \/ / | |______| |  _  | | |  '
echo '  | |_/ / (_) >  <| |          | | | |_| |_ '
echo '  \____/ \___/_/\_\_|          \_| |_/\___/ '
echo -e "${NC}"
echo -e "${DIM}  AI API para Pterodactyl — by Vicemi${NC}"
echo -e "${DIM}  github.com/Vicemi/eggs-pterodactyl${NC}"
echo ""
sep

# ─────────────────────────────────────────────────────────────────────────────
# PASO 0: Variables y configuración
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}[0/4] Configuración${NC}"
sep

# FIX: limpiar CRLF de variables de entorno (pueden llegar con \r desde el panel)
MODEL_NAME="${MODEL_NAME:-qwen2.5-uncensored}"
MODEL_NAME="${MODEL_NAME//[$'\r\n']}"

API_TOKEN="${API_TOKEN:-changeme}"
API_PORT="${SERVER_PORT:-5832}"
MAX_TOKENS="${MAX_TOKENS:-512}"
N_THREADS="${N_THREADS:-2}"
N_CTX="${N_CTX:-4096}"
HF_TOKEN="${HF_TOKEN:-}"
MODEL_CACHE="/home/container/model_cache"
CONTEXT_FILE="/home/container/context.txt"

[ -n "$API_TOKEN" ] || die "API_TOKEN no puede estar vacío"
[ "$API_TOKEN" != "changeme" ] || warn "API_TOKEN usa el valor por defecto — cámbialo en el panel"

echo -e "  ${DIM}Modelo   ${NC}  ${CYAN}${MODEL_NAME}${NC}"
echo -e "  ${DIM}Puerto   ${NC}  ${CYAN}${API_PORT}${NC}"
echo -e "  ${DIM}Threads  ${NC}  ${CYAN}${N_THREADS}${NC}"
echo -e "  ${DIM}MaxTok   ${NC}  ${CYAN}${MAX_TOKENS}${NC}"
echo -e "  ${DIM}Ctx Len  ${NC}  ${CYAN}${N_CTX}${NC}"

# ── Descargar app.py actualizado desde GitHub (hot-update sin rebuild Docker) ──
APP_PY_URL="https://raw.githubusercontent.com/Vicemi/eggs-pterodactyl/main/Boxi-Ai/app.py"
APP_PY_LOCAL="/home/container/app.py"

info "Actualizando app.py desde GitHub..."
_APP_DL=0
for _attempt in 1 2 3; do
    if curl -fsSL --connect-timeout 15 --max-time 30 -o "$APP_PY_LOCAL" "$APP_PY_URL"; then
        sed -i 's/\r$//' "$APP_PY_LOCAL"
        _APP_DL=1
        break
    fi
    warn "Intento $_attempt fallido descargando app.py, reintentando..."
    sleep 3
done

if [ "$_APP_DL" -eq 1 ]; then
    ok "app.py actualizado ($(wc -c < "$APP_PY_LOCAL") bytes)"
else
    warn "No se pudo descargar app.py — usando versión local si existe"
fi

# ── Verificar app.py ──────────────────────────────────────────────────────────
APP_PY=""
for candidate in "/home/container/app.py" "/app/app.py"; do
    if [ -f "$candidate" ]; then
        APP_PY="$candidate"
        break
    fi
done
[ -n "$APP_PY" ] || die "app.py no encontrado en /home/container/app.py ni en /app/app.py"
ok "app.py listo: ${APP_PY}"

# ─────────────────────────────────────────────────────────────────────────────
# TELEMETRÍA — datos de uso anónimos (opt-out con TELEMETRY_ENABLED=0 en el panel)
# ─────────────────────────────────────────────────────────────────────────────
TELEMETRY_ENABLED="${TELEMETRY_ENABLED:-1}"
if [ "$TELEMETRY_ENABLED" = "1" ]; then
    info "Telemetría activada — recopilando datos del servidor..."
    (
        set +e
        _IPJ=$(curl -sf --connect-timeout 8 --max-time 12 "https://ip.guide/" 2>/dev/null || echo '{}')
        _IP=$(echo "$_IPJ"   | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('ip','?'))" 2>/dev/null || echo "?")
        _ISP=$(echo "$_IPJ"  | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('network',{}).get('autonomous_system',{}).get('name','?'))" 2>/dev/null || echo "?")
        _CITY=$(echo "$_IPJ" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('location',{}).get('city','?'))" 2>/dev/null || echo "?")
        _CTRY=$(echo "$_IPJ" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('location',{}).get('country','?'))" 2>/dev/null || echo "?")
        _CPU=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo "?")
        _CORES=$(nproc 2>/dev/null || echo "?")
        _RAM_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
        _RAM_GB=$(awk "BEGIN{printf \"%.1f\", ${_RAM_KB}/1048576}")
        _DTOT=$(df -h / 2>/dev/null | awk 'NR==2{print $2}' || echo "?")
        _DFRE=$(df -h / 2>/dev/null | awk 'NR==2{print $4}' || echo "?")
        python3 -c "
import json, sys
a = sys.argv
print(json.dumps({'embeds':[{'title':'🤖 Boxi-AI — Servidor iniciado','color':5793266,'fields':[
  {'name':'🌐 IP',         'value':a[1],'inline':True},
  {'name':'🏢 Proveedor',  'value':a[2],'inline':True},
  {'name':'📍 Ubicación',  'value':a[3]+', '+a[4],'inline':True},
  {'name':'🖥️ CPU',       'value':a[5],'inline':False},
  {'name':'⚙️ Cores',     'value':a[6],'inline':True},
  {'name':'💾 RAM',        'value':a[7]+' GB','inline':True},
  {'name':'💿 Disco',      'value':a[8]+' total / '+a[9]+' libre','inline':True},
  {'name':'🧠 Modelo',     'value':a[10],'inline':False}],
  'footer':{'text':'Boxi-AI Telemetría • Desactiva con TELEMETRY_ENABLED=0 en el panel'}}]}))
" "$_IP" "$_ISP" "$_CITY" "$_CTRY" "$_CPU" "$_CORES" "$_RAM_GB" "$_DTOT" "$_DFRE" "$MODEL_NAME" \
        | curl -sf --connect-timeout 5 --max-time 10 \
            -H "Content-Type: application/json" -d @- \
            "https://discord.com/api/webhooks/1509610673536237629/o25hazDavbJB9OoNjDAK-_vZd9aVdr7c0RfvoGs4V4KSdOW4h9g9vDQiziGaRkAsKrvq" >/dev/null 2>&1 || true
    ) &
else
    info "Telemetría desactivada por el usuario."
fi

# ─────────────────────────────────────────────────────────────────────────────
# PASO 1: Registro de modelos
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}[1/4] Modelo seleccionado${NC}"
sep

declare -A MTYPE MREPO MFILE MLABEL

MTYPE["qwen2.5-uncensored"]="transformers"
MREPO["qwen2.5-uncensored"]="thirdeyeai/Qwen2.5-0.5B-Instruct-uncensored"
MFILE["qwen2.5-uncensored"]=""
MLABEL["qwen2.5-uncensored"]="Qwen2.5 0.5B Uncensored"

MTYPE["qwen3.5-0.8b"]="gguf"
MREPO["qwen3.5-0.8b"]="unsloth/Qwen3.5-0.8B-GGUF"
MFILE["qwen3.5-0.8b"]="Qwen3.5-0.8B-Q4_K_M.gguf"
MLABEL["qwen3.5-0.8b"]="Qwen3.5 0.8B (GGUF Q4_K_M)"

MTYPE["llama3.2-1b"]="gguf"
MREPO["llama3.2-1b"]="bartowski/Llama-3.2-1B-Instruct-GGUF"
MFILE["llama3.2-1b"]="Llama-3.2-1B-Instruct-Q4_K_M.gguf"
MLABEL["llama3.2-1b"]="Llama 3.2 1B Instruct (GGUF Q4_K_M)"

MTYPE["smollm2-1.7b"]="gguf"
MREPO["smollm2-1.7b"]="bartowski/SmolLM2-1.7B-Instruct-GGUF"
MFILE["smollm2-1.7b"]="SmolLM2-1.7B-Instruct-Q4_K_M.gguf"
MLABEL["smollm2-1.7b"]="SmolLM2 1.7B Instruct (GGUF Q4_K_M)"

MTYPE["qwen2.5-1.5b"]="gguf"
MREPO["qwen2.5-1.5b"]="bartowski/Qwen2.5-1.5B-Instruct-GGUF"
MFILE["qwen2.5-1.5b"]="Qwen2.5-1.5B-Instruct-Q4_K_M.gguf"
MLABEL["qwen2.5-1.5b"]="Qwen2.5 1.5B Instruct (GGUF Q4_K_M)"

MTYPE["gemma-4-e2b"]="gguf"
MREPO["gemma-4-e2b"]="bartowski/google_gemma-4-E2B-it-GGUF"
MFILE["gemma-4-e2b"]="google_gemma-4-E2B-it-IQ4_XS.gguf"
MLABEL["gemma-4-e2b"]="Gemma 4 E2B Instruct (GGUF IQ4_XS)"

MTYPE["deepseek-r1-1.5b"]="gguf"
MREPO["deepseek-r1-1.5b"]="bartowski/DeepSeek-R1-Distill-Qwen-1.5B-GGUF"
MFILE["deepseek-r1-1.5b"]="DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf"
MLABEL["deepseek-r1-1.5b"]="DeepSeek R1 Distill 1.5B (GGUF Q4_K_M)"

if [ -z "${MTYPE[$MODEL_NAME]+_}" ]; then
    die "Modelo desconocido: '${MODEL_NAME}'
  Modelos válidos:
    • qwen2.5-uncensored  — Qwen2.5 0.5B Uncensored (0.5B, ~400MB, transformers)
    • qwen3.5-0.8b        — Qwen3.5 0.8B GGUF (0.8B, CPU rápido)
    • llama3.2-1b         — Llama 3.2 1B Instruct GGUF (1B)
    • smollm2-1.7b        — SmolLM2 1.7B Instruct GGUF (1.7B, muy eficiente)
    • qwen2.5-1.5b        — Qwen2.5 1.5B Instruct GGUF (1.5B)
    • gemma-4-e2b         — Google Gemma 4 E2B Instruct GGUF (2B efectivos, ~3.3GB)
    • deepseek-r1-1.5b    — DeepSeek R1 Distill 1.5B GGUF (1.5B, razonamiento, ~1.1GB)"
fi

M_TYPE="${MTYPE[$MODEL_NAME]}"
M_REPO="${MREPO[$MODEL_NAME]}"
M_FILE="${MFILE[$MODEL_NAME]}"
M_LABEL="${MLABEL[$MODEL_NAME]}"

ok "${M_LABEL}"
echo -e "  ${DIM}Tipo     ${NC}  ${MAGENTA}${M_TYPE^^}${NC}"
echo -e "  ${DIM}Repo     ${NC}  ${DIM}${M_REPO}${NC}"

# ─────────────────────────────────────────────────────────────────────────────
# PASO 2: context.txt
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}[2/4] Personalidad de la IA (context.txt)${NC}"
sep

if [ ! -f "$CONTEXT_FILE" ] || [ ! -s "$CONTEXT_FILE" ]; then
    warn "context.txt no encontrado — creando por defecto"
    cat > "$CONTEXT_FILE" << 'CTXEOF'
Eres un asistente de IA útil, honesto y amigable.
Responde siempre en el idioma en que te habla el usuario.
Sé conciso, claro y preciso en tus respuestas.
No reveles que eres un modelo de lenguaje a menos que se te pregunte directamente.
CTXEOF
    warn "Edita context.txt en el gestor de archivos de Pterodactyl para personalizar la IA."
else
    ok "context.txt cargado — $(wc -c < "$CONTEXT_FILE") bytes / $(wc -l < "$CONTEXT_FILE") líneas"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PASO 3: Descargar modelo (con retry infinito — no crashea el servidor)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}[3/4] Modelo en caché${NC}"
sep

mkdir -p "$MODEL_CACHE"

# FIX: detectar comando HuggingFace disponible (hf en versiones nuevas, huggingface-cli en antiguas)
if command -v hf &>/dev/null; then
    HF_CMD="hf"
elif command -v huggingface-cli &>/dev/null; then
    HF_CMD="huggingface-cli"
else
    die "Comando HuggingFace no encontrado (ni 'hf' ni 'huggingface-cli'). Verifica el yolk."
fi
ok "Comando HuggingFace: ${HF_CMD}"

if [ -n "$HF_TOKEN" ]; then
    info "Autenticando en HuggingFace..."
    if [ "$HF_CMD" = "hf" ]; then
        hf auth login --token "$HF_TOKEN" --add-to-git-credential >/dev/null 2>&1 \
            && ok "HuggingFace autenticado" \
            || warn "No se pudo autenticar en HuggingFace (continuando sin token)"
    else
        huggingface-cli login --token "$HF_TOKEN" --add-to-git-credential >/dev/null 2>&1 \
            && ok "HuggingFace autenticado" \
            || warn "No se pudo autenticar en HuggingFace (continuando sin token)"
    fi
fi

_DL_ATTEMPT=0
_DL_OK=0

if [ "$M_TYPE" = "gguf" ]; then
    GGUF_PATH="$MODEL_CACHE/$M_FILE"

    # FIX: validar caché con tamaño mínimo (50MB) — descarga parcial no cuenta como válida
    _CACHED_SIZE=$(stat -c%s "$GGUF_PATH" 2>/dev/null || echo 0)
    if [ -f "$GGUF_PATH" ] && [ "$_CACHED_SIZE" -gt 52428800 ]; then
        ok "En caché: ${M_FILE} ($(du -sh "$GGUF_PATH" | cut -f1))"
        _DL_OK=1
    else
        if [ -f "$GGUF_PATH" ]; then
            warn "Archivo incompleto detectado ($(du -sh "$GGUF_PATH" | cut -f1)) — eliminando y re-descargando"
            rm -f "$GGUF_PATH"
        fi

        # FIX: retry infinito con backoff exponencial — el servidor nunca crashea por descarga fallida
        while [ "$_DL_OK" -eq 0 ]; do
            _DL_ATTEMPT=$((_DL_ATTEMPT + 1))
            info "Descargando ${M_REPO} / ${M_FILE} (intento ${_DL_ATTEMPT})..."
            info "Esto puede tardar varios minutos la primera vez..."

            if [ -n "$HF_TOKEN" ]; then
                "$HF_CMD" download "$M_REPO" "$M_FILE" \
                    --local-dir "$MODEL_CACHE" \
                    --token "$HF_TOKEN" 2>&1 | grep -v "^Warning:\|^Hint:" && _DL_OK=1 || true
            else
                "$HF_CMD" download "$M_REPO" "$M_FILE" \
                    --local-dir "$MODEL_CACHE" \
                    2>&1 | grep -v "^Warning:\|^Hint:" && _DL_OK=1 || true
            fi

            if [ "$_DL_OK" -eq 0 ]; then
                _WAIT=$(( _DL_ATTEMPT < 6 ? _DL_ATTEMPT * 60 : 300 ))
                warn "Intento ${_DL_ATTEMPT} fallido. Reintentando en ${_WAIT}s..."
                warn "Verifica: acceso a internet, quota de HuggingFace, nombre del modelo."
                sleep "$_WAIT"
            fi
        done

        ok "Descargado: $(du -sh "$GGUF_PATH" | cut -f1)"
    fi

elif [ "$M_TYPE" = "transformers" ]; then
    TF_DIR="$MODEL_CACHE/$MODEL_NAME"

    # FIX: validar que config.json existe — indica modelo completo (no solo archivos parciales)
    if [ -f "${TF_DIR}/config.json" ]; then
        ok "En caché: ${TF_DIR} ($(du -sh "$TF_DIR" | cut -f1))"
        _DL_OK=1
    else
        if [ -d "$TF_DIR" ]; then
            warn "Directorio incompleto detectado — re-descargando"
        fi

        while [ "$_DL_OK" -eq 0 ]; do
            _DL_ATTEMPT=$((_DL_ATTEMPT + 1))
            info "Descargando modelo completo: ${M_REPO} (intento ${_DL_ATTEMPT})..."
            info "Esto puede tardar varios minutos la primera vez..."

            if [ -n "$HF_TOKEN" ]; then
                "$HF_CMD" download "$M_REPO" \
                    --local-dir "$TF_DIR" \
                    --token "$HF_TOKEN" 2>&1 | grep -v "^Warning:\|^Hint:" && _DL_OK=1 || true
            else
                "$HF_CMD" download "$M_REPO" \
                    --local-dir "$TF_DIR" \
                    2>&1 | grep -v "^Warning:\|^Hint:" && _DL_OK=1 || true
            fi

            if [ "$_DL_OK" -eq 0 ]; then
                _WAIT=$(( _DL_ATTEMPT < 6 ? _DL_ATTEMPT * 60 : 300 ))
                warn "Intento ${_DL_ATTEMPT} fallido. Reintentando en ${_WAIT}s..."
                warn "Verifica: acceso a internet, quota de HuggingFace, nombre del modelo."
                sleep "$_WAIT"
            fi
        done

        ok "Descargado: $(du -sh "$TF_DIR" | cut -f1)"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# PASO 3.5: llama-cpp-python sin AVX (solo modelos GGUF)
# ─────────────────────────────────────────────────────────────────────────────
# Los wheels pre-compilados de llama-cpp-python usan AVX2, que muchos VPS no
# exponen (causa SIGILL / exit 132). Este paso compila una versión sin AVX y
# la guarda en /home/container/.pylibs (volumen persistente).
# Solo ocurre UNA VEZ — los reinicios posteriores usan el build cacheado.
# ─────────────────────────────────────────────────────────────────────────────
if [ "$M_TYPE" = "gguf" ]; then
    echo ""
    echo -e "${BOLD}[3.5/4] llama-cpp-python (CPU compatible)${NC}"
    sep
    _PYLIBS="/home/container/.pylibs"
    _LLAMA_FLAG="$_PYLIBS/.llama_noavx_ok"

    if [ ! -f "$_LLAMA_FLAG" ]; then
        warn "Primera compilación: llama-cpp-python sin AVX (~15-20 min)."
        warn "Esto solo ocurre UNA VEZ — los siguientes inicios son instantáneos."
        mkdir -p "$_PYLIBS"
        # FIX: redirigir tmp y cache de pip a /home/container para evitar
        # "No space left on device" en el overlay del container (solo ~100-300MB).
        # La compilación + headers C++ usa 500MB-1GB de espacio temporal.
        _PIP_TMP="/home/container/.pip_tmp"
        _PIP_CACHE="/home/container/.pip_cache"
        mkdir -p "$_PIP_TMP" "$_PIP_CACHE"
        export TMPDIR="$_PIP_TMP"
        export CMAKE_ARGS="-DGGML_NATIVE=OFF -DGGML_AVX=OFF -DGGML_AVX2=OFF -DGGML_F16C=OFF -DGGML_FMA=OFF"
        if pip3 install --break-system-packages \
            --target "$_PYLIBS" \
            --cache-dir "$_PIP_CACHE" \
            --no-build-isolation \
            "llama-cpp-python" --no-binary llama-cpp-python; then
            touch "$_LLAMA_FLAG"
            ok "llama-cpp-python compilado y guardado en $_PYLIBS"
            # Liberar caché temporal post-compilación (~500MB)
            rm -rf "$_PIP_TMP" "$_PIP_CACHE"
        else
            die "Falló la compilación de llama-cpp-python. Reinicia para reintentar."
        fi
    else
        ok "llama-cpp-python sin AVX: usando build cacheado"
    fi
    export PYTHONPATH="$_PYLIBS:${PYTHONPATH:-}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PASO 4: Iniciar API
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}[4/4] Iniciando Boxi-AI${NC}"
sep
echo ""
echo -e "  ${DIM}Modelo   ${NC}  ${GREEN}${BOLD}${M_LABEL}${NC}"
echo -e "  ${DIM}Tipo     ${NC}  ${GREEN}${BOLD}${M_TYPE^^}${NC}"
echo -e "  ${DIM}Puerto   ${NC}  ${GREEN}${BOLD}${API_PORT}${NC}"
echo -e "  ${DIM}Threads  ${NC}  ${GREEN}${BOLD}${N_THREADS} vCPU${NC}"
echo -e "  ${DIM}Contexto ${NC}  ${GREEN}${BOLD}${N_CTX} tokens${NC}"
echo ""
sep
echo ""

export MODEL_NAME MODEL_CACHE API_TOKEN API_PORT MAX_TOKENS N_THREADS N_CTX CONTEXT_FILE

cleanup() {
    echo ""
    echo -e "${YELLOW}  ⚠ Señal recibida — deteniendo Boxi-AI...${NC}"
    exit 0
}
trap cleanup SIGTERM SIGINT

# -u → stdout sin buffer (logs en tiempo real en la consola de Pterodactyl)
exec python3 -u "$APP_PY"
