#!/bin/bash
#
# hardware_check.command
# Kiểm tra nhanh: SSD, RAM, lỗi ổ đĩa, tình trạng Pin
# Chỉ dùng lệnh gốc của macOS - không cần cài thêm phần mềm
# Chạy được trên Intel T2 (A1989/A1932/A2141) và Apple Silicon (A2337/A2338)
#

line() { printf '%s\n' "------------------------------------------------------------"; }
header() { echo; line; echo "  $1"; line; }

echo "############################################################"
echo "#          KIỂM TRA PHẦN CỨNG MACBOOK (built-in)           #"
echo "#          $(date '+%Y-%m-%d %H:%M:%S')                          #"
echo "############################################################"

# ---------------------------------------------------------------
# 1. Tổng quan máy: tên model, chip, số serial, dung lượng RAM
header "1. TỔNG QUAN MÁY"
system_profiler SPHardwareDataType 2>/dev/null | \
  grep -i -E "Model Name|Model Identifier|Chip|Processor Name|Total Number of Cores|Memory|Serial Number|OS Loader"

# ---------------------------------------------------------------
# 2. RAM: trên máy mới RAM hàn chết nên chỉ xem được tổng quan
header "2. RAM"
system_profiler SPMemoryDataType 2>/dev/null
echo
echo ">> Áp lực bộ nhớ hiện tại (càng gần 'normal' càng tốt):"
memory_pressure 2>/dev/null | grep -i -E "System-wide|free percentage"

# ---------------------------------------------------------------
# 3. SSD: kiểm tra máy có nhận ổ không và trạng thái SMART
header "3. SSD / Ổ LƯU TRỮ"
echo ">> Thông tin controller NVMe (máy có nhận SSD không):"
system_profiler SPNVMeDataType 2>/dev/null | \
  grep -i -E "Capacity|Model|Serial|TRIM|Link Width|Link Speed|SMART"
echo
echo ">> Chi tiết disk0 (chú ý dòng SMART Status):"
diskutil info disk0 2>/dev/null | \
  grep -i -E "Device / Media Name|Disk Size|SMART Status|Solid State|Protocol"

# ---------------------------------------------------------------
# 4. Kiểm tra lỗi ổ đĩa - chỉ verify, không sửa
header "4. KIỂM TRA LỖI Ổ ĐĨA (filesystem)"
echo ">> Đang verify ổ hệ thống, chờ vài giây..."
diskutil verifyVolume / 2>&1 | tail -n 15

# ---------------------------------------------------------------
# 5. Pin: đọc chỉ số thô từ IORegistry và trạng thái từ system_profiler
header "5. PIN - CÓ CẦN SERVICE CHƯA?"
echo ">> Chỉ số chi tiết:"
ioreg -r -c AppleSmartBattery 2>/dev/null | \
  grep -i -E '"CycleCount"|"DesignCapacity"|"AppleRawMaxCapacity"|"MaxCapacity"|"Serial"|"Temperature"' | \
  sed 's/^[[:space:]]*|*[[:space:]]*//'
echo
echo ">> Tình trạng (Normal = tốt, Service Recommended = nên thay pin):"
system_profiler SPPowerDataType 2>/dev/null | \
  grep -i -E "Cycle Count|Condition|Maximum Capacity|Fully Charged|Charging|State of Charge"

# ---------------------------------------------------------------
# Tự tính phần trăm sức khỏe pin = dung lượng hiện tại / dung lượng thiết kế
header "   -> PHẦN TRĂM SỨC KHỎE PIN (ước tính)"
design=$(ioreg -r -c AppleSmartBattery 2>/dev/null | grep -i '"DesignCapacity"' | head -1 | sed 's/[^0-9]//g')
maxcap=$(ioreg -r -c AppleSmartBattery 2>/dev/null | grep -i '"AppleRawMaxCapacity"' | head -1 | sed 's/[^0-9]//g')
[ -z "$maxcap" ] && maxcap=$(ioreg -r -c AppleSmartBattery 2>/dev/null | grep -i '"MaxCapacity"' | head -1 | sed 's/[^0-9]//g')
if [ -n "$design" ] && [ -n "$maxcap" ] && [ "$design" -gt 0 ]; then
  health=$(( maxcap * 100 / design ))
  echo "   Thiết kế: ${design} mAh | Hiện tại: ${maxcap} mAh"
  echo "   Sức khỏe pin: ~${health}%"
  if [ "$health" -lt 80 ]; then
    echo "   => Dưới 80%: nên cân nhắc thay pin (Service)."
  else
    echo "   => Trên 80%: pin còn tốt."
  fi
else
  echo "   Không đọc được đủ số liệu để tính. Xem mục Condition ở trên."
fi

echo
line
echo "  XONG. Kéo lên trên để đọc từng mục."
line
echo
echo "Nhấn phím bất kỳ để đóng cửa sổ..."
read -n 1 -s
