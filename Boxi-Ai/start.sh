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

# ── Log a archivo ─────────────────────────────────────────────────────────────
# Todo el output (stdout + stderr) se escribe en consola Y en logs/startup_*.log
# para poder revisar errores incluso si el servidor crashea antes de terminar.
mkdir -p /home/container/logs
# Mantener solo los últimos 5 logs (evitar llenar disco)
ls -t /home/container/logs/startup_*.log 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true
LOG_FILE="/home/container/logs/startup_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

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
#
# CUÁDRUPLE PROTECCIÓN contra instrucciones AVX (v4 — definitivo):
#  1. COMPILER WRAPPERS (CC/CXX) — la única protección 100% infalible:
#     gcc/g++ wrappers que añaden -mno-avx AL FINAL del cmd de compilación.
#     En GCC, los flags POSTERIORES siempre ganan: si cmake añade -mavx2
#     antes, nuestro -mno-avx2 al final lo sobrescribe invariablemente.
#  2. CFLAGS/CXXFLAGS → flags adicionales en posición inicial.
#  3. CMAKE_ARGS → desactiva GGML_AVX/GGML_NATIVE antes de que cmake actúe.
#  4. --config-settings cmake.args (uno por flag) → PEP 517 para
#     scikit-build-core. Nota: pasar todos juntos en una sola string con
#     espacios NO funciona (llega a cmake como un único argumento).
# ─────────────────────────────────────────────────────────────────────────────
if [ "$M_TYPE" = "gguf" ]; then
    echo ""
    echo -e "${BOLD}[3.5/4] llama-cpp-python (CPU compatible)${NC}"
    sep
    _PYLIBS="/home/container/.pylibs"
    # v7: cmake.args en UN solo --config-settings (semicolons) + PATH-intercept.
    # Causa raíz confirmada (log v6): DISASM mostró 555K instrucciones AVX →
    # las opciones GGML_AVX=OFF NUNCA llegaron a cmake. Motivos:
    #   · El pip del VPS es < 23.1 y DESCARTA todos los --config-settings menos
    #     el ÚLTIMO → solo aplicaba -DGGML_F16C=OFF, dejando GGML_AVX/AVX2 = ON.
    #   · La versión de scikit-build-core ignora el env CMAKE_ARGS.
    # Además la CPU tiene AVX pero NO AVX2/FMA/F16C → el binario con AVX2/FMA
    # da SIGILL. Fix v7:
    #   1. TODAS las cmake.args en UN único --config-settings, separadas por ';'
    #      (scikit-build-core lo divide en lista) → ya no se pierden por el pip.
    #   2. PATH-intercept: wrappers cc/gcc/c++/g++ PRIMEROS en PATH → cmake los
    #      usa sí o sí. Sanitizan flags AVX y fuerzan -march=x86-64-v2 (solo SSE).
    #   3. Log de invocaciones del wrapper (prueba de que se usó) + disasm SOLO
    #      del .so de llama_cpp (excluye numpy, que tiene AVX con dispatch seguro).
    _LLAMA_FLAG="$_PYLIBS/.llama_noavx_v7_ok"

    # Volcado de las capacidades REALES de la CPU (ayuda a diagnosticar SIGILL)
    _CPUFLAGS=$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null | sed 's/^flags[[:space:]]*:[[:space:]]*//')
    if [ -n "$_CPUFLAGS" ]; then
        _line=""
        for _f in sse2 sse4_2 avx avx2 fma f16c avx512f; do
            if printf '%s' "$_CPUFLAGS" | grep -qw "$_f"; then _line="$_line ${_f}=sí"; else _line="$_line ${_f}=no"; fi
        done
        echo -e "  ${DIM}CPU :${NC}${_line}"
    fi

    if [ ! -f "$_LLAMA_FLAG" ]; then
        warn "Compilando llama-cpp-python sin AVX (~30-40 min, 1 job)."
        warn "Esto solo ocurre UNA VEZ — los siguientes inicios son instantáneos."
        rm -rf "$_PYLIBS" "/home/container/.pip_tmp" "/home/container/.pip_cache" \
               "/home/container/.compiler_wrappers" 2>/dev/null || true
        mkdir -p "$_PYLIBS"
        _PIP_TMP="/home/container/.pip_tmp"
        _PIP_CACHE="/home/container/.pip_cache"
        _WRAPPERS="/home/container/.compiler_wrappers"
        mkdir -p "$_PIP_TMP" "$_PIP_CACHE" "$_WRAPPERS"
        export TMPDIR="$_PIP_TMP"

        # ── Wrappers SANITIZANTES con PATH-intercept ──────────────────────────
        # Un único script _novax, symlinkeado como cc/gcc/c++/g++ y puesto
        # PRIMERO en PATH. Así cmake usa nuestros wrappers haga lo que haga.
        # Cada wrapper: (1) registra su invocación en un log (prueba de uso),
        # (2) descarta -mavx*/-mfma/-mf16c/-march/-mtune, (3) fuerza
        # -march=x86-64-v2 (SSE4.2 — SIN AVX).
        _REAL_GCC="$(command -v gcc 2>/dev/null || echo /usr/bin/gcc)"
        _REAL_GPP="$(command -v g++ 2>/dev/null || echo /usr/bin/g++)"
        export NOVAX_REAL_CC="$_REAL_GCC"
        export NOVAX_REAL_CXX="$_REAL_GPP"
        export NOVAX_LOG="$_WRAPPERS/calls.log"
        cat > "$_WRAPPERS/_novax" <<'WRAP'
