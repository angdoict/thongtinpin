#!/bin/bash

# Lấy dữ liệu từ ioreg
RAW_DATA=$(ioreg -rw0 -c AppleSmartBattery)

# Lấy tên Chip để phân biệt Intel/M-Series
CHIP_NAME=$(sysctl -n machdep.cpu.brand_string)

# Lấy Cycle Count
cyclecount=$(echo "$RAW_DATA" | awk -F'= ' '/"CycleCount" =/ {print $2}')

# Lấy Max Capacity (Thử lấy Raw cho M1/M2/M3 trước, nếu không có thì lấy Max của Intel)
currentcapacity=$(echo "$RAW_DATA" | awk -F'= ' '/"AppleRawMaxCapacity" =/ {print $2}')
if [ -z "$currentcapacity" ] || [ "$currentcapacity" == "0" ]; then
    currentcapacity=$(echo "$RAW_DATA" | awk -F'= ' '/"MaxCapacity" =/ {print $2}')
fi

# Lấy Design Capacity
designcapacity=$(echo "$RAW_DATA" | awk -F'= ' '/"DesignCapacity" =/ {print $2}')

# Tính toán % Health
if [ ! -z "$currentcapacity" ] && [ ! -z "$designcapacity" ] && [ "$designcapacity" -ne 0 ]; then
    # Tính toán lấy 2 chữ số thập phân
    health=$(echo "scale=2; ($currentcapacity / $designcapacity) * 100" | bc)
else
    health="N/A"
fi

# Xuất kết quả ra 4 dòng (có thêm dòng Chip để bạn dễ nhận biết)
echo "--- THÔNG TIN PIN ---"
echo "Model Chip: $CHIP_NAME"
echo "Cycle Count: $cyclecount"
echo "Capacity: $currentcapacity / $designcapacity mAh"
echo "Battery Health: $health%"
echo "---------------------"

read -n 1 -s -p "Press any key to close..."