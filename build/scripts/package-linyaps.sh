#!/usr/bin/env bash
# 玲珑（linyaps）UAB 打包编排入口。
#
# 业务定位：
#   把 Flutter Linux 发布产物打成玲珑 UAB 包（ll-builder export --uabx 的产物）。
#   与 DEB/RPM/AppImage 并列的第四种发行形态。
#
# 为什么本脚本不走 --inner 重入（与其他 package-*.sh 不同）：
#   ll-builder 只能跑在宿主机上——它需要宿主侧的玲珑守护进程、层仓库
#   (/var/lib/linglong) 与可写构建状态，容器里既没有这些命令，直调宿主二进制
#   也只会得到静默失败。因此本脚本固定在宿主侧编排：
#     - 编译：交给 build-linux-bundle.sh，它自己会进入发布容器；
#     - 元数据渲染：交给 render-packaging-templates.sh，同样自行进入发布容器；
#     - 装配与导出：本脚本直接调用宿主 ll-builder。
#   这也意味着本脚本不能在发布容器内运行，检测到即失败闭合。
#
# 产物与限制：
#   产物是一个可安装的 UAB，但**运行时功能不完整**：玲珑容器内没有 ll-cli，
#   商店的安装/卸载/更新/已装列表等能力需要宿主侧通道才能工作，详见
#   docs/59-linyaps-uab-packaging-design.md。脚本结束时会明确提示这一点。
#
# 用法：
#   build/scripts/package-linyaps.sh --version <3.7.0> --arch <amd64|arm64> \
#     [--channel stable|nightly] [--base org.deepin.base/25.2.2] [--bundle-dir <dir>]
#
#   --bundle-dir 用于 CI 复用已构建的 bundle，或本地在不重跑 Flutter 编译的前提下
#   验证打包链路；提供时跳过 build-linux-bundle.sh。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT_DIR/build/scripts/linux-arch-utils.sh"
. "$ROOT_DIR/build/scripts/lib/application-identity.sh"

load_application_identity "$ROOT_DIR/config/application_identity.conf"

# 应用文件在包内的固定前缀。玲珑把它作为 $PREFIX 注入构建容器，两侧必须一致，
# 因此只在这里推导一次，渲染清单与改写 desktop 都复用它。
readonly APP_PREFIX="/opt/apps/$APPLICATION_ID/files"

# 默认 base 决定运行时提供的系统库。Flutter Linux 产物依赖 GTK3，而 base 镜像里
# 只有运行时（无开发头文件），因此这个引用必须指向一个已发布的 base。
readonly DEFAULT_BASE_REF="org.deepin.base/25.2.2"

# Flutter 产物里 runner 的可执行文件名（linux/CMakeLists.txt 的 BINARY_NAME）。
readonly APP_BINARY_NAME="linglong_store"

# 图标名必须与渲染出的 desktop 里 Icon= 字段一致，否则启动器找不到图标。
readonly APP_ICON_NAME="linglong-store"

if [[ -n "${LINGLONG_RELEASE_CONTAINER:-}" ]]; then
  echo "package-linyaps.sh 必须在宿主机上运行：ll-builder 依赖宿主的玲珑守护进程与层仓库。" >&2
  echo "发布容器里请只调用 build-linux-bundle.sh / render-packaging-templates.sh。" >&2
  exit 64
fi

release_version=""
target_arch=""
channel="stable"
base_ref="$DEFAULT_BASE_REF"
bundle_dir_override=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      release_version="$2"
      shift 2
      ;;
    --arch)
      target_arch="$2"
      shift 2
      ;;
    --channel)
      channel="$2"
      shift 2
      ;;
    --base)
      base_ref="$2"
      shift 2
      ;;
    --bundle-dir)
      bundle_dir_override="$2"
      shift 2
      ;;
    *)
      echo "Usage: $0 --version <3.7.0> --arch <amd64|arm64> [--channel stable|nightly] [--base <ref>] [--bundle-dir <dir>]" >&2
      exit 64
      ;;
  esac
done

if [[ -z "$release_version" || -z "$target_arch" ]]; then
  echo "Both --version and --arch are required." >&2
  exit 64
