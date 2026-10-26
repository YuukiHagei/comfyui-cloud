#!/usr/bin/env bash
# =============================================================================
# 给「模板自带的 ComfyUI」补模型（不改模板、不重装 ComfyUI）
# 用法（在 Cloud Studio 终端里）：
#     bash cloud-setup.sh              # 完整装（约 10 GB，含像素 LoRA）
#     SKIP_PIXEL=1 bash cloud-setup.sh # 省 160 MB，跳过像素 LoRA
#     SKIP_CHIBI2=1 bash cloud-setup.sh# 再省 35 MB，只留一个 Q版 LoRA
#
# 做的事：
#   1. 找到模板里 ComfyUI 的位置和 models 目录（并检查可写 / 磁盘够不够）
#   2. 装 ComfyUI_IPAdapter_plus 节点
#   3. 从 ModelScope / HF 镜像下载：SDXL base、IPAdapter、CLIP-ViT-H、LoRA
#   4. 打印一份「装了什么 / 还差什么 / 怎么重启」的清单
#
# 不会自动重启你的 ComfyUI —— 模板一般由平台托管，重启方式见最后输出。
# =============================================================================
set -uo pipefail

MS="https://modelscope.cn/api/v1/models"
HF="https://hf-mirror.com"

say() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
ok()  { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[1;31m✗\033[0m %s\n' "$*"; }

# ---------- 1. 定位 ComfyUI ----------
say "1/5 定位 ComfyUI"
COMFY=""
# 先看进程参数（模板通常用 python main.py 启动）
PID=$(pgrep -f "main.py" | head -1 || true)
if [ -n "${PID:-}" ]; then
  ARGS=$(tr '\0' ' ' < "/proc/$PID/cmdline" 2>/dev/null || true)
  CWD=$(readlink -f "/proc/$PID/cwd" 2>/dev/null || true)
  if echo "$ARGS" | grep -q "main.py"; then
    case "$ARGS" in
      *"main.py"*) COMFY="$CWD";;
    esac
  fi
fi
# 兜底：全盘找
if [ -z "$COMFY" ] || [ ! -f "$COMFY/main.py" ]; then
  CAND=$(find / -maxdepth 8 -path '*ComfyUI/main.py' 2>/dev/null | head -1)
  [ -n "$CAND" ] && COMFY=$(dirname "$CAND")
fi

if [ -z "$COMFY" ] || [ ! -f "$COMFY/main.py" ]; then
  bad "没找到 ComfyUI/main.py —— 这个模板可能不是标准目录结构"
  echo "  先跑这两条，把输出发给助手："
  echo "    ps aux | grep -i -E 'main.py|comfy' | head"
  echo "    find / -maxdepth 8 -name main.py 2>/dev/null | head"
  exit 1
fi
ok "ComfyUI = $COMFY"

M="$COMFY/models"
if [ ! -d "$M" ]; then
  bad "没有 models 目录：$M"; exit 1
fi
if ! touch "$M/.write_test" 2>/dev/null; then
  bad "models 目录不可写：$M"; exit 1
fi
rm -f "$M/.write_test"
ok "models = $M（可写）"

mkdir -p "$M/checkpoints" "$M/loras" "$M/ipadapter" "$M/clip_vision" "$M/clip"
FREE_GB=$(df -BG --output=avail "$M" 2>/dev/null | tail -1 | tr -dc '0-9')
echo "  可用空间：${FREE_GB:-?} GB"
if [ -n "${FREE_GB:-}" ] && [ "$FREE_GB" -lt 12 ]; then
  bad "空间不足 12 GB —— 建议 SKIP_PIXEL=1 SKIP_CHIBI2=1 bash cloud-setup.sh（约 8 GB）"
fi

# ---------- 2. IPAdapter 节点 ----------
say "2/5 安装 IPAdapter 节点"
NODE="$COMFY/custom_nodes/ComfyUI_IPAdapter_plus"
if [ -d "$NODE" ]; then
  ok "已存在：$NODE"
else
  git clone --depth 1 https://gh-proxy.com/https://github.com/cubiq/ComfyUI_IPAdapter_plus.git "$NODE" 2>/dev/null \
    && ok "已安装" || bad "克隆失败（可能没网/没 git）"
fi

# ---------- 3. 下载 ----------
say "3/5 下载模型"
dl() { # dl <url> <目标> <预期MB> <名称>
  local url="$1" out="$2" mb="$3" name="$4"
  if [ -f "$out" ]; then
    local have; have=$(du -m "$out" | cut -f1)
    if [ "$have" -gt $((mb * 90 / 100)) ]; then ok "$name 已存在（${have} MB）"; return 0; fi
    echo "  $name 不完整（${have}/${mb} MB），续传"
  fi
  echo "  ↓ $name（约 ${mb} MB）"
  curl -fL --retry 5 --retry-delay 3 -C - --progress-bar -o "$out.part" "$url" \
    && mv "$out.part" "$out" && ok "$name 完成" || { bad "$name 下载失败"; rm -f "$out.part"; return 1; }
}

dl "$MS/AI-ModelScope/stable-diffusion-xl-base-1.0/repo?Revision=master&FilePath=sd_xl_base_1.0.safetensors" \
   "$M/checkpoints/sd_xl_base_1.0.safetensors" 6617 "SDXL base 1.0"

dl "$MS/AI-ModelScope/IP-Adapter/repo?Revision=master&FilePath=sdxl_models%2Fip-adapter-plus_sdxl_vit-h.safetensors" \
   "$M/ipadapter/ip-adapter-plus_sdxl_vit-h.safetensors" 808 "IPAdapter plus SDXL (ViT-H)"

dl "$MS/AI-ModelScope/IP-Adapter/repo?Revision=master&FilePath=models%2Fimage_encoder%2Fmodel.safetensors" \
   "$M/clip_vision/CLIP-ViT-H-14-laion2B.safetensors" 2411 "CLIP-ViT-H 视觉编码器"

[ "${SKIP_PIXEL:-0}" = "1" ] || \
dl "$HF/nerijs/pixel-art-xl/resolve/main/pixel-art-xl.safetensors" \
   "$M/loras/pixel-art-xl.safetensors" 160 "像素 LoRA"

dl "$HF/K666K/SDXL_chibi_flat/resolve/main/SDXL_styl-z-000004.safetensors" \
   "$M/loras/chibi-flat-2d-xl.safetensors" 210 "Q版 LoRA（flat 2d）"

[ "${SKIP_CHIBI2:-0}" = "1" ] || \
dl "$HF/trappy/ChibiArtStyle/resolve/main/output/chibiArtstyle_10.safetensors" \
   "$M/loras/chibi-artstyle-xl.safetensors" 35 "Q版 LoRA（artstyle）"

# ---------- 4. 自检 ----------
say "4/5 自检"
for f in \
  "$M/checkpoints/sd_xl_base_1.0.safetensors" \
  "$M/ipadapter/ip-adapter-plus_sdxl_vit-h.safetensors" \
  "$M/clip_vision/CLIP-ViT-H-14-laion2B.safetensors" ; do
  if [ -s "$f" ]; then ok "$(basename "$f") $(du -m "$f" | cut -f1) MB"; else bad "缺 $(basename "$f")"; fi
done
ls -1 "$M/loras" 2>/dev/null | sed 's/^/  LoRA: /'

# ---------- 5. 下一步 ----------
say "5/5 下一步"
cat <<EOF
  1) 重启 ComfyUI 让它扫到新模型：
       · 模板由平台托管 → 在 Cloud Studio 面板点「重启」/「重新运行」
       · 自己起的 → kill 后重跑原来的启动命令
  2) 重启后把这句话发给我：「重启好了」
     我会立刻通过 API 验证模型是否被识别，并跑第一张 Q版+IPAdapter。
  3) 如果 models 目录是只读/空间不足：
     新建一个「Ubuntu 22.04 / PyTorch」基础镜像工作空间（不要用 ComfyUI 模板），
     然后跑 install-comfyui-t4.sh —— 从零装，路径完全可控。
EOF
