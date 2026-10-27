#!/bin/bash
# =============================================================================
# wipe_internal.command
# Xoá sạch ổ TRONG của máy Mac (Intel, 2020 trở về trước) khi đang boot
# từ USB ngoài, để cài mới macOS cho khách.
#
#   Cách 1: Tháo hết volume, xoá các container APFS, rồi format lại
#           (tự thử thêm mẹo JHFS+ -> APFS nếu lần đầu lỗi)
#   Cách 2: Xoá bảng phân vùng (ghi 0 lên 10 MB đầu ổ) rồi format lại
#           (dùng khi cách 1 vẫn không xoá được)
#   F:      Reset Fusion Drive (iMac có SSD + HDD gộp)
#
# Cách chạy:  sudo bash wipe_internal.command
# (Trong Terminal của macOS Recovery/Installer thì đã là root, chạy bash là được)
#
# An toàn: script tự tìm ổ trong, KHÔNG dựa vào số disk0, từ chối xoá ổ
# đang boot / ổ ngoài, và bắt gõ xác nhận trước khi xoá.
# =============================================================================
set -u

NAME="Macintosh HD"

if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo bash "$0" "$@"
  else
    echo "Cần chạy bằng quyền root."; exit 1
  fi
fi

say()  { echo; echo "==> $*"; }
fail() { echo; echo "!!! $*"; }

info_field() {   # info_field <disk> <tên trường>
  diskutil info "$1" 2>/dev/null | awk -F': *' -v k="$2" '$1 ~ "^ *"k"$" {print $2; exit}'
}

# ---- Ổ vật lý đang chứa hệ điều hành đang chạy (USB boot) -------------------
boot_whole_disks() {
  local whole store
  whole="$(info_field / 'Part of Whole')"
  [ -n "$whole" ] && echo "$whole"
  # Nếu / là APFS thì whole là ổ ảo -> lấy thêm ổ vật lý bên dưới
  store="$(info_field "$whole" 'APFS Physical Store')"
  [ -z "$store" ] && store="$(diskutil apfs list 2>/dev/null | awk -v c="$whole" '
      /Container Reference:/ {ref=$NF} /^\+-- Container disk/ {ref=$3}
      /Physical Store Disk:/ && ref==c {print $NF; exit}')"
  [ -n "$store" ] && echo "$store" | sed -E 's/(disk[0-9]+).*/\1/'
}

# ---- Tìm các ổ trong (vật lý) ------------------------------------------------
find_internal_disks() {
  local d id
  for d in /dev/disk[0-9]*; do
    id="${d#/dev/}"
    [[ "$id" =~ ^disk[0-9]+$ ]] || continue          # chỉ lấy ổ nguyên, bỏ diskXsY
    local inf; inf="$(diskutil info "$id" 2>/dev/null)" || continue
    echo "$inf" | grep -Eq '^ *Internal: *Yes'           || continue
    echo "$inf" | grep -Eq '^ *Virtual: *Yes'            && continue   # ổ ảo APFS
    echo "$inf" | grep -Eq '^ *Protocol: *Disk Image'    && continue   # ramdisk Recovery
    echo "$inf" | grep -Eq 'APFS Physical Store'         && continue
    echo "$id"
  done
}

# ---- Container APFS nằm trên ổ $1 -------------------------------------------
apfs_containers_on() {
  diskutil apfs list 2>/dev/null | awk -v d="$1" '
    /Container Reference:/  {ref=$NF}
    /^\+-- Container disk/  {ref=$3}
    /Physical Store Disk:/  { if ($NF ~ "^"d"s[0-9]+$") print ref }' | sort -u
}

unmount_all() {   # tháo hết volume trên ổ $1 và các container APFS của nó
  local c
  for c in $(apfs_containers_on "$1"); do
    diskutil unmountDisk force "$c" >/dev/null 2>&1
  done
  diskutil unmountDisk force "$1"
}

do_erase() {      # format ổ $1 theo $FMT
  diskutil eraseDisk "$FMT" "$NAME" GPT "$1"
}

method1() {
  local D="$1" c
  say "Cách 1: tháo hết volume trên $D"
  unmount_all "$D"

  for c in $(apfs_containers_on "$D"); do
    say "Xoá container APFS $c"
    diskutil apfs deleteContainer "$c" || fail "Không xoá được $c (sẽ thử tiếp)"
  done

  say "Format $D -> $FMT \"$NAME\""
  if do_erase "$D"; then return 0; fi

  say "Lỗi, thử mẹo: format Mac OS Extended trước rồi format lại"
  unmount_all "$D"
  if diskutil partitionDisk "$D" 1 GPT JHFS+ "Temp" 100% && do_erase "$D"; then
    return 0
  fi
  fail "Cách 1 không thành công. Chạy lại script và chọn Cách 2."
  return 1
}

