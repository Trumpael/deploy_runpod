#!/bin/bash
# ============================================================
# Qwen-Image-2.1-Uncensored-GGUF — RunPod 一键部署脚本
# ============================================================
# 使用方法：
#   1. 在 RunPod 部署 ComfyUI 模板 Pod 后
#   2. 打开 Pod 的 Web Terminal 或 SSH
#   3. 运行: bash deploy_runpod.sh
# ============================================================

set -e

# ---- 配置区（可按需修改）----
# GGUF 量化版本（可选: Q4_0 Q4_K_M Q5_K_M Q6_K Q8_0 BF16）
# 推荐 Q4_K_M（体积与质量最佳平衡），磁盘紧张用 Q4_0
QUANT="Q4_K_M"

# 文本编码器版本（int8 更省显存，推荐）
# 可选: qwen3vl_8b_int8_convrot.safetensors 或 qwen3vl_8b_bf16.safetensors
TEXT_ENCODER="qwen3vl_8b_int8_convrot.safetensors"

# ComfyUI 根目录（RunPod 模板默认路径）
COMFYUI_DIR="/workspace/ComfyUI"

# HuggingFace 模型仓库
HF_REPO="abenzerps/Qwen-Image-2.1-Uncensored-GGUF"

# ---- 颜色输出 ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}"
echo "============================================"
echo "  Qwen-Image-2.1-Uncensored-GGUF 部署脚本"
echo "  量化版本: ${QUANT}"
echo "  文本编码器: ${TEXT_ENCODER}"
echo "============================================"
echo -e "${NC}"

# ---- 检查 ComfyUI 目录 ----
if [ ! -d "${COMFYUI_DIR}" ]; then
    echo -e "${RED}[错误] 未找到 ComfyUI 目录: ${COMFYUI_DIR}${NC}"
    echo -e "${YELLOW}请确认你已使用 RunPod 的 ComfyUI 模板创建 Pod${NC}"
    exit 1
fi
echo -e "${GREEN}[OK] ComfyUI 目录存在: ${COMFYUI_DIR}${NC}"

# ---- 步骤 1: 安装 ComfyUI-GGUF (leejet fork) ----
echo ""
echo -e "${CYAN}=== 步骤 1/3: 安装 ComfyUI-GGUF 插件 ===${NC}"

GGUF_DIR="${COMFYUI_DIR}/custom_nodes/ComfyUI-GGUF"

# 检查是否已有旧版 city96/ComfyUI-GGUF
if [ -d "${COMFYUI_DIR}/custom_nodes/ComfyUI-GGUF" ]; then
    echo -e "${YELLOW}[提示] ComfyUI-GGUF 已存在，检查版本...${NC}"
    cd "${GGUF_DIR}"
    git remote -v | head -2
    git pull origin main 2>/dev/null || git pull origin master 2>/dev/null || true
else
    echo -e "${YELLOW}正在克隆 leejet/ComfyUI-GGUF...${NC}"
    cd "${COMFYUI_DIR}/custom_nodes"
    git clone https://github.com/leejet/ComfyUI-GGUF
    echo -e "${GREEN}[OK] ComfyUI-GGUF 克隆完成${NC}"
fi

# 安装依赖
echo -e "${YELLOW}安装 Python 依赖...${NC}"
pip install -r "${GGUF_DIR}/requirements.txt" 2>/dev/null || true
echo -e "${GREEN}[OK] ComfyUI-GGUF 安装完成${NC}"

# ---- 步骤 2: 下载模型文件 ----
echo ""
echo -e "${CYAN}=== 步骤 2/3: 下载模型文件 ===${NC}"

# 创建目录
mkdir -p "${COMFYUI_DIR}/models/diffusion_models"
mkdir -p "${COMFYUI_DIR}/models/text_encoders"
mkdir -p "${COMFYUI_DIR}/models/vae"

# 文件名映射
case "${QUANT}" in
    Q4_0)    GGUF_FILE="qwen-image-2.1-UC-Q4_0.gguf" ;;
    Q4_K_M)  GGUF_FILE="qwen-image-2.1-UC-Q4_K_M.gguf" ;;
    Q5_K_M)  GGUF_FILE="qwen-image-2.1-UC-Q5_K_M.gguf" ;;
    Q6_K)    GGUF_FILE="qwen-image-2.1-UC-Q6_K.gguf" ;;
    Q8_0)    GGUF_FILE="qwen-image-2.1-UC-Q8_0.gguf" ;;
    BF16)    GGUF_FILE="qwen-image-2.1-UC-BF16.gguf" ;;
    *)       echo -e "${RED}[错误] 未知量化版本: ${QUANT}${NC}"; exit 1 ;;
esac

VAE_FILE="qwen_image_2.1_vae_bf16.safetensors"

# 下载函数（支持断点续传）
download_file() {
    local url="$1"
    local dest="$2"
    local name="$3"

    if [ -f "${dest}" ]; then
        echo -e "${GREEN}[跳过] ${name} 已存在: ${dest}${NC}"
        return 0
    fi

    echo -e "${YELLOW}下载 ${name}...${NC}"
    echo -e "  URL: ${url}"
    echo -e "  目标: ${dest}"

    # 优先使用 huggingface-cli（支持断点续传）
    if command -v huggingface-cli &> /dev/null; then
        local hf_filename=$(echo "${url}" | sed 's|.*/resolve/main/||')
        local hf_subpath="${hf_filename}"
        # 处理子目录文件
        if echo "${url}" | grep -q "text_encoders\|vae"; then
            hf_subpath=$(echo "${url}" | sed 's|.*/resolve/main/||')
        fi
        huggingface-cli download "${HF_REPO}" "${hf_subpath}" \
            --local-dir "$(dirname "${dest}")" \
            --local-dir-use-symlinks False 2>/dev/null || {
            echo -e "${YELLOW}huggingface-cli 失败，改用 wget...${NC}"
            wget -c -O "${dest}" "${url}"
        }
    else
        wget -c -O "${dest}" "${url}"
    fi
    echo -e "${GREEN}[OK] ${name} 下载完成${NC}"
}

