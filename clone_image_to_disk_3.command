#!/bin/bash
#================================================================
#  clone_image_to_disk_3.command   —   MeePo Tek
#  Clone 1 image macOS nhiều phan vung sang 1 disk dich,
#  TU DONG doc layout cua image (ten/size that su — khong
#  hard-code gi ca), nen chay dung cho image doi nay va sau nay.
#
#  Source : .dmg / .sparseimage / .img tren ~/Desktop
#  Target : 1 disk NGOAI (hoac 1 sparseimage ao de TEST truoc)
#
#  Cach clone tung phan vung:
#     Apple_HFS   -> dd               (raw)
#     EFI         -> dd               (raw, bat/tat bang CLONE_EFI)
#     Apple_Boot  -> dd               (raw)
#     Apple_APFS  -> dd + resize      (nở đầy ổ)
#
#  v3 (2026-10-25):
#   - phan vung dich tao dang KHONG FORMAT, dung loai cua image
#     (%Apple_HFS% / %Apple_Boot% / %Apple_APFS%) -> khong auto-mount,
#     het "Resource busy", Apple_Boot giu dung loai
#   - bo asr: asr tu cat phan vung de tao Recovery (Apple_Boot) -> lech layout
#   - dem loi; co loi thi KHONG bao "HOAN TAT"
#   - resize APFS tu dong: thu "0", loi -69743 thi resize ve size cu the
#     (partition - 1GB); van loi moi nhac rut/cam lai
#================================================================
set -u

# ---- tuy chinh ------------------------------------------------
PAD_BYTES=524288000     # +500MB dem cho moi phan vung (tru APFS cuoi)
CLONE_EFI=1             # 1 = clone noi dung EFI; 0 = de EFI trong (diskutil tu tao)
# --------------------------------------------------------------

RED=$'\033[31;1m'; GRN=$'\033[32;1m'; YEL=$'\033[33;1m'; CYN=$'\033[36;1m'; NC=$'\033[0m'
say()  { echo -e "${CYN}$*${NC}"; }
ok()   { echo -e "${GRN}$*${NC}"; }
warn() { echo -e "${YEL}$*${NC}"; }
die()  { echo -e "${RED}$*${NC}" >&2; exit 1; }
FAILS=()
fail() { echo -e "${RED}   ! $*${NC}"; FAILS+=("$*"); }

# 0. sudo
if [[ $EUID -ne 0 ]]; then
  exec sudo "$0" "$@"
fi
SUDO_HOME=$(eval echo "~${SUDO_USER:-$USER}")

# helper: doc 1 khoa trong plist cua `diskutil info`
dkey() { # <device> <PlistKey>
  local t; t=$(mktemp)
  diskutil info -plist "$1" > "$t" 2>/dev/null
  plutil -extract "$2" raw -o - "$t" 2>/dev/null
  rm -f "$t"
}
# liet ke cac slice (diskNsM) cua 1 whole disk, dung thu tu
list_slices() { # <wholeDisk>
  diskutil list "$1" | awk '$NF ~ /^disk[0-9]+s[0-9]+$/ {print $NF}'
}

#================================================================
# 1. Chon file image
#================================================================
echo "=== IMAGE TREN DESKTOP ==="
ls "$SUDO_HOME/Desktop/"*.dmg "$SUDO_HOME/Desktop/"*.sparseimage "$SUDO_HOME/Desktop/"*.img 2>/dev/null
echo ""
read -r -p "Ten file image: " IMAGE
IMAGE_PATH="$SUDO_HOME/Desktop/$IMAGE"
[[ -f "$IMAGE_PATH" ]] || die "X Khong thay file: $IMAGE_PATH"

