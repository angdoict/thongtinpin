#!/bin/bash
# =============================================================================
# disable_startup.command
# Tắt các chương trình TechTool (Micromat) tự chạy khi boot trên các ổ macOS
# gắn ngoài (USB). Không xoá gì: file .plist được dời vào
#   <volume>/Users/Shared/disabled-startup/  (giữ nguyên đường dẫn gốc bên trong)
# để có thể bật lại bằng --restore.
#
# Cách dùng:
#   sudo bash disable_startup.command                 # quét TẤT CẢ ổ ngoài đang gắn
#   sudo bash disable_startup.command MeePoCata       # chỉ 1 (hoặc vài) volume
#   sudo bash disable_startup.command -g              # tắt luôn Google Updater
#   sudo bash disable_startup.command -r MeePoCata    # bật lại (restore)
# =============================================================================
set -u
shopt -s nullglob

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
}

# Tự xin quyền root nếu chưa có
if [ "$(id -u)" -ne 0 ]; then
  exec sudo bash "$0" "$@"
fi

MODE="disable"
GOOGLE=0
VOLS=()
for a in "$@"; do
  case "$a" in
    -g|--google)  GOOGLE=1 ;;
    -r|--restore) MODE="restore" ;;
    -h|--help)    usage; exit 0 ;;
    *)            VOLS+=("$a") ;;
  esac
done

# Từ tên volume -> thư mục gốc chứa Library/Users
# Catalina trở lên: dùng "<tên> - Data" (volume ghi được); bản cũ: dùng chính volume
resolve_root() {
  local v="${1#/Volumes/}"
  v="${v%/}"
  v="${v% - Data}"
  if [ -d "/Volumes/$v - Data/Library" ]; then
    echo "/Volumes/$v - Data"
  elif [ -d "/Volumes/$v/Library" ]; then
    echo "/Volumes/$v"
  fi
}

# Không có tên volume -> tự tìm mọi ổ macOS gắn ngoài
if [ ${#VOLS[@]} -eq 0 ]; then
  for p in /Volumes/*; do
    [ -L "$p" ] && continue          # bỏ ổ đang chạy máy (Macintosh HD -> /)
    VOLS+=("$(basename "$p")")
  done
fi

# Lọc ra danh sách root, bỏ trùng
ROOTS=()
for v in "${VOLS[@]}"; do
  r="$(resolve_root "$v")"
  [ -z "$r" ] && continue
  [ -d "$r/Library/LaunchDaemons" ] || [ -d "$r/Library/LaunchAgents" ] || continue
  dup=0
  for x in "${ROOTS[@]+"${ROOTS[@]}"}"; do [ "$x" = "$r" ] && dup=1; done
  [ $dup -eq 0 ] && ROOTS+=("$r")
done

if [ ${#ROOTS[@]} -eq 0 ]; then
  echo "Không tìm thấy volume macOS nào phù hợp. Kiểm tra: ls /Volumes"
  exit 1
fi

disable_root() {
  local root="$1" dest="$1/Users/Shared/disabled-startup" n=0 f rel
  mkdir -p "$dest"
  local items=(
    "$root"/Library/LaunchDaemons/com.micromat.*.plist
    "$root"/Library/LaunchAgents/com.micromat.*.plist
    "$root"/Library/LaunchAgents/TechTool*.plist
  )
  if [ $GOOGLE -eq 1 ]; then
    items+=(
      "$root"/Library/LaunchAgents/com.google.*.plist
      "$root"/Library/LaunchDaemons/com.google.*.plist
      "$root"/Users/*/Library/LaunchAgents/com.google.*.plist
    )
  fi
  for f in "${items[@]}"; do
    [ -e "$f" ] || continue
    rel="${f#$root/}"                       # vd: Library/LaunchDaemons/x.plist
    mkdir -p "$dest/$(dirname "$rel")"
    if [ -e "$dest/$rel" ]; then
      echo "  ! Đã có bản trong disabled-startup, bỏ qua: $rel"
      continue
    fi
    mv "$f" "$dest/$rel" && echo "  - Đã tắt: $rel" && n=$((n+1))
  done
  echo "  => Tắt $n mục."
}

restore_root() {
  local root="$1" dest="$1/Users/Shared/disabled-startup" n=0 rel target
  if [ ! -d "$dest" ]; then
    echo "  Không có thư mục disabled-startup."
    return
  fi
  while IFS= read -r rel; do
    rel="${rel#./}"
    case "$rel" in
      */*)               target="$root/$rel" ;;
      TechTool*.plist)   target="$root/Library/LaunchAgents/$rel" ;;   # kiểu cũ (để phẳng)
      com.micromat.*)    target="$root/Library/LaunchDaemons/$rel" ;;
      *) echo "  ? Không biết chỗ gốc, bỏ qua: $rel"; continue ;;
    esac
    if [ -e "$target" ]; then
      echo "  ! Đã tồn tại, bỏ qua: ${target#$root/}"
      continue
    fi
    mkdir -p "$(dirname "$target")"
    mv "$dest/$rel" "$target" && echo "  + Đã bật lại: ${target#$root/}" && n=$((n+1))
  done < <(cd "$dest" && find . -type f -name '*.plist')
  echo "  => Bật lại $n mục."
}

for r in "${ROOTS[@]}"; do
  echo "== $r =="
  if [ "$MODE" = "restore" ]; then
    restore_root "$r"
  else
    disable_root "$r"
  fi
done
echo "Xong."