# 2a: 下载 GGUF 扩散模型
DIFFUSION_URL="https://huggingface.co/${HF_REPO}/resolve/main/${GGUF_FILE}"
DIFFUSION_DEST="${COMFYUI_DIR}/models/diffusion_models/${GGUF_FILE}"
download_file "${DIFFUSION_URL}" "${DIFFUSION_DEST}" "扩散模型 (${QUANT}, $(du -h "${DIFFUSION_DEST}" 2>/dev/null | cut -f1 || echo '~4.6GB'))"

# 2b: 下载文本编码器
TE_URL="https://huggingface.co/${HF_REPO}/resolve/main/text_encoders/${TEXT_ENCODER}"
TE_DEST="${COMFYUI_DIR}/models/text_encoders/${TEXT_ENCODER}"
download_file "${TE_URL}" "${TE_DEST}" "文本编码器 (int8, ~9.35GB)"

# 2c: 下载 VAE
VAE_URL="https://huggingface.co/${HF_REPO}/resolve/main/vae/${VAE_FILE}"
VAE_DEST="${COMFYUI_DIR}/models/vae/${VAE_FILE}"
download_file "${VAE_URL}" "${VAE_DEST}" "VAE (~676MB)"

# ---- 步骤 3: 验证 & 重启 ComfyUI ----
echo ""
echo -e "${CYAN}=== 步骤 3/3: 验证文件 & 重启 ComfyUI ===${NC}"

echo ""
echo -e "${YELLOW}已下载文件:${NC}"
echo "  扩散模型:  $(ls -lh ${DIFFUSION_DEST} 2>/dev/null | awk '{print $5, $9}' || echo '缺失!')"
echo "  文本编码器: $(ls -lh ${TE_DEST} 2>/dev/null | awk '{print $5, $9}' || echo '缺失!')"
echo "  VAE:       $(ls -lh ${VAE_DEST} 2>/dev/null | awk '{print $5, $9}' || echo '缺失!')"
echo ""

# 重启 ComfyUI
echo -e "${YELLOW}重启 ComfyUI 以加载新插件...${NC}"

# 方法1: 通过 ComfyUI Manager 重启（如果安装了的话）
# 方法2: kill 现有进程并重新启动
if pgrep -f "comfyui" > /dev/null 2>&1 || pgrep -f "main.py" > /dev/null 2>&1; then
    echo -e "${YELLOW}停止现有 ComfyUI 进程...${NC}"
    pkill -f "comfyui" 2>/dev/null || true
    pkill -f "main.py.*--port" 2>/dev/null || true
    sleep 2
fi

echo -e "${YELLOW}启动 ComfyUI...${NC}"
cd "${COMFYUI_DIR}"
# 后台启动 ComfyUI
nohup python main.py --listen 0.0.0.0 --port 8188 --preview-method latents2rgb > /workspace/comfyui.log 2>&1 &
COMFYUI_PID=$!
echo -e "${GREEN}[OK] ComfyUI 已启动 (PID: ${COMFYUI_PID})${NC}"
echo -e "${YELLOW}日志: /workspace/comfyui.log${NC}"

# 等待启动
echo -e "${YELLOW}等待 ComfyUI 启动...${NC}"
for i in $(seq 1 30); do
    if curl -s http://localhost:8188/ > /dev/null 2>&1; then
        echo -e "${GREEN}[OK] ComfyUI 已就绪!${NC}"
        break
    fi
    sleep 2
    echo -e "  等待中... (${i}/30)"
done

# ---- 完成 ----
echo ""
echo -e "${GREEN}${GREEN}"
echo "============================================"
echo "  部署完成!"
echo "============================================"
echo -e "${NC}"
echo ""
echo -e "${CYAN}访问 ComfyUI:${NC}"
echo "  在 RunPod Pod 页面点击端口 8188 的链接"
echo "  或访问: https://<your-pod-id>-8188.proxy.runpod.net"
echo ""
echo -e "${CYAN}工作流设置:${NC}"
echo "  1. 在 ComfyUI 中右键 → Add Node → loaders"
echo "  2. 添加 'Unet Loader (GGUF)' 节点"
echo "     → 选择: ${GGUF_FILE}"
echo "  3. 添加 'CLIPLoader' 节点"
echo "     → 选择: ${TEXT_ENCODER}"
echo "     → type 设为: qwen_image"
echo "  4. 添加 'VAELoader' 节点"
echo "     → 选择: ${VAE_FILE}"
echo "  5. 连接节点: CLIP→TextEncode, MODEL→KSampler, VAE→VAEDecode"
echo ""
echo -e "${CYAN}或者导入工作流:${NC}"
echo "  下载官方模板并替换 UNETLoader 为 Unet Loader (GGUF):"
echo "  https://github.com/Comfy-Org/workflow_templates/blob/main/templates/image_qwen_image_2_1_t2i.json"
echo ""
echo -e "${CYAN}快速测试 (API 方式):${NC}"
echo "  python3 /workspace/generate_image.py --prompt 'A serene mountain landscape at sunrise'"
echo ""
echo -e "${YELLOW}提示: 不使用时记得在 RunPod 页面停止 Pod 以节省费用${NC}"
echo ""
