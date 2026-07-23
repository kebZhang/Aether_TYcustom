#!/bin/bash
set -euo pipefail

# ============================================================
# 在 CloudLab K8s 机上运行：把 scp 过来的 *.tar 导入容器运行时
# 用法： ./load_images.sh <包含 tar 的目录>
# 例：   ./load_images.sh /local/aether_custom_images
# ============================================================

TAR_DIR="${1:?用法: ./load_images.sh <tar目录>}"

# ---- 自动探测运行时 ----
RUNTIME="$(kubectl get node -o jsonpath='{.items[0].status.nodeInfo.containerRuntimeVersion}')"
echo "检测到容器运行时: ${RUNTIME}"

load_one() {
  local tar="$1"
  echo "---- load ${tar} ----"
  case "${RUNTIME}" in
    containerd://*)
      # containerd：优先 nerdctl，其次 ctr。注意 K8s 镜像在 k8s.io namespace。
      if command -v nerdctl >/dev/null 2>&1; then
        sudo nerdctl -n k8s.io load -i "${tar}"
      else
        sudo ctr -n k8s.io images import "${tar}"
      fi
      ;;
    docker://*)
      sudo docker load -i "${tar}"
      ;;
    *)
      echo "未知运行时 ${RUNTIME}，请手动 load ${tar}"; exit 1
      ;;
  esac
}

for tar in "${TAR_DIR}"/*.tar; do
  [ -f "${tar}" ] || { echo "目录里没有 tar 文件"; exit 1; }
  load_one "${tar}"
done

echo ""
echo "全部导入完成。验证："
case "${RUNTIME}" in
  containerd://*)
    if command -v nerdctl >/dev/null 2>&1; then
      sudo nerdctl -n k8s.io images | grep 5gc- || true
    else
      sudo ctr -n k8s.io images ls | grep 5gc- || true
    fi
    ;;
  docker://*)
    sudo docker images | grep 5gc- || true
    ;;
esac
