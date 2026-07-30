#!/bin/bash
# Package the SwiftPM PixShell executable into a double-clickable macOS .app.
# Usage: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/package-mac.sh [debug|release]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
APP="$ROOT/dist/PixShell.app"
# Optional override for CFBundleShortVersionString (CI tag strip / local release).
VERSION="${VERSION:-0.1.1}"
VERSION="${VERSION#v}"

# set -u 下空数组 "${BUILD_ARGS[@]}" 会炸；用显式参数列表。
BUILD_CMD=(swift build)
if [ "$CONFIG" = "release" ]; then
  BUILD_CMD+=(-c release)
elif [ "$CONFIG" = "debug" ]; then
  : # debug = 默认配置，不加 -c
else
  echo "用法: bash scripts/package-mac.sh [debug|release]" >&2
  exit 2
fi

if [ -n "${ARCH:-}" ]; then
  BUILD_CMD+=(--arch "$ARCH")
fi

echo "定位 SwiftPM $CONFIG 输出目录 ..."
BIN_DIR="$(cd "$ROOT" && "${BUILD_CMD[@]}" --show-bin-path)"
BIN="$BIN_DIR/PixShell"

if [ ! -x "$BIN" ]; then
  echo "找不到可执行文件: $BIN" >&2
  echo "先构建: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build${BUILD_ARGS:+ -c $CONFIG}" >&2
  exit 1
fi

echo "打包 $CONFIG 二进制 → $APP"
python3 - "$APP" <<'PYRM'
from pathlib import Path
import shutil, sys
p = Path(sys.argv[1])
if p.exists():
    shutil.rmtree(p)
PYRM
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PixShell"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>PixShell</string>
  <key>CFBundleIdentifier</key><string>com.pixshell.mac</string>
  <key>CFBundleName</key><string>PixShell</string>
  <key>CFBundleDisplayName</key><string>PixShell</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <!-- macOS 15+ 本地网络隐私：裸二进制连 192.168.x 会 errno 65 No route to host；
       .app + 这条 usage description 才会弹出「本地网络」授权，SSH/SFTP 才能通。 -->
  <key>NSLocalNetworkUsageDescription</key>
  <string>PixShell 需要访问局域网以连接 SSH/SFTP 主机（例如 192.168.x.x）。</string>
  <key>NSBonjourServices</key>
  <array>
    <string>_ssh._tcp</string>
    <string>_sftp-ssh._tcp</string>
  </array>
</dict>
</plist>
PLIST

# App icon for Dock / Finder / ⌘Tab (from v0.1.0 packaging assets).
ICON_SRC=""
for cand in \
  "$ROOT/Resources/AppIcon.icns" \
  "$ROOT/build/icon.icns" \
  "$ROOT/../build/icon.icns" \
  "$ROOT/../docs/assets/icon.png"
do
  if [ -f "$cand" ]; then
    ICON_SRC="$cand"
    break
  fi
done
if [ -n "$ICON_SRC" ]; then
  case "$ICON_SRC" in
    *.icns)
      cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.icns"
      ;;
    *)
      # Fallback: keep png name recognized only if no icns; prefer icns path above.
      cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null || true
      if [ ! -f "$APP/Contents/Resources/AppIcon.icns" ]; then
        echo "警告: 无法写入 AppIcon.icns（源: $ICON_SRC）" >&2
      fi
      ;;
  esac
  echo "已嵌入图标: $ICON_SRC"
else
  echo "警告: 未找到 AppIcon.icns / icon.icns，.app 将无自定义图标" >&2
fi

echo "二进制架构:"
file "$APP/Contents/MacOS/PixShell"

# SwiftPM executable resource accessors resolve bundles from Bundle.main.bundleURL,
# which is the .app root for this wrapper. Keep bundles at the .app root so
# Bundle.module works.
#
# Ad-hoc codesign（本地开发必须）：macOS 15+ 本地网络 TCC 按 code signature
# 身份记忆授权。完全 unsigned 的 .app 每次身份不稳，弹窗授权后仍可能失败。
# 正式分发再换 Developer ID + 公证；CI zip 可仍 unsigned。

