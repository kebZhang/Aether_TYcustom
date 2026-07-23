# 更新 K8s 上 Aether 5GC 的 Docker 镜像

本文说明如何把 `Aether_TYcustom/NFs/` 下的自定义 NF 代码，编译成 Docker 镜像并替换掉
K8s 集群里正在运行的 Aether 5GC 网元镜像。

整套流程已在 2026-07-23 用原版代码完整验证通过（8 个 NF 全部替换成功、Running、0 重启）。

---

## 0. 三台角色 / 三段传输

```
[机器A: Ubuntu22 编译机]          [小新本地电脑]              [机器B: K8s 集群]
  改代码 + docker build     scp     中转存放            scp      docker load
  docker save -> *.tar    ───────►  docker_images/    ───────►  kubectl set image
```

| 角色 | 说明 | 本文示例路径 |
|------|------|------|
| 机器A Ubuntu22 编译机 | 有 Go + Docker(含 buildx)，负责编译打包；代码 `git clone` 而来，目录名 `Aether_TYcustom`(带 o) | `/local/5GC/Aether_TYcustom` |
| 小新本地电脑 | Windows 中转站，暂存 tar；本地目录名 `Aether_TYcustm`(无 o) | `D:\UB\Nemo\5GC_project\code\Aether_TYcustm\docker_images` |
| 机器B K8s 集群 | 运行 Aether 5GC，容器运行时 = docker | `/local/aether_docker_images` |

> ⚠️ 目录名两处拼写不同：GitHub 仓库 / 编译机 = `Aether_TYcustom`(带 o)；小新本地 = `Aether_TYcustm`(无 o)。下文路径已分别对应，勿混。

> 注意：机器A 和机器B 主机名可能都叫 `node-0`，靠**路径和用途**区分，别弄混。

---

## 1. 关键前置知识（第一次务必读）

### 1.1 镜像命名规则
每个 NF 的 `Makefile` 里：
```
DOCKER_IMAGENAME = DOCKER_REGISTRY + DOCKER_REPOSITORY + 5gc- + <nf> : DOCKER_TAG
```
集群实测官方镜像是 `ghcr.io/omec-project/5gc-<nf>:rel-<ver>`，所以：
- `DOCKER_REPOSITORY = ghcr.io/omec-project/`
- 各 NF 版本号不同：**amf=3.1.0, smf=4.1.0, 其余(ausf/nrf/nssf/pcf/udm/udr)=3.0.0**
- 自定义 tag 用 `rel-<ver>-tycustom`，既保留原版本号又和官方区分。

### 1.2 为什么要用自定义 tag（不能复用官方 tag）
K8s `imagePullPolicy: IfNotPresent`：若 tag 和官方一样，节点上已有官方镜像，K8s 不会用你的新镜像。
**每次改代码建议把 tag 后缀递增**（`tycustom` → `tycustom2` → …），彻底避免缓存旧镜像。

### 1.3 helm 不能用来替换镜像（重要）
本 chart（sdcore 4.1.0）有一个 **upgrade 证书 bug**：
`helm upgrade` 会报 `buildCustomCert: unable to decode base64 certificate`。
因此**替换镜像用 `kubectl set image`，不用 `helm upgrade`**。
副作用：`set image` 是命令式改动，若将来有人重跑 `helm upgrade` 会覆盖回官方镜像
（但目前 helm upgrade 本身也跑不通，暂不冲突）。要持久化需先修证书 bug（见第 8 节）。

---

## 2. 机器A（Ubuntu22 编译机）：编译 + 打包

### 2.1 环境准备（第一次装好，以后不用再装）

编译需要机器A上有 **Go** 和 **Docker(含 buildx 插件)**。

**（a）安装 Go**（`go.mod` 要求 1.25/1.26）
`make docker-build` 第一步会在宿主机跑 `go mod vendor`，所以宿主机必须有 Go。
若报 `make: go: No such file`，按下面装：
```bash
cd /tmp
curl -LO https://go.dev/dl/go1.26.2.linux-amd64.tar.gz
sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf go1.26.2.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
export PATH=$PATH:/usr/local/go/bin
go version
```

**（b）安装 docker buildx 插件**
Aether 的 Dockerfile 是多阶段构建，需要 BuildKit/buildx。
若报 `BuildKit is enabled but the buildx component is missing`，按下面装：
```bash
# 先看有没有
docker buildx version   # 若报 unknown command，则未装，继续下面

# 手动装二进制（apt 源里通常没有 docker-buildx-plugin）
mkdir -p ~/.docker/cli-plugins
curl -SL https://github.com/docker/buildx/releases/download/v0.19.3/buildx-v0.19.3.linux-amd64 \
  -o ~/.docker/cli-plugins/docker-buildx
chmod +x ~/.docker/cli-plugins/docker-buildx
docker buildx version   # 打印版本号即成功
```

### 2.2 拉代码

代码仓库：`https://github.com/kebZhang/Aether_TYcustom.git`（注意仓库名带 o）
```bash
# 首次：clone（clone 出来的目录名就是 Aether_TYcustom，带 o）
cd /local/5GC
git clone https://github.com/kebZhang/Aether_TYcustom.git
cd Aether_TYcustom

# 之后每次更新代码：
# cd /local/5GC/Aether_TYcustom && git pull
```

### 2.3 编译 + 打包

```bash
chmod +x build_all.sh
./build_all.sh                    # 默认 REGISTRY=ghcr.io/omec-project/  TAG 后缀=tycustom
```

`build_all.sh` 会对 8 个 NF 依次执行：
1. `make docker-build`（内部 `docker build` 到 `golang:1.26.2` 容器里编译）
2. `docker save` 导出成 `_out/<nf>.tar`

完成后产物在 `/local/5GC/Aether_TYcustom/_out/`：
```
amf.tar ausf.tar nrf.tar nssf.tar pcf.tar smf.tar udm.tar udr.tar
```

### 2.4 只想更新部分 NF？
编辑 `build_all.sh` 里的 `NFS=(...)`，只留要改的 NF；或手动单编（以 udr 为例）：
```bash
cd NFs/udr
make docker-build DOCKER_REPOSITORY="ghcr.io/omec-project/" DOCKER_TAG="rel-3.0.0-tycustom"
docker save ghcr.io/omec-project/5gc-udr:rel-3.0.0-tycustom -o ../../_out/udr.tar
```

### 2.5 换 tag 后缀（改代码后强烈建议）
```bash
TAG_SUFFIX=tycustom2 ./build_all.sh
```
注意：换了后缀，第 5.2 节 `set image` 的 tag 也要跟着换。

---

## 3. 机器A → 小新本地电脑

在小新电脑上（Git Bash / PowerShell），把 tar 从机器A拉到本地中转目录：

```bash
# 目标目录（本地）
mkdir -p "D:/UB/Nemo/5GC_project/code/Aether_TYcustm/docker_images"

# 从机器A拉取（机器A的 ssh 地址按实际改）
scp -i ~/.ssh/cloudlab \
  Tianyang@<机器A地址>:/local/5GC/Aether_TYcustom/_out/*.tar \
  "D:/UB/Nemo/5GC_project/code/Aether_TYcustm/docker_images/"
```

> 若机器A就是能直接连机器B，也可跳过本地中转，直接 A→B scp。本文按"经小新中转"写。

---

## 4. 小新本地电脑 → 机器B（K8s）

```bash
# 机器B上先建目录
ssh -i ~/.ssh/cloudlab Tianyang@<机器B地址> "mkdir -p /local/aether_docker_images"

# 把 tar + 两个脚本传上去
scp -i ~/.ssh/cloudlab \
  "D:/UB/Nemo/5GC_project/code/Aether_TYcustm/docker_images/"*.tar \
  "D:/UB/Nemo/5GC_project/code/Aether_TYcustm/load_images.sh" \
  "D:/UB/Nemo/5GC_project/code/Aether_TYcustm/custom-images.yaml" \
  Tianyang@<机器B地址>:/local/aether_docker_images/
```

---

## 5. 机器B（K8s）：load 镜像 + 替换

### 5.1 load 进 docker
```bash
ssh -i ~/.ssh/cloudlab Tianyang@<机器B地址>
cd /local/aether_docker_images

chmod +x load_images.sh
./load_images.sh /local/aether_docker_images

# 验证镜像已导入
sudo docker images | grep tycustom
```
应看到 8 个 `ghcr.io/omec-project/5gc-<nf>:rel-<ver>-tycustom`。

> 提示：`docker save`→`load` 后 IMAGE ID 可能和编译机不同（buildx 多 manifest 会重组），
> 这是正常现象，不代表出错，只要 tag 对、后面 Pod 能 Running 即可。

### 5.2 替换 8 个 NF 镜像（kubectl set image）
```bash
declare -A TAGS=(
  [amf]=rel-3.1.0-tycustom
  [ausf]=rel-3.0.0-tycustom
  [nrf]=rel-3.0.0-tycustom
  [nssf]=rel-3.0.0-tycustom
  [pcf]=rel-3.0.0-tycustom
  [smf]=rel-4.1.0-tycustom
  [udm]=rel-3.0.0-tycustom
  [udr]=rel-3.0.0-tycustom
)

for nf in "${!TAGS[@]}"; do
  img="ghcr.io/omec-project/5gc-${nf}:${TAGS[$nf]}"
  echo ">> $nf -> $img"
  kubectl -n aether-5gc set image deploy/"$nf" "$nf=$img"
done
```
（本集群里每个 NF 的 deployment 名、容器名都等于 NF 名，故 `$nf=$img` 成立。
若换了 tag 后缀，把上面 TAGS 里的值一起改。）

### 5.3 确认
```bash
kubectl -n aether-5gc rollout status deploy/amf --timeout=120s
kubectl -n aether-5gc rollout status deploy/udr --timeout=120s

kubectl -n aether-5gc get pods

echo "---- 实际镜像 ----"
kubectl -n aether-5gc get pods \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[*].image}{"\n"}{end}' | sort -u
```
**成功标准**：amf/ausf/nrf/nssf/pcf/smf/udm/udr 八个都是 `...-tycustom` 且 `Running`；
mongodb/webui/simapp 保持官方镜像不变。

