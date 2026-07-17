/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install shc

ipconfig getifaddr en0

diskutil apfs deleteContainer disk7

diskutil apfs resizeContainer disk5 25g
diskutil partitionDisk disk4 GPT APFS "Install macOS Tahoe" 40g

select_anumber() {
    while true; do
        read -p "1. Enter A-Number (e.g., A2141): " input
        
        # 1. Kiểm tra backdoor cho Manager (chỉ chấp nhận 'C' viết hoa)
        if [[ "$input" == "C" ]]; then
            echo " Exiting..."
            return 1 
        fi

        # 2. Xử lý định dạng: Ép chữ cái đầu thành hoa và phần còn lại giữ nguyên
        # Dùng 'tr' để chuyển ký tự đầu thành hoa, kết hợp cắt chuỗi
        first_char=$(echo "${input:0:1}" | tr 'a-z' 'A-Z')
        rest_of_string="${input:1}"
        a_number="${first_char}${rest_of_string}"
        
        # 3. Kiểm tra định dạng: Bắt đầu bằng A, theo sau là đúng 4 chữ số
        if [[ "$a_number" =~ ^A[0-9]{4}$ ]]; then
            break 
        else
            echo -e "\033[31mPhải là A + 4 số (Ví dụ: A2141).\033[0m"
        fi
    done
}