# Copy SwiftPM resource bundles to the .app root to match
# DerivedSources/resource_bundle_accessor.swift.
required_bundles=(
  "PixShell_PixShell.bundle"
  "SwiftTerm_SwiftTerm.bundle"
  "swift-crypto_Crypto.bundle"
  "swift-nio_NIOPosix.bundle"
)
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
  name="$(basename "$bundle")"
  echo "复制资源 bundle: $name"
  cp -R "$bundle" "$APP/$name"
done
shopt -u nullglob

for name in "${required_bundles[@]}"; do
  if [ ! -d "$APP/$name" ]; then
    echo "缺少资源 bundle: $APP/$name" >&2
    exit 1
  fi
done

# SwiftPM 资源包默认没有 Info.plist，codesign 会报「bundle format unrecognized /
# unsealed contents present in the bundle root」。给每个 .bundle 注入最小 BNDL plist，
# 身份才能稳定，macOS 15 本地网络 TCC 才记得住「允许」。
inject_bundle_plist() {
  local bundle="$1"
  local base id
  base="$(basename "$bundle" .bundle)"
  id="com.pixshell.res.${base//_/-}"
  # 扁平 bundle（无 Contents/）+ 根级 Info.plist，是 codesign 接受的 resource bundle 形态
  if [ ! -f "$bundle/Info.plist" ] && [ ! -f "$bundle/Contents/Info.plist" ]; then
    cat > "$bundle/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>${id}</string>
  <key>CFBundleName</key><string>${base}</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
</dict>
</plist>
PLIST
    echo "已注入 bundle Info.plist: $base"
  fi
}