fi

case "$channel" in
  stable|nightly)
    ;;
  *)
    echo "Unsupported channel: $channel" >&2
    exit 64
    ;;
esac

normalize_linux_release_arch "$target_arch"

# 玲珑版本号是四段式（MAJOR.MINOR.PATCH.REVISION），仓库发布版本是三段式（3.7.0）。
# 只在这里转换一次；nightly 版本号含 "+<sha>"，不符合玲珑版本号语法，宁可失败也不
# 拼出一个装不上的包。
if [[ ! "$release_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "玲珑包版本号必须是三段式数字（如 3.7.0），当前为：$release_version" >&2
  echo "nightly 渠道的版本号带 +<sha>，需要先确定玲珑侧的版本号方案。" >&2
  exit 64
fi
linglong_version="${release_version}.0"

if ! command -v ll-builder > /dev/null 2>&1; then
  echo "找不到 ll-builder：请先在宿主机安装玲珑构建工具（linglong-builder）。" >&2
  exit 69
fi

output_dir="$ROOT_DIR/build/out/linux/$release_version/$target_arch"
stage_root="$ROOT_DIR/build/tmp/package-linyaps/$release_version-$target_arch"
payload_dir="$stage_root/payload"
share_dir="$stage_root/share"
metadata_dir="$stage_root/rendered"
manifest_path="$stage_root/linglong.yaml"
artifact_path="$output_dir/linglong-store_${release_version}_${target_arch}.uab"
icon_path="$share_dir/icons/hicolor/256x256/apps/${APP_ICON_NAME}.png"

# 暂存目录放在 build/tmp 下：ll-builder 会在工作目录里创建 linglong/ 构建状态目录，
# 若在仓库根目录直接构建就会把未跟踪的 linglong/ 留在工作树里（build/tmp 已被忽略）。
remove_stage_root() {
  [[ -e "$stage_root" ]] || return 0
  # ll-builder 的 overlay workdir 会被建成权限 0000（属主仍是当前用户），此时
  # `rm -rf` 无法遍历目录内容而失败。find 是前序遍历，会先放开目录自身再进入，
  # 因此这里先补属主权限再删；权限本身补不动时不阻断，让 rm 的失败照常暴露。
  find "$stage_root" -type d -exec chmod u+rwx {} + 2> /dev/null || true
  find "$stage_root" -type f -exec chmod u+rw {} + 2> /dev/null || true
  rm -rf -- "$stage_root"
}

remove_stage_root
mkdir -p "$payload_dir" "$share_dir"

# 1) 取得预编译产物。默认走仓库既有的发布编译链路；--bundle-dir 供 CI 复用。
bundle_dir="$bundle_dir_override"
if [[ -z "$bundle_dir" ]]; then
  "$ROOT_DIR/build/scripts/build-linux-bundle.sh" --version "$release_version" --arch "$target_arch"
  bundle_dir="$output_dir/bundle/linglong-store"
fi

if [[ ! -x "$bundle_dir/$APP_BINARY_NAME" ]]; then
  echo "预编译产物无效：$bundle_dir/$APP_BINARY_NAME 不存在或不可执行" >&2
  exit 1
fi

cp -a "$bundle_dir/." "$payload_dir/"

# 2) 渲染共享元数据。desktop 的自然语言字段由 ARB 生成器渲染，必须复用既有渲染器，
#    禁止在 linyaps 目录里另写一份 desktop 模板。
installed_size_kb="$(du -sk "$payload_dir" | cut -f1)"
"$ROOT_DIR/build/scripts/render-packaging-templates.sh" \
  --version "$release_version" \
  --arch "$target_arch" \
  --output-dir "$metadata_dir" \
  --installed-size-kb "$installed_size_kb" \
  --channel "$channel"

mapfile -t rendered_desktop_files < <(find "$metadata_dir" -maxdepth 1 -type f -name '*.desktop' | sort)
if [[ "${#rendered_desktop_files[@]}" -ne 1 ]]; then
  echo "Expected exactly one rendered desktop file in $metadata_dir, found ${#rendered_desktop_files[@]}" >&2
  exit 1
fi
desktop_filename="$(basename "${rendered_desktop_files[0]}")"

install -d "$share_dir/applications" "$share_dir/icons/hicolor/256x256/apps"

# desktop 的 Exec 必须改写成包内绝对路径：ll-builder 会把 Exec 包成
# `ll-cli run <appid> -- <Exec>`，而容器内没有 PATH 查找，裸命令名会启动失败。
# %u 保留，用于承接 og:// 安装链接（desktop 模板已注册 x-scheme-handler/og）。
sed "s|^Exec=.*|Exec=${APP_PREFIX}/${APP_BINARY_NAME} %u|" \
  "${rendered_desktop_files[0]}" > "$share_dir/applications/$desktop_filename"

rsvg-convert -w 256 -h 256 "$ROOT_DIR/assets/icons/logo.svg" -o "$icon_path"

# 3) 渲染玲珑清单。占位符替换与仓库其它渲染脚本保持同一种写法（纯字符串替换，
#    不执行模板内容）。
manifest_content="$(<"$ROOT_DIR/build/packaging/linux/linyaps/linglong.yaml.in")"
manifest_content="${manifest_content//@APPLICATION_ID@/$APPLICATION_ID}"
manifest_content="${manifest_content//@PACKAGE_NAME@/linglong-store}"
manifest_content="${manifest_content//@LINGLONG_VERSION@/$linglong_version}"
manifest_content="${manifest_content//@PACKAGE_DESCRIPTION@/玲珑应用商店社区版：浏览、安装与管理玲珑应用。}"
manifest_content="${manifest_content//@PREFIX@/$APP_PREFIX}"
manifest_content="${manifest_content//@BASE_REF@/$base_ref}"
printf '%s\n' "$manifest_content" > "$manifest_path"

cp "$ROOT_DIR/build/packaging/linux/linyaps/build.sh" "$stage_root/build.sh"

# 4) 装配。cwd 必须是暂存目录：ll-builder 把工作目录挂成容器内的 /project，
#    build.sh 依赖 /project/payload 与 /project/share 这两个固定位置。
rm -f "$artifact_path"
mkdir -p "$output_dir"

(
  cd "$stage_root"
  ll-builder build -f linglong.yaml
  # 必须用默认导出模式，它产出的是**可安装** UAB（`ll-cli install <file.uab>`）。
  # 不要加 --uabx：那是「可执行 UABX」，设计为直接运行（./xxx.uab），
  # ll-cli 安装时会直接拒绝并报
  # `Error -1: executable UAB installation is not supported`（实测）。
  # 图标随 share/icons 打进层内即可，无需 --icon（该参数仅对 --uabx 有效）。
  ll-builder export -f linglong.yaml -o "$artifact_path"
)

if [[ ! -f "$artifact_path" ]]; then
  echo "导出失败：未生成 $artifact_path" >&2
  exit 1
fi

echo "UAB 产物: $artifact_path"
echo "SHA256: $(sha256sum "$artifact_path" | cut -d' ' -f1)"
echo "安装: ll-cli install -y \"$artifact_path\""
echo "卸载: ll-cli uninstall $APPLICATION_ID"

# 同一 desktop ID 可能已被 DEB/RPM 形态占用。本机实测：DEB 版 linglong-store 3.7.0
# 已占用 /usr/share/applications/<desktop id>，玲珑安装不会覆盖它，启动器入口仍指向
# 旧形态。这里只提示，不阻断打包。
if [[ -e "/usr/share/applications/$CANONICAL_DESKTOP_ID" ]]; then
  echo "注意：/usr/share/applications/$CANONICAL_DESKTOP_ID 已存在（可能来自 DEB/RPM 安装），玲珑包不会覆盖该入口。" >&2
fi

# 诚实提示：这个包能装上、能浏览商品，但容器内没有 ll-cli，安装/卸载/更新/已装
# 列表等能力尚不可用（详见 docs/59-linyaps-uab-packaging-design.md）。
echo "注意：该产物运行时尚未接通宿主玲珑通道，应用管理能力不可用。" >&2
