#!/bin/bash
set -euo pipefail

# ============================================================
# 在 Ubuntu22 编译机上运行：build 每个 NF 的 docker 镜像并导出成 tar
# 用法： ./build_all.sh
# 产物： ./_out/<nf>.tar  (每个 NF 一个 tar)
# ============================================================

# ---- 配置（按需修改）----
# 你在 K8s 上看到的镜像 repo 前缀。必须和 chart 里的 image.repository 对得上。
# 集群实测： ghcr.io/omec-project/5gc-<nf>:rel-<ver>
REGISTRY_PREFIX="${REGISTRY_PREFIX:-ghcr.io/omec-project/}"

# 自定义 tag 后缀。每个 NF 最终 tag = rel-<该NF的VERSION>-<TAG_SUFFIX>
# 例如 udr(VERSION=3.0.0) => rel-3.0.0-tycustom , amf => rel-3.1.0-tycustom
# 保留原版本号便于追溯，同时与官方 tag(rel-3.0.0)区分，避免 K8s 复用旧镜像。
TAG_SUFFIX="${TAG_SUFFIX:-tycustom}"

# 要编译的 NF 列表
NFS=(amf ausf pcf udm udr nrf nssf smf)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${SCRIPT_DIR}/_out"
mkdir -p "${OUT_DIR}"

for nf in "${NFS[@]}"; do
  nf_dir="${SCRIPT_DIR}/NFs/${nf}"
  [ -d "${nf_dir}" ] || { echo "跳过：${nf_dir} 不存在"; continue; }

  # 每个 NF 读自己的 VERSION，tag 拼成 rel-<VERSION>-<TAG_SUFFIX>
  ver="$(cat "${nf_dir}/VERSION" 2>/dev/null | tr -d '[:space:]')"
  image_tag="rel-${ver}-${TAG_SUFFIX}"

  # Makefile 里镜像名 = REGISTRY + REPOSITORY + 5gc- + <nf> : TAG
  # 我们用 DOCKER_REPOSITORY 承载前缀，DOCKER_TAG 承载自定义 tag。
  image="${REGISTRY_PREFIX}5gc-${nf}:${image_tag}"

  echo "================================================================"
  echo "[build] ${nf}  ->  ${image}"
  echo "================================================================"
  (
    cd "${nf_dir}"
    # make docker-build 会执行 go mod vendor + docker build + 打 tag + 删 vendor
    make docker-build \
      DOCKER_REPOSITORY="${REGISTRY_PREFIX}" \
      DOCKER_TAG="${image_tag}"
  )

  echo "[save]  ${image}  ->  ${OUT_DIR}/${nf}.tar"
  docker save "${image}" -o "${OUT_DIR}/${nf}.tar"
done

echo ""
echo "全部完成。tar 文件在： ${OUT_DIR}/"
ls -lh "${OUT_DIR}/"
echo ""
echo "下一步：把 ${OUT_DIR}/*.tar scp 到 K8s 机，再运行 load_images.sh。"
echo "repo 前缀 = ${REGISTRY_PREFIX} , tag 形如 rel-<VERSION>-${TAG_SUFFIX}"