shopt -s nullglob
for bundle in "$APP"/*.bundle; do
  inject_bundle_plist "$bundle"
done
shopt -u nullglob

# Ad-hoc 签名：稳定 TCC 身份（本地网络授权能记住）。
#
# SwiftPM Bundle.module 要求 *.bundle 在 .app 根（与 Contents 同级）。
# 这会让 codesign 报「unsealed contents present in the bundle root」，
# 无法对 .app 做完整 seal。对策：
#   1) 先在临时路径给 Mach-O 单独 ad-hoc 签，再放进 .app（避免从 bundle 内签被父级连坐）
#   2) 每个 *.bundle 单独签
#   3) .app 级签名允许失败；本地网络 TCC 主要跟主可执行文件身份走
# 稳定 codesign 身份：优先复用 login keychain 里的 "PixShell Local" 自签证书。
# ad-hoc（codesign -s -）每次 CDHash 都变 → 本地网络 TCC 授权每次 rebuild 丢失。
# 自签证书跨 rebuild CDHash 稳定（同一证书），Keychain ACL / TCC 才能记住。
#
# 注意：自签未进 trust settings 时，`security find-identity -v` 会报
# CSSMERR_TP_NOT_TRUSTED → "0 valid identities"，但 `codesign --sign <SHA-1>`
# 仍可用（无需 sudo / 用户交互 trust）。多份 "PixShell Local" 时以
# identity.hash 锁定同一份，避免 rebuild 换证书。
# 清理重复证书（Keychain Access 手动删多余项）可选，本脚本不自动删除。
ensure_local_sign_identity() {
  local name="PixShell Local"
  local dir="${HOME}/Library/Application Support/PixShell/codesign"
  local hash_file="$dir/identity.hash"
  local identity_list hashes preferred h line
  mkdir -p "$dir"

  # 收集所有 "PixShell Local" 的 SHA-1（含 untrusted；-v 只列 valid，会漏）。
  # 行格式:  1) HASH "PixShell Local" [(CSSMERR_...)]
  identity_list="$(security find-identity -p codesigning 2>/dev/null || true)"
  hashes=()
  while IFS= read -r line; do
    case "$line" in
      *\"$name\"*)
        h="$(printf '%s\n' "$line" | sed -n 's/.*\([0-9A-Fa-f]\{40\}\).*/\1/p')"
        if [ -n "$h" ]; then
          hashes+=("$h")
        fi
        ;;
    esac
  done <<< "$identity_list"

  # 1) 有效身份（-v）：若有同名 valid，优先用名字（系统认可）。
  if security find-identity -v -p codesigning 2>/dev/null | grep -F "\"$name\"" >/dev/null 2>&1; then
    # 仍把 hash 持久化（多份 valid 时锁定）
    preferred=""
    if [ -f "$hash_file" ]; then
      preferred="$(tr -d '[:space:]' < "$hash_file" | tr '[:lower:]' '[:upper:]')"
    fi
    if [ -n "$preferred" ]; then
      for h in "${hashes[@]+"${hashes[@]}"}"; do
        if [ "$(printf '%s' "$h" | tr '[:lower:]' '[:upper:]')" = "$preferred" ]; then
          printf '%s\n' "$h" > "$hash_file"
          echo "$h"
          return 0
        fi
      done
    fi
    if [ "${#hashes[@]}" -gt 0 ]; then
      h="${hashes[0]}"
      printf '%s\n' "$h" > "$hash_file"
      echo "$h"
      return 0
    fi
    # 有 valid 名字但解析不出 hash：回落用名字（codesign 能解析 common name）
    echo "$name"
    return 0
  fi

  # 2) 无 valid：用 SHA-1 签 untrusted 自签（已验证 codesign --sign HASH 成功）。
  if [ "${#hashes[@]}" -gt 0 ]; then
    preferred=""
    if [ -f "$hash_file" ]; then
      preferred="$(tr -d '[:space:]' < "$hash_file" | tr '[:lower:]' '[:upper:]')"
    fi
    if [ -n "$preferred" ]; then
      for h in "${hashes[@]}"; do
        if [ "$(printf '%s' "$h" | tr '[:lower:]' '[:upper:]')" = "$preferred" ]; then
          printf '%s\n' "$h" > "$hash_file"
          # bash 3.2: 用 ${h}，避免 $h 紧贴全角括号被误解析
          echo "提示: 使用持久化 identity.hash=${h} (CSSMERR_TP_NOT_TRUSTED 仍可 hash 签名)" >&2
          echo "$h"
          return 0
        fi
      done
      echo "提示: identity.hash=${preferred} 不在当前 keychain，改选可用 PixShell Local" >&2
    fi
    # 多份时取列表第一条（find-identity 顺序稳定即可；不自动删重复）
    h="${hashes[0]}"
    if [ "${#hashes[@]}" -gt 1 ]; then
      echo "提示: 发现 ${#hashes[@]} 个 PixShell Local 证书（重复未自动删除）。锁定: ${h}" >&2
      echo "      可选清理: Keychain Access -> 登录 -> 证书 -> 删多余 PixShell Local；保留 identity.hash 对应项。" >&2
    fi
    printf '%s\n' "$h" > "$hash_file"
    echo "提示: 使用 SHA-1 身份 ${h} 签名（未 trust 的自签；无需 sudo）" >&2
    echo "$h"
    return 0
  fi

  # 3) 没有现成身份：生成自签 p12 并导入 login keychain，再取 hash。
  local key="$dir/pixshell-local.key"
  local crt="$dir/pixshell-local.crt"
  local p12="$dir/pixshell-local.p12"
  local conf="$dir/openssl.cnf"
  if [ ! -f "$p12" ]; then
    cat > "$conf" <<'EOF'