method2() {
  local D="$1"
  say "Cách 2: xoá bảng phân vùng trên $D"
  unmount_all "$D"
  dd if=/dev/zero of="/dev/r$D" bs=1m count=10 \
    || dd if=/dev/zero of="/dev/$D" bs=1m count=10 \
    || { fail "Không ghi được lên $D (ổ đang bị khoá/đang dùng)."; return 1; }
  sleep 2
  say "Format $D -> $FMT \"$NAME\""
  do_erase "$D" && return 0
  # Lần đầu đôi khi lỗi do hệ thống chưa nhận lại ổ trống -> thử lại 1 lần
  sleep 3; diskutil unmountDisk force "$D" >/dev/null 2>&1
  do_erase "$D" && return 0
  fail "Cách 2 không thành công."
  return 1
}

# =============================== MAIN ========================================
BOOT="$(boot_whole_disks | sort -u | tr '\n' ' ')"
INTERNAL=()
for d in $(find_internal_disks); do
  [[ " $BOOT " == *" $d "* ]] && continue
  INTERNAL+=("$d")
done

echo "Ổ đang boot (sẽ KHÔNG đụng tới): ${BOOT:-không rõ}"
if [ ${#INTERNAL[@]} -eq 0 ]; then
  fail "Không tìm thấy ổ trong nào. Xem: diskutil list"
  exit 1
fi

echo
echo "Ổ trong tìm thấy:"
for d in "${INTERNAL[@]}"; do
  printf "  %-7s %-10s %s\n" "$d" "$(info_field "$d" 'Disk Size' | awk '{print $1,$2}')" \
    "$(info_field "$d" 'Device / Media Name')"
done

# ---- Chọn ổ ------------------------------------------------------------------
if [ ${#INTERNAL[@]} -eq 1 ]; then
  D="${INTERNAL[0]}"
else
  echo
  echo "Có nhiều ổ trong (có thể là Fusion Drive). Gõ tên ổ cần xoá (vd: disk0),"
  read -r -p "hoặc gõ F để reset Fusion Drive: " D
  if [ "$D" = "F" ] || [ "$D" = "f" ]; then
    echo; diskutil list internal 2>/dev/null || diskutil list
    read -r -p "Reset Fusion sẽ XOÁ SẠCH các ổ trên. Gõ XOA để tiếp tục: " ok
    [ "$ok" = "XOA" ] || { echo "Huỷ."; exit 0; }
    diskutil resetFusion; diskutil list; exit $?
  fi
  [[ " ${INTERNAL[*]} " == *" $D "* ]] || { fail "$D không phải ổ trong hợp lệ."; exit 1; }
fi

echo; diskutil list "$D"

# ---- Chọn cách + định dạng ---------------------------------------------------
echo
echo "Chọn cách xoá:"
echo "  1) Tháo hết volume + xoá container APFS + format (nên thử trước)"
echo "  2) Xoá bảng phân vùng + format (khi cách 1 không được)"
read -r -p "Cách [1/2]: " M
[[ "$M" =~ ^[12]$ ]] || { echo "Huỷ."; exit 0; }

echo
echo "Định dạng sau khi xoá:"
echo "  1) APFS            (cài High Sierra trở lên)"
echo "  2) Mac OS Extended (cài Sierra trở xuống)"
read -r -p "Định dạng [1/2, mặc định 1]: " F
case "${F:-1}" in 2) FMT="JHFS+" ;; *) FMT="APFS" ;; esac

echo
echo "!!! SẼ XOÁ SẠCH $D bằng cách $M, format $FMT \"$NAME\"."
read -r -p "Gõ đúng tên ổ ($D) để xác nhận: " ok
[ "$ok" = "$D" ] || { echo "Huỷ."; exit 0; }

if [ "$M" = "1" ]; then method1 "$D"; else method2 "$D"; fi
rc=$?

echo; diskutil list "$D"
if [ $rc -eq 0 ]; then
  echo; echo "XONG: $D đã được xoá và format $FMT \"$NAME\". Thoát Terminal và cài macOS."
fi
exit $rc