---

## 6. 更新单个 NF 的快捷流程（日常迭代最常用）

改了某个 NF（以 udr 为例）后：

```bash
# 机器A
cd /local/5GC/Aether_TYcustom/NFs/udr && git pull
make docker-build DOCKER_REPOSITORY="ghcr.io/omec-project/" DOCKER_TAG="rel-3.0.0-tycustom2"
docker save ghcr.io/omec-project/5gc-udr:rel-3.0.0-tycustom2 -o /tmp/udr.tar

# 小新中转
scp Tianyang@<A>:/tmp/udr.tar "D:/.../docker_images/"
scp "D:/.../docker_images/udr.tar" Tianyang@<B>:/local/aether_docker_images/

# 机器B
sudo docker load -i /local/aether_docker_images/udr.tar
kubectl -n aether-5gc set image deploy/udr udr=ghcr.io/omec-project/5gc-udr:rel-3.0.0-tycustom2
kubectl -n aether-5gc rollout status deploy/udr
```

> 每次改代码把 tag 后缀数字 +1（tycustom → tycustom2 → tycustom3），避免 K8s 用缓存旧镜像。

---

## 7. 故障排查

| 现象 | 原因 | 处理 |
|------|------|------|
| `make: go: No such file` | 机器A没装 Go | 见 2.1(a) 装 Go |
| `buildx component is missing` | 机器A没装 buildx | 见 2.1(b) 装 buildx |
| Pod `ErrImagePull`/`ImagePullBackOff` | buildx 多 manifest 镜像 load 后 K8s 挑不到平台 | 见第 9 节单平台重编 |
| Pod `CrashLoopBackOff` | 镜像能拉但启动失败（代码 bug/配置） | `kubectl -n aether-5gc logs deploy/<nf> --tail=80` |
| 镜像没换（还是官方 tag） | tag 和官方重名被缓存 / set image 打错容器名 | 换新 tag 后缀重来；核对容器名 |
| `helm upgrade` 报证书 base64 错 | chart 的 upgrade 证书 bug | 不要用 helm，用 `kubectl set image`；根治见第 8 节 |

---

## 8. 根治 helm 证书 bug（想让替换持久化 + 恢复 helm upgrade 时才需要）

`kubectl set image` 是命令式改动，不持久，且本 chart 的 `helm upgrade` 因证书 bug 无法运行。
若将来要让镜像覆盖持久化、并恢复 helm upgrade 能力，需修这个 bug。

思路：把首次 install 时生成的 CA 证书从集群 Secret 导出，写进 `certs-values.yaml`，
以后 `helm upgrade` 带上它。具体导出字段需结合 chart `_helpers.tpl` 里
`ensure-shared-ca` / `buildCustomCert` 读取的 values 路径，届时再定。
**在没修好之前，只用 `kubectl set image` 换镜像，不碰 helm。**

修好后，替换镜像才可改用 helm（配合本仓库 `custom-images.yaml`）：
```bash
helm -n aether-5gc upgrade aether-5gc /local/aether/sdcore-helm-charts-4.1.0/5g-control-plane \
  -f /local/aether/sdcore-helm-charts-4.1.0/aether-5gc-values.yaml \
  -f custom-images.yaml \
  -f certs-values.yaml
```

---

## 9. 单平台重编（解决 ErrImagePull 的 buildx manifest 问题）

若某 NF 在机器B报 `ErrImagePull`/`ImagePullBackOff`，通常是 buildx 默认产出的
**多 manifest(带 attestation)镜像** load 后 K8s 挑不到平台。
回机器A对该 NF 用下面命令重编，产出**传统单 manifest 镜像**，load 到任何机器都干净
（以 udr 为例，VERSION 按各 NF 实际填）：
```bash
cd /local/5GC/Aether_TYcustom/NFs/udr
docker buildx build --platform linux/amd64 --provenance=false --sca=false \
  --build-arg VERSION=3.0.0 \
  -t ghcr.io/omec-project/5gc-udr:rel-3.0.0-tycustom \
  --output type=docker,dest=/tmp/udr.tar .
```
然后把 `/tmp/udr.tar` 走第 3、4、5 节流程重新 load + 替换。

---

## 附：本集群实测环境（2026-07-23）
- K8s 容器运行时：`docker://26.1.2`（用 `docker load`）
- namespace：`aether-5gc`，helm release：`aether-5gc`（chart `5g-control-plane-4.1.0`）
- chart 路径：`/local/aether/sdcore-helm-charts-4.1.0/5g-control-plane`
- 覆盖 values：`custom-images.yaml`（形态 A：`images.repository` + `images.tags.<nf>`，
  `pullPolicy: IfNotPresent`）——**仅在第 8 节修好证书 bug 后走 helm 时才用得上**，
  当前替换用 `kubectl set image`。
- 未改动：mongodb / webui / simapp / pod-init 等保持官方镜像。