[ req ]
distinguished_name = req_distinguished_name
x509_extensions = v3_code_signing
prompt = no
[ req_distinguished_name ]
CN = PixShell Local
O = PixShell
[ v3_code_signing ]
basicConstraints = CA:FALSE
keyUsage = digitalSignature
extendedKeyUsage = codeSigning
EOF
    openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
      -keyout "$key" -out "$crt" -config "$conf" >/dev/null 2>&1 || return 1
    openssl pkcs12 -export -inkey "$key" -in "$crt" -out "$p12" \
      -passout pass:pixshell-local -name "$name" >/dev/null 2>&1 || return 1
  fi
  security import "$p12" -k ~/Library/Keychains/login.keychain-db \
    -P pixshell-local -T /usr/bin/codesign -T /usr/bin/security >/dev/null 2>&1 || true
  # 允许 codesign 不弹钥匙串（尽量；空密码 keychain 才有效）
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" \
    ~/Library/Keychains/login.keychain-db >/dev/null 2>&1 || true

  identity_list="$(security find-identity -p codesigning 2>/dev/null || true)"
  hashes=()
  while IFS= read -r line; do
    case "$line" in
      *\"$name\"*)
        h="$(printf '%s\n' "$line" | sed -n 's/.*\([0-9A-Fa-f]\{40\}\).*/\1/p')"
        if [ -n "$h" ]; then
          hashes+=("$h")
        fi
        ;;
    esac
  done <<< "$identity_list"

  if [ "${#hashes[@]}" -gt 0 ]; then
    preferred=""
    if [ -f "$hash_file" ]; then
      preferred="$(tr -d '[:space:]' < "$hash_file" | tr '[:lower:]' '[:upper:]')"
    fi
    if [ -n "$preferred" ]; then
      for h in "${hashes[@]}"; do
        if [ "$(printf '%s' "$h" | tr '[:lower:]' '[:upper:]')" = "$preferred" ]; then
          printf '%s\n' "$h" > "$hash_file"
          echo "$h"
          return 0
        fi
      done
    fi
    h="${hashes[0]}"
    printf '%s\n' "$h" > "$hash_file"
    echo "$h"
    return 0
  fi

  # 最后：若 valid 列表里有名字（罕见），仍回落名字
  if security find-identity -v -p codesigning 2>/dev/null | grep -F "\"$name\"" >/dev/null 2>&1; then
    echo "$name"
    return 0
  fi
  return 1
}

print_cdhash() {
  local target="$1"
  local label="${2:-}"
  local info cdhash
  info="$(codesign -dv --verbose=2 "$target" 2>&1 || true)"
  cdhash="$(printf '%s\n' "$info" | sed -n 's/^CDHash=//p' | head -1)"
  if [ -n "$cdhash" ]; then
    echo "CDHash${label:+ ($label)}: $cdhash"
  else
    echo "CDHash${label:+ ($label)}: (未读到)" >&2
  fi
}