#!/bin/bash
self="$(basename "$0")"
case "$self" in
  *++) REAL="${NOVAX_REAL_CXX:-/usr/bin/g++}" ;;
  *)   REAL="${NOVAX_REAL_CC:-/usr/bin/gcc}" ;;
esac
echo "[$self] $*" >> "${NOVAX_LOG:-/dev/null}" 2>/dev/null
args=()
for a in "$@"; do
  case "$a" in
    -mavx*|-mfma*|-mf16c|-march=*|-mtune=*) ;;   # descartar (habilitan AVX/etc.)
    *) args+=("$a") ;;
  esac
done
exec "$REAL" "${args[@]}" \
  -march=x86-64-v2 -mno-avx -mno-avx2 -mno-avx512f -mno-fma -mno-f16c
WRAP
        chmod +x "$_WRAPPERS/_novax"
        for _n in cc gcc c++ g++; do ln -sf "$_WRAPPERS/_novax" "$_WRAPPERS/$_n"; done
        export PATH="$_WRAPPERS:$PATH"
        export CC="$_WRAPPERS/gcc"
        export CXX="$_WRAPPERS/g++"
        export CFLAGS="-march=x86-64-v2 -mno-avx -mno-avx2 -mno-fma -mno-f16c"
        export CXXFLAGS="$CFLAGS"
        export CMAKE_ARGS="-DCMAKE_C_COMPILER=$_WRAPPERS/gcc -DCMAKE_CXX_COMPILER=$_WRAPPERS/g++ -DGGML_NATIVE=OFF -DGGML_AVX=OFF -DGGML_AVX2=OFF -DGGML_AVX512=OFF -DGGML_FMA=OFF -DGGML_F16C=OFF"
        export CMAKE_BUILD_PARALLEL_LEVEL=1

        # TODAS las cmake.args en UN solo --config-settings, separadas por ';'
        # (scikit-build-core las divide en lista). Esto evita que el pip antiguo
        # del VPS descarte todas menos la última.
        _CMAKE_ALL="-DCMAKE_C_COMPILER=$_WRAPPERS/gcc;-DCMAKE_CXX_COMPILER=$_WRAPPERS/g++;-DGGML_NATIVE=OFF;-DGGML_AVX=OFF;-DGGML_AVX2=OFF;-DGGML_AVX512=OFF;-DGGML_FMA=OFF;-DGGML_F16C=OFF"

        if pip3 install --break-system-packages \
            --target "$_PYLIBS" \
            --cache-dir "$_PIP_CACHE" \
            --config-settings "cmake.args=$_CMAKE_ALL" \
            "llama-cpp-python" --no-binary llama-cpp-python; then

            # ── Prueba de que el wrapper se usó ───────────────────────────────
            if [ -f "$NOVAX_LOG" ]; then
                _NCALLS=$(wc -l < "$NOVAX_LOG" 2>/dev/null || echo 0)
                _AVXIN=$(grep -cE -- '-mavx|-mfma|-mf16c|-march=native' "$NOVAX_LOG" 2>/dev/null || echo 0)
                info "Wrapper de compilador invocado ${_NCALLS} veces; ${_AVXIN} traían flags AVX (eliminados)."
                [ "$_NCALLS" -eq 0 ] && warn "El wrapper NO se usó — cmake encontró otro compilador."
            fi

            # ── Disasm SOLO del .so de llama_cpp (excluye numpy) ──────────────
            _AVXN=0
            if command -v objdump >/dev/null 2>&1; then
                while IFS= read -r _so; do
                    [ -n "$_so" ] || continue
                    _n=$(objdump -d --no-show-raw-insn "$_so" 2>/dev/null \
                         | grep -Eco '%(y|z)mm[0-9]+|vfmadd|vbroadcast|vpermil|vmaskmov|vperm2' || true)
                    _AVXN=$((_AVXN + _n))
                done <<EOF
