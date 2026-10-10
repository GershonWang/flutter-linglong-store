#!/usr/bin/env bash
# 玲珑构建容器内的装配步骤。
#
# 业务定位：
#   Flutter Linux 产物是自包含 bundle（可执行文件与 lib/、data/、libexec/ 同级），
#   而玲珑要求应用文件落在 $PREFIX（/opt/apps/<appid>/files）下，并且只有 share/
#   下的 desktop 与图标会被导出给宿主（见宿主 /usr/share/linglong/export-dirs.json）。
#   本脚本只做「装配」，不编译、不联网、不解析版本号。
#
# 为什么不在构建容器里编译：
#   玲珑 base 镜像只装运行时，实测无 gcc/g++/make/cmake/ninja/pkg-config，
#   也没有 Flutter SDK；Flutter 产物只能由 build/scripts/build-linux-bundle.sh
#   在发布容器里预编译。这里消费它的产物——与 RPM 的「二进制重打包」轨道同构。
#
# 调用约束：
#   - 由 ll-builder 执行，cwd 为 /project（ll-builder 挂载的项目目录）；
#   - $PREFIX 与 $LINGLONG_APPID 由 ll-builder 注入，脚本内禁止硬编码应用 ID；
#   - /project/payload 是 Flutter bundle 内容，/project/share 是待导出的 share 树。
set -euo pipefail

: "${PREFIX:?ll-builder 未注入 PREFIX}"
: "${LINGLONG_APPID:?ll-builder 未注入 LINGLONG_APPID}"

payload_dir="/project/payload"
share_dir="/project/share"

if [[ ! -d "$payload_dir" ]]; then
  echo "装配失败：缺少预编译产物目录 $payload_dir" >&2
  exit 1
fi

if [[ ! -x "$payload_dir/linglong_store" ]]; then
  echo "装配失败：$payload_dir/linglong_store 不存在或不可执行" >&2
  exit 1
fi

install -d "$PREFIX"

# bundle 内部的相对布局必须原样保留：Flutter 引擎按可执行文件所在目录定位
# data/icudtl.dat 与 data/flutter_assets，CMake 侧 RPATH 是 $ORIGIN/lib，
# 特权 helper 也按可执行文件同级目录的 libexec/ 定位（lib/core/platform/
# privileged_helper/privileged_helper_binary.dart）。
cp -a "$payload_dir/." "$PREFIX/"

# share/ 是唯一会被玲珑导出给宿主的目录：desktop 入口与 hicolor 图标必须在这里，
# 否则包能装上但启动器里看不到应用。
if [[ -d "$share_dir" ]]; then
  install -d "$PREFIX/share"
  cp -a "$share_dir/." "$PREFIX/share/"
fi