if command -v codesign >/dev/null 2>&1; then
  SIGN_ID="-"
  # ensure 可能混进提示行：只取 40 位 hex 或字面名，避免 set -u / 多行污染
  if RAW_ID="$(ensure_local_sign_identity 2>/tmp/pixshell-ensure-id.err)"; then
    # BSD sed 不支持 GNU `t;` 链式分支；分两步：先抽 40 位 hex，否则 trim 后认字面名
    LOCAL_ID="$(printf '%s\n' "$RAW_ID" | sed -n 's/.*\([0-9A-Fa-f]\{40\}\).*/\1/p' | head -1)"
    if [ -z "$LOCAL_ID" ]; then
      LOCAL_ID="$(printf '%s\n' "$RAW_ID" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -Fx 'PixShell Local' | head -1 || true)"
    fi
    if [ -n "$LOCAL_ID" ]; then
      SIGN_ID="$LOCAL_ID"
      echo "codesign 使用稳定身份: ${SIGN_ID} (钥匙串/TCC 可跨 rebuild 记住)"
      cat /tmp/pixshell-ensure-id.err 2>/dev/null || true
    else
      echo "警告: ensure 返回无法解析: $(printf '%s' "$RAW_ID" | tr '\n' ' ')" >&2
      cat /tmp/pixshell-ensure-id.err 2>/dev/null || true
    fi
  else
    echo "警告: 无法创建/定位 PixShell Local 证书，回退 ad-hoc" >&2
    cat /tmp/pixshell-ensure-id.err 2>/dev/null || true
  fi
  sign_ok=1

  # 主可执行：拷到 /tmp 再签，再写回（绕过 .app 根 unsealed 连坐）
  tmp_bin="$(mktemp -t PixShell.XXXXXX)"
  cp "$APP/Contents/MacOS/PixShell" "$tmp_bin"
  chmod +x "$tmp_bin"
  if codesign --force --sign "$SIGN_ID" --timestamp=none --identifier com.pixshell.mac "$tmp_bin" 2>/tmp/pixshell-codesign.err; then
    cp "$tmp_bin" "$APP/Contents/MacOS/PixShell"
    chmod +x "$APP/Contents/MacOS/PixShell"
    echo "主可执行签名 OK (id=com.pixshell.mac, identity=$SIGN_ID)"
    if [ "$SIGN_ID" != "-" ]; then
      print_cdhash "$APP/Contents/MacOS/PixShell" "main"
    fi
  else
    echo "警告: 可执行文件签名失败，尝试 ad-hoc…" >&2
    cat /tmp/pixshell-codesign.err >&2 || true
    if codesign --force --sign - --timestamp=none --identifier com.pixshell.mac "$tmp_bin" 2>/tmp/pixshell-codesign.err; then
      cp "$tmp_bin" "$APP/Contents/MacOS/PixShell"
      chmod +x "$APP/Contents/MacOS/PixShell"
      SIGN_ID="-"
      echo "主可执行 ad-hoc 回退 OK"
    else
      sign_ok=0
    fi
  fi
  rm -f "$tmp_bin"

  shopt -s nullglob
  for bundle in "$APP"/*.bundle; do
    [ -e "$bundle" ] || continue
    if ! codesign --force --sign "$SIGN_ID" --timestamp=none "$bundle" 2>/tmp/pixshell-codesign.err; then
      codesign --force --sign - --timestamp=none "$bundle" 2>/dev/null || true
      echo "警告: bundle 签名降级: $(basename "$bundle")" >&2
    else
      echo "bundle 签名 OK: $(basename "$bundle")"
    fi
  done
  shopt -u nullglob

  if codesign --force --sign "$SIGN_ID" --timestamp=none "$APP" 2>/tmp/pixshell-codesign.err; then
    echo ".app 级签名 OK ($SIGN_ID)"
    if [ "$SIGN_ID" != "-" ]; then
      print_cdhash "$APP" "app"
    fi
  else
    echo "提示: .app 级签名跳过（根级 SwiftPM .bundle 导致 unsealed；主二进制已单独签）" >&2
    head -5 /tmp/pixshell-codesign.err >&2 || true
  fi

  echo "---- codesign -dv (main binary) ----"
  codesign -dv --verbose=2 "$APP/Contents/MacOS/PixShell" 2>&1 | head -20 || true
  echo "---- codesign -dv (.app, may be unsigned) ----"
  codesign -dv --verbose=2 "$APP" 2>&1 | head -10 || true
  if [ "$sign_ok" = 1 ]; then
    # 用 ${SIGN_ID:--} 避免 set -u 下 SIGN_ID 偶发未绑定（子 shell/回退路径）
    echo "codesign 完成 identity=${SIGN_ID:--}（稳定身份可减少钥匙串反复授权）"
  else
    echo "警告: 部分签名失败" >&2
  fi

  if [ "${SIGN_ID:--}" = "-" ]; then
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
    echo "!! 警告: codesign 最终为 ad-hoc（SIGN_ID=-）" >&2
    echo "!! adhoc CDHash 每次 rebuild 会变，本地网络授权会丢" >&2
    echo "!! 修复: 确保 login keychain 有 \"PixShell Local\" 并保留" >&2
    echo "!!   ~/Library/Application Support/PixShell/codesign/identity.hash" >&2
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
    if [ "${REQUIRE_STABLE_SIGN:-0}" = "1" ]; then
      echo "REQUIRE_STABLE_SIGN=1：拒绝 ad-hoc，退出 1" >&2
      exit 1
    fi
  fi
else
  echo "警告: 无 codesign，跳过签名" >&2
  if [ "${REQUIRE_STABLE_SIGN:-0}" = "1" ]; then
    echo "REQUIRE_STABLE_SIGN=1：无 codesign，退出 1" >&2
    exit 1
  fi
fi

echo "完成: $APP (version ${VERSION})"
echo "资源 bundle 在 .app 根（SwiftPM Bundle.module）+ 已注入 Info.plist 可 ad-hoc 签。"
echo "本地网络：Info.plist usage + NWBrowser 弹窗 + 帮助「一键打开授权设置」。"
echo "双击运行，或: open \"$APP\""