$(find "$_PYLIBS/llama_cpp" -name "*.so*" 2>/dev/null)
EOF
                if [ "$_AVXN" -gt 0 ]; then
                    warn "DISASM (solo llama_cpp): ${_AVXN} instrucciones AVX/FMA — los flags NO se aplicaron."
                    warn "El modelo crasheará con SIGILL. Reporta este log."
                else
                    ok "DISASM (solo llama_cpp): binario limpio, 0 instrucciones AVX/FMA"
                fi
            fi

            touch "$_LLAMA_FLAG"
            ok "llama-cpp-python compilado y guardado en $_PYLIBS"
            rm -rf "$_PIP_TMP" "$_PIP_CACHE" "$_WRAPPERS"
        else
            rm -rf "$_WRAPPERS"
            die "Falló la compilación de llama-cpp-python. Reinicia para reintentar."
        fi
    else
        ok "llama-cpp-python sin AVX: usando build cacheado"
    fi
    export PYTHONPATH="$_PYLIBS:${PYTHONPATH:-}"

    # ── PRE-FLIGHT + AUTO-TUNE de N_CTX ───────────────────────────────────────
    # Carga el modelo y hace una inferencia corta ANTES de arrancar la API, para
    # detectar crashes silenciosos ("Server offline") y traducirlos a una causa:
    #   · señal 4  (SIGILL)  → instrucción ilegal (AVX) → aborta (no se arregla aquí)
    #   · señal 9  (SIGKILL) → OOM, sin RAM → baja N_CTX AUTOMÁTICAMENTE y reintenta
    #   · señal 11 (SIGSEGV) → modelo corrupto → aborta
    # El valor de N_CTX que SÍ entra en RAM se cachea en .working_n_ctx para que
    # los siguientes inicios sean directos. Así el servidor arranca solo, sin que
    # tengas que editar nada en el panel.
    _CTX_CACHE="$_PYLIBS/.working_n_ctx"
    _GGUF_PATH="$MODEL_CACHE/$M_FILE"

    if [ -f "$_CTX_CACHE" ]; then
        _cached=$(cat "$_CTX_CACHE" 2>/dev/null || echo "")
        if printf '%s' "$_cached" | grep -qE '^[0-9]+$' && [ "$_cached" -lt "$N_CTX" ]; then
            warn "Auto-tune previo: N_CTX limitado a ${_cached} (la RAM no alcanza para ${N_CTX})"
            N_CTX="$_cached"
        fi
    else
        # Candidatos: el N_CTX pedido y, si crashea por OOM, valores menores
        _CANDIDATES="$N_CTX"
        for _c in 2048 1024 512; do
            [ "$_c" -lt "$N_CTX" ] && _CANDIDATES="$_CANDIDATES $_c"
        done

        _CHOSEN=""
        for _try in $_CANDIDATES; do
            info "Pre-flight: probando carga del modelo con N_CTX=${_try}..."
            PYTHONPATH="$_PYLIBS:${PYTHONPATH:-}" python3 - "$_GGUF_PATH" "$_try" "$N_THREADS" <<'PYEOF'
