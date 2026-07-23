# docker_images —— NF 镜像 tar 中转目录

本目录是**小新本地电脑上的中转站**，用来暂存从机器A（Ubuntu22 编译机）编译导出的
Aether 5GC 网元（NF）Docker 镜像 tar，再转发到机器B（K8s 集群）。

完整更新流程见上层文档：[../update_aether_docker_image.md](../update_aether_docker_image.md)

---

## 目录约定

每个子文件夹对应**一批/一个版本**的镜像 tar，便于区分不同来源。

| 子文件夹 | 内容 |
|----------|------|
| `original_code/` | **原始 v4.1.0 chart 版本 Aether 源码**编译出的 8 个 NF 镜像（未加任何自定义代码，功能等同官方镜像，仅用于验证"编译→load→替换"流程本身可行） |

`original_code/` 里的 8 个 tar：
```
amf.tar  ausf.tar  nrf.tar  nssf.tar  pcf.tar  smf.tar  udm.tar  udr.tar
```
对应镜像（tag 后缀 `-tycustom`，各 NF 版本号不同）：
```
ghcr.io/omec-project/5gc-amf:rel-3.1.0-tycustom
ghcr.io/omec-project/5gc-ausf:rel-3.0.0-tycustom
ghcr.io/omec-project/5gc-nrf:rel-3.0.0-tycustom
ghcr.io/omec-project/5gc-nssf:rel-3.0.0-tycustom
ghcr.io/omec-project/5gc-pcf:rel-3.0.0-tycustom
ghcr.io/omec-project/5gc-smf:rel-4.1.0-tycustom
ghcr.io/omec-project/5gc-udm:rel-3.0.0-tycustom
ghcr.io/omec-project/5gc-udr:rel-3.0.0-tycustom
```

> 以后加了自定义代码，建议按版本另建子文件夹（如 `tycustom2/`、`amf-worker-log/` 等），
> 并同步递增镜像 tag 后缀，避免和旧镜像混淆。

---

## 注意：本目录下的 tar 不入 git

镜像 tar 体积大（本批约 225MB），**已在仓库根 `.gitignore` 中排除**，不会上传到 GitHub。
这些 tar 是编译产物，随时可由机器A `build_all.sh` 重新生成，无需版本控制。
本目录仅保留 `README.md` 本身入库。
