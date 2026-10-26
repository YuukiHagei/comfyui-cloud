#!/usr/bin/env bash
# =============================================================================
# 工作空间（Cloud Studio / VSCode 形态）一键启动
#   · 第一次运行：装 ComfyUI + 依赖 + 下载 10 GB 模型（约 10–20 分钟）
#   · 之后每次运行：直接起服务（秒级）
#
# 用法：
#   bash /workspace/workspace-start.sh
# 在 .vscode/preview.yml 里就填这一行，点「运行」即可。
#
# 可调环境变量：
#   ROOT=/workspace/ye-comfyui   安装位置
#   MIRROR=cn|global             下载源（默认 cn）
#   SKIP_PIXEL=1 / SKIP_CHIBI2=1 省空间
#   PORT=8188                    监听端口
# =============================================================================
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${ROOT:-/workspace/ye-comfyui}"
MIRROR="${MIRROR:-cn}"
PORT="${PORT:-8188}"
PY="${PY:-python3}"

log() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }

# ---------- 1. 首次安装 ----------
if [ ! -f "$ROOT/ComfyUI/main.py" ] || [ ! -d "$ROOT/venv" ]; then
  log "首次运行：开始安装（这一步要 10–20 分钟，模型约 10 GB）"
  if [ -f "$SELF_DIR/install-comfyui-t4.sh" ]; then
    MIRROR="$MIRROR" ROOT="$ROOT" PORT="$PORT" bash "$SELF_DIR/install-comfyui-t4.sh"
  else
    log "找不到 install-comfyui-t4.sh（应在同目录），中止"
    exit 1
  fi
fi

if [ ! -f "$ROOT/ComfyUI/main.py" ]; then
  log "安装看起来没成功，$ROOT/ComfyUI/main.py 不存在"
  exit 1
fi

# ---------- 2. 确认关键模型 ----------
M="$ROOT/ComfyUI/models"
missing=0
for f in \
  "$M/checkpoints/sd_xl_base_1.0.safetensors" \
  "$M/ipadapter/ip-adapter-plus_sdxl_vit-h.safetensors" \
  "$M/clip_vision/CLIP-ViT-H-14-laion2B.safetensors" ; do
  if [ -s "$f" ]; then
    printf '  ✓ %s (%s MB)\n' "$(basename "$f")" "$(du -m "$f" | cut -f1)"
  else
    printf '  ✗ 缺 %s\n' "$f"; missing=1
  fi
done
if [ "$missing" = "1" ]; then
  log "有模型缺失，服务仍会启动，但出图会报错 —— 检查网络后重跑本脚本（支持续传）"
fi

# ---------- 3. 启动 ----------
log "启动 ComfyUI：http://0.0.0.0:$PORT"
cd "$ROOT/ComfyUI"
# shellcheck disable=SC1091
source "$ROOT/venv/bin/activate"
exec python main.py --listen 0.0.0.0 --port "$PORT"