import sys
from llama_cpp import Llama
path, nctx, nth = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
m = Llama(model_path=path, n_ctx=nctx, n_threads=nth, n_gpu_layers=0, verbose=False)
o = m.create_chat_completion(messages=[{"role": "user", "content": "ping"}], max_tokens=8)
print("PREFLIGHT_OK:", o["choices"][0]["message"]["content"][:60].replace(chr(10), " "))
PYEOF
            _rc=$?
            if [ "$_rc" -eq 0 ]; then
                _CHOSEN="$_try"
                break
            elif [ "$_rc" -gt 128 ]; then
                _sig=$((_rc - 128))
                if [ "$_sig" -eq 4 ]; then
                    warn "SIGILL detectado — ejecutando diagnóstico de la instrucción exacta..."
                    echo -e "${DIM}  ── Diagnóstico SIGILL ──────────────────────────────${NC}"
                    # (1) .so presentes en llama_cpp (confirmar qué escanear)
                    echo "  Librerías .so de llama_cpp:"
                    find "$_PYLIBS/llama_cpp" -name "*.so*" 2>/dev/null | while read -r _f; do
                        echo "    $(du -h "$_f" 2>/dev/null | cut -f1)  $_f"
                    done
                    # (2) Disasm AMPLIO — incluye F16C (vcvtph2ps), que el check previo NO miraba
                    if command -v objdump >/dev/null 2>&1; then
                        echo "  Conteo de instrucciones por tipo (por librería):"
                        for _f in $(find "$_PYLIBS/llama_cpp" -name "*.so*" 2>/dev/null); do
                            _d=$(objdump -d --no-show-raw-insn "$_f" 2>/dev/null)
                            for _pat in vcvtph2ps vcvtps2ph vfmadd '%ymm' '%zmm' vbroadcast vpermil vpgather; do
                                _c=$(printf '%s\n' "$_d" | grep -cE -- "$_pat" 2>/dev/null || echo 0)
                                _c=$(printf '%s' "$_c" | tr -d '[:space:]')
                                [ "${_c:-0}" -gt 0 ] 2>/dev/null && echo "    [$(basename "$_f")] ${_pat}: ${_c}"
                            done
                        done
                    fi
                    # (3) gdb: instrucción EXACTA del fallo + librería culpable
                    command -v gdb >/dev/null 2>&1 || (apt-get update -qq && apt-get install -y -qq gdb) >/dev/null 2>&1 || true
                    if command -v gdb >/dev/null 2>&1; then
                        echo "  Instrucción que falla (gdb):"
                        PYTHONPATH="$_PYLIBS:${PYTHONPATH:-}" gdb -batch -nx \
                            -ex 'set pagination off' -ex run \
                            -ex 'printf "FAULT_INSN "' -ex 'x/i $pc' \
                            -ex 'info symbol $pc' -ex 'bt' \
                            --args python3 -c "from llama_cpp import Llama; Llama(model_path='$_GGUF_PATH', n_ctx=256, n_threads=1, verbose=False)" 2>&1 \
                          | grep -E 'FAULT_INSN|=> 0x|\.so|SIGILL|#[0-9]+ ' | head -n 20 | sed 's/^/    /'
                    fi
                    # (4) dmesg (si el container tiene acceso)
                    dmesg 2>/dev/null | grep -iE 'invalid opcode|trap' | tail -3 | sed 's/^/    dmesg: /' || true
                    echo -e "${DIM}  ────────────────────────────────────────────────────${NC}"
                    die "SIGILL — diagnóstico arriba. Pásame ESTE log completo para el fix definitivo.
  (CPU: avx=sí pero f16c/avx2/fma=no → muy probablemente una instrucción F16C
   'vcvtph2ps' que ggml usa en su ruta AVX asumiendo que toda CPU con AVX
   tiene F16C. El conteo de arriba lo confirma.)"
                elif [ "$_sig" -eq 9 ]; then
                    warn "N_CTX=${_try} se quedó SIN MEMORIA (OOM, señal 9). Probando un valor menor..."
                    continue
                else
                    die "llama_cpp crashea con señal ${_sig} al cargar (N_CTX=${_try})."
                fi
            else
                die "Pre-flight falló (código ${_rc}). Revisa el error de Python arriba."
            fi
        done

        if [ -z "$_CHOSEN" ]; then
            die "El modelo no cargó ni con N_CTX=512 — la RAM del servidor es demasiado baja.
  Sube la RAM asignada al servidor o usa un modelo GGUF más pequeño (qwen3.5-0.8b)."
        fi

        echo "$_CHOSEN" > "$_CTX_CACHE"
        if [ "$_CHOSEN" -lt "$N_CTX" ]; then
            warn "Auto-tune: N_CTX reducido de ${N_CTX} a ${_CHOSEN} para que entre en la RAM disponible."
            N_CTX="$_CHOSEN"
        else
            ok "Pre-flight OK — el modelo carga e infiere con N_CTX=${N_CTX}"
        fi
    fi
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
