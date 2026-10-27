#!/bin/bash
# ================================
# Script: Create_IMG_256GB.command
# Mục đích: Tạo image ULFO từ master macOS multi-installer 256GB (USB hoặc SSD)
# Layout master:
#   EFI | InstallCatalina | InstallBigSur | InstallMonterey |
#   APFS (MeePoSequoia) | SSN | APFS (MeePoCata) |
#   Install macOS Sequoia | Install macOS Tahoe
# ================================

# Các volume bắt buộc phải có trên master
EXPECTED_VOLUMES=(
  "InstallCatalina"
  "InstallBigSur"
  "InstallMonterey"
  "SSN"
  "Install macOS Sequoia"
  "Install macOS Tahoe"
  "MeePoSequoia"
  "MeePoCata"
)
MIN_SIZE_GB=240   # master phải lớn hơn mức này (ổ "256GB" thực tế ~250GB)

ask_continue() {
  read -p "$1 Tiếp tục? (y/N): " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "Đã huỷ."; exit 1; }
}

echo "=== DANH SÁCH DISK NGOÀI ==="
diskutil list external physical
echo ""

read -p "Nhập disk ID master (ví dụ disk2): " DISKID

# Chỉ chấp nhận dạng diskN
if ! [[ "$DISKID" =~ ^disk[0-9]+$ ]]; then
  echo "❌ Disk ID không hợp lệ (phải dạng disk2, disk3...)"
  exit 1
fi

# Kiểm tra disk tồn tại
if ! diskutil info "$DISKID" >/dev/null 2>&1; then
  echo "❌ Disk $DISKID không tồn tại"
  exit 1
fi

# Không cho chọn ổ trong của máy
if diskutil info "$DISKID" | grep -Eq "Device Location: +Internal"; then
  echo "❌ $DISKID là ổ TRONG của máy, không dùng làm master được"
  exit 1
fi

# Kiểm tra dung lượng
SIZE_BYTES=$(diskutil info "$DISKID" | awk -F'[()]' '/Disk Size/ {split($2,a," "); print a[1]; exit}')
SIZE_GB=$((SIZE_BYTES / 1000000000))
echo "💽 Dung lượng $DISKID: ${SIZE_GB} GB"
if [ "$SIZE_GB" -lt "$MIN_SIZE_GB" ]; then
  echo "⚠️  Ổ này nhỏ hơn ${MIN_SIZE_GB} GB, có vẻ không phải master 256GB."
  ask_continue ""
fi

# Tìm các APFS container nằm trên ổ (MeePoSequoia, MeePoCata)
CONTAINERS=$(diskutil list "$DISKID" | awk '/Apple_APFS/ {for(i=1;i<=NF;i++) if($i=="Container") print $(i+1)}')

# Kiểm tra đủ các phân vùng
echo ""
echo "🔍 Kiểm tra layout master..."
LAYOUT=$(diskutil list "$DISKID"; for c in $CONTAINERS; do diskutil list "$c"; done)
MISSING=0
for v in "${EXPECTED_VOLUMES[@]}"; do
  if echo "$LAYOUT" | grep -q "$v"; then
    echo "  ✅ $v"
  else
    echo "  ❌ Thiếu: $v"
    MISSING=1
  fi
done
if [ "$MISSING" -eq 1 ]; then
  ask_continue "⚠️  Master thiếu phân vùng."
fi

# Kiểm tra chỗ trống trên Desktop (tính trường hợp xấu nhất = bằng dung lượng ổ)
FREE_KB=$(df -k "$HOME/Desktop" | awk 'NR==2 {print $4}')
FREE_GB=$((FREE_KB * 1024 / 1000000000))
echo ""
echo "🗂  Desktop còn trống: ${FREE_GB} GB"
if [ "$FREE_GB" -lt "$SIZE_GB" ]; then
  ask_continue "⚠️  Chỗ trống ít hơn dung lượng ổ (${SIZE_GB} GB), image có thể không đủ chỗ."
fi

# Tên image theo ngày
DATE=$(date +"%Y-%m-%d")
IMG_NAME="macOS_multi_installer_256GB_$DATE.dmg"
IMG_PATH="$HOME/Desktop/$IMG_NAME"

if [ -e "$IMG_PATH" ]; then
  ask_continue "⚠️  Đã có $IMG_NAME trên Desktop, sẽ bị GHI ĐÈ."
fi

# Xin quyền sudo trước để không bị hỏi giữa chừng
sudo -v || exit 1

# Unmount ổ vật lý và các APFS container
echo ""
echo "🔻 Unmount $DISKID và các container: $CONTAINERS"
diskutil unmountDisk "$DISKID" || exit 1
for c in $CONTAINERS; do
  diskutil unmountDisk "$c" >/dev/null 2>&1
done

# Xác nhận không còn volume nào đang mount
PATTERN="$DISKID"
for c in $CONTAINERS; do PATTERN="$PATTERN|$c"; done
if mount | grep -Eq "^/dev/($PATTERN)s[0-9]"; then
  echo "❌ Vẫn còn volume đang mount:"
  mount | grep -E "^/dev/($PATTERN)s[0-9]"
  exit 1
fi

# Tạo image (dùng rdisk cho nhanh, caffeinate để máy không ngủ)
echo ""
echo "📦 Đang tạo image: $IMG_NAME"
echo "   Quá trình này có thể mất khá lâu..."
START=$(date +%s)
sudo caffeinate -i hdiutil create \
  -srcdevice "/dev/r$DISKID" \
  -format ULFO \
  -ov \
  "$IMG_PATH"
RC=$?
MINUTES=$(( ($(date +%s) - START) / 60 ))

if [ $RC -ne 0 ]; then
  echo "❌ Có lỗi khi tạo image (sau ${MINUTES} phút)"
  diskutil mountDisk "$DISKID" >/dev/null 2>&1
  exit 1
fi

echo "✅ Tạo image xong sau ${MINUTES} phút"

# Scan để asr restore được
echo "🔎 Đang imagescan..."
if sudo asr imagescan --source "$IMG_PATH"; then
  echo "✅ Imagescan OK"
else
  echo "❌ Imagescan lỗi, image có thể không restore bằng asr được"
fi

# Mount lại master
diskutil mountDisk "$DISKID" >/dev/null 2>&1

echo ""
echo "--------------------------"
echo "📍 Image: $IMG_PATH"
ls -lh "$IMG_PATH" | awk '{print "📏 Dung lượng image: " $5}'