say "* Dang attach image (read-only, khong mount)..."
ATT=$(hdiutil attach -nomount -noverify -readonly "$IMAGE_PATH") || die "X Attach that bai."
IMG_DEV=$(echo "$ATT" | awk '/GUID_partition_scheme/{print $1; exit}')
[[ -n "$IMG_DEV" ]] || { echo "$ATT"; die "X Khong thay GUID_partition_scheme trong image."; }
IMG_DISK=${IMG_DEV#/dev/}
ok "# Image dang o: /dev/$IMG_DISK"
echo ""
diskutil list "/dev/$IMG_DISK"
echo ""

#================================================================
# 2. Chon disk dich
#================================================================
echo "=== DISK NGOAI / AO ==="
diskutil list external physical 2>/dev/null | grep "/dev/disk"
echo ""
read -r -p "Nhap disk DICH (vi du disk6): " TGT
TGT=${TGT#/dev/}
[[ "$TGT" =~ ^disk[0-9]+$ ]] || die "X Dinh dang sai, can kieu diskN (vd disk6)."

# ---- AN TOAN: khong xoa nham o he thong ----
[[ "$TGT" == "$IMG_DISK" ]] && die "X Dich trung voi image. Huy."
BOOT_WHOLE=$(diskutil info / 2>/dev/null | awk -F: '/Part of Whole/{gsub(/[[:space:]]/,"",$2);print $2}')
[[ "$TGT" == "$BOOT_WHOLE" ]] && die "X $TGT la o dang chay macOS. TUYET DOI khong. Huy."
LOC=$(diskutil info "/dev/$TGT" 2>/dev/null | awk -F: '/Device Location/{gsub(/^[ \t]+/,"",$2);print $2}')
[[ "$LOC" == "Internal" ]] && die "X $TGT la o Internal. Huy de an toan."

echo ""
diskutil list "/dev/$TGT"
echo ""
TGT_SIZE=$(dkey "/dev/$TGT" Size)
[[ -n "$TGT_SIZE" ]] || die "X Khong doc duoc dung luong dich."

#================================================================
# 3. Doc layout image -> mang
#================================================================
SRC=(); C_CONTENT=(); C_SIZE=(); C_NAME=()
while IFS= read -r s; do
  SRC+=("$s")
  C_CONTENT+=("$(dkey "/dev/$s" Content)")
  C_SIZE+=("$(dkey "/dev/$s" Size)")
  C_NAME+=("$(dkey "/dev/$s" VolumeName)")
done < <(list_slices "/dev/$IMG_DISK")
[[ ${#SRC[@]} -gt 0 ]] || die "X Khong doc duoc phan vung nao tu image."

# cac phan vung se tao (bo EFI vi GPT tu tao)
NONEFI_IDX=()
for i in "${!SRC[@]}"; do
  [[ "${C_CONTENT[$i]}" == "EFI" ]] && continue
  NONEFI_IDX+=("$i")
done
LAST_POS=$(( ${#NONEFI_IDX[@]} - 1 ))

# build args cho partitionDisk + kiem tra tong dung luong
PARGS=(); TOTAL=0; pos=0
for i in "${NONEFI_IDX[@]}"; do
  c="${C_CONTENT[$i]}"; nm="${C_NAME[$i]}"; sz="${C_SIZE[$i]}"
  # Tao MOI phan vung o dang KHONG format, giu dung loai cua image
  # (%Apple_HFS%, %Apple_Boot%, %Apple_APFS%...). macOS khong tu mount gi ca,
  # dd ghi vao khong bi "Resource busy", va Apple_Boot giu dung loai Apple_Boot.
  fmt="%${c}%"
  [[ -n "$nm" ]] || nm="Part$((pos+1))"
  if [[ $pos -eq $LAST_POS ]]; then
    tok="0b"                     # phan vung cuoi: lap day o
  else
    tok="$(( sz + PAD_BYTES ))b"
  fi
  TOTAL=$(( TOTAL + sz + PAD_BYTES ))
  PARGS+=( "$fmt" "$nm" "$tok" )
  pos=$(( pos + 1 ))
done
[[ $TOTAL -lt $TGT_SIZE ]] || die "X O dich ($TGT_SIZE B) nho hon tong can ($TOTAL B). Huy."

#================================================================
# 4. Xac nhan
#================================================================
echo "=============================================================="
warn "SE XOA TOAN BO /dev/$TGT va tao layout:"
echo "   - EFI (tao tu dong)"
pos=0
for i in "${NONEFI_IDX[@]}"; do
  if [[ $pos -eq $LAST_POS ]]; then fill="  [lap day]"; else fill=""; fi
  echo "   - ${C_CONTENT[$i]}  '${C_NAME[$i]}'  (${C_SIZE[$i]} B)$fill"
  pos=$((pos+1))
done
echo "=============================================================="
echo "Lenh: diskutil partitionDisk /dev/$TGT GPT ${PARGS[*]}"
echo ""
read -r -p "Go dung '$TGT' de xac nhan XOA va clone: " CONF
[[ "$CONF" == "$TGT" ]] || die "X Khong khop. Huy."

#================================================================
# 5. Tao phan vung
#================================================================
say "* Dang phan vung /dev/$TGT ..."
diskutil partitionDisk "/dev/$TGT" GPT "${PARGS[@]}" || die "X partitionDisk loi."

TGTS=()
while IFS= read -r s; do TGTS+=("$s"); done < <(list_slices "/dev/$TGT")
[[ ${#TGTS[@]} -ge $(( ${#NONEFI_IDX[@]} + 1 )) ]] || die "X So phan vung dich khong khop."

#================================================================
# 6. Clone tung phan vung
#================================================================
nef=0
for i in "${!SRC[@]}"; do
  s="${SRC[$i]}"; c="${C_CONTENT[$i]}"; nm="${C_NAME[$i]}"
  if [[ "$c" == "EFI" ]]; then
    t="${TGTS[0]}"
    if [[ "$CLONE_EFI" == "1" ]]; then
      say ">> EFI  $s -> $t (dd)"
      diskutil unmount "/dev/$t" >/dev/null 2>&1
      dd if="/dev/r$s" of="/dev/r$t" bs=4m 2>/dev/null && ok "   OK EFI" || warn "   ! EFI dd loi (bo qua)"
    else
      warn "~ Bo qua EFI (de trong)."
    fi
    continue
  fi
  t="${TGTS[$(( nef + 1 ))]}"; nef=$(( nef + 1 ))
  case "$c" in
    Apple_HFS)
      # KHONG dung asr: voi volume co Recovery (Apple_Boot) di kem, asr tu y
      # cat nho phan vung dich de tao them Apple_Boot -> lech het layout.
      # dd raw: chep nguyen khoi, layout giu dung nhu image.
      say ">> HFS  '$nm'  $s -> $t (dd)  — Ctrl-T xem tien do"
      diskutil unmount force "/dev/$t" >/dev/null 2>&1
      dd if="/dev/r$s" of="/dev/r$t" bs=4m && ok "   OK $nm" || fail "HFS '$nm' dd loi ($s -> $t)"
      ;;
    Apple_Boot)
      say ">> Boot $s -> $t (dd)  — Ctrl-T xem tien do"
      diskutil unmount "/dev/$t" >/dev/null 2>&1
      dd if="/dev/r$s" of="/dev/r$t" bs=4m && ok "   OK Boot" || fail "Boot dd loi ($s -> $t)"
      ;;
    Apple_APFS)
      say ">> APFS '$nm'  $s -> $t (dd + resize)  — Ctrl-T xem tien do"
      # neu lo co container (vd chay script cu) -> thao het volume cua no truoc
      cont=$(dkey "/dev/$t" APFSContainerReference)
      [[ -n "$cont" ]] && diskutil unmountDisk force "/dev/$cont" >/dev/null 2>&1
      diskutil unmount force "/dev/$t" >/dev/null 2>&1
      if ! dd if="/dev/r$s" of="/dev/r$t" bs=4m; then
        fail "dd APFS loi ($s -> $t) — bo qua resize"
        continue
      fi
      ok "   OK dd container"
      sync
      # cho macOS doc lai container moi vua ghi
      diskutil unmountDisk force "/dev/$TGT" >/dev/null 2>&1
      diskutil mountDisk "/dev/$TGT" >/dev/null 2>&1
      sleep 3
      say "   ... resize container lap day o"
      # Sau khi dd, "resizeContainer 0" hay bao -69743 (size giong nhau) vi
      # diskutil lay size partition lam moc. Meo: resize ve 1 size CU THE
      # (nho hon partition 1GB) -> APFS nhan va no container ra.
      PSIZE=$(dkey "/dev/$t" Size)
      RS_G=$(( ${PSIZE:-0} / 1000000000 - 1 ))
      RESIZE_T="$t"; RESIZE_G="$RS_G"
      if diskutil apfs resizeContainer "$t" 0 >/dev/null 2>&1; then
        ok "   OK resize (lap day)"
      elif [[ $RS_G -gt 0 ]] && diskutil apfs resizeContainer "$t" "${RS_G}g"; then
        ok "   OK resize -> ${RS_G}GB"
      else
        NEED_RESIZE=1
        warn "   ~ macOS chua nhan container moi -> resize sau khi rut/cam lai o (xem cuoi)"
      fi
      ;;
    *)
      say ">> $c  $s -> $t (dd)"
      diskutil unmount "/dev/$t" >/dev/null 2>&1
      dd if="/dev/r$s" of="/dev/r$t" bs=4m && ok "   OK" || fail "$c dd loi ($s -> $t)"
      ;;
  esac
done

#================================================================
# 7. Don dep + ket qua
#================================================================
say "* Thao image..."
hdiutil detach "/dev/$IMG_DISK" >/dev/null 2>&1
echo ""
if [[ ${#FAILS[@]} -gt 0 ]]; then
  echo -e "${RED}X CLONE CHUA XONG — ${#FAILS[@]} loi:${NC}"
  for f in "${FAILS[@]}"; do echo -e "${RED}   - $f${NC}"; done
  echo "  Kiem tra:  diskutil list /dev/$TGT"
  exit 1
fi
ok "V CLONE XONG! /dev/$TGT khong co loi."
if [[ "${NEED_RESIZE:-0}" == "1" ]]; then
  warn ">> CON 1 BUOC: rut o ra, cam lai, roi chay (doi so disk neu bi doi):"
  echo "     diskutil list external"
  echo "     sudo diskutil apfs resizeContainer ${RESIZE_T:-diskNsM} ${RESIZE_G:-<size>}g"
fi
echo "  Kiem tra:  diskutil list /dev/$TGT"
