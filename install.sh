!/bin/bash

USB_FILE_SIZE_MB=2048
REQUIRED_SPACE_MB=$((USB_FILE_SIZE_MB + 1024))
MOUNT_FOLDER="/mnt/usb_share"
USE_EXISTING_FOLDER="no"

COMPATIBLE_MODELS=("Raspberry Pi Zero W Rev 1.1" "Raspberry Pi Zero 2 W Rev 1.0")
HARDWARE_MODEL=$(cat /proc/device-tree/model)

is_model_compatible() {
    for model in "${COMPATIBLE_MODELS[@]}"; do
        if [[ $model == $1 ]]; then return 0; fi
    done
    return 1
}

if is_model_compatible "$HARDWARE_MODEL"; then
    echo "Detected compatible hardware: $HARDWARE_MODEL"
else
    echo "Detected hardware: $HARDWARE_MODEL"
    echo "This model is not in the known list. Continue? (y/n)"
    read continue_choice
    [[ "$continue_choice" =~ ^(y|yes)$ ]] || exit 1
fi

# Install required packages
sudo apt update && sudo apt install -y samba winbind python3-pip python3-watchdog || exit 1

# Append helper
append_text_to_file() {
    local text="$1"; local file="$2"; local id="$3"
    [[ -n "$id" && $(grep -Fxc "$id" "$file" 2>/dev/null) -ne 0 ]] && return 1
    echo "$text" | sudo tee -a "$file" >/dev/null
}

# Boot config tweaks
BOOT_DIR="/boot"; [[ -d "/boot/firmware" ]] && BOOT_DIR="/boot/firmware"
append_text_to_file "dtoverlay=dwc2" "$BOOT_DIR/config.txt" "dtoverlay=dwc2"
append_text_to_file "dwc2" "/etc/modules" "dwc2"
append_text_to_file "libcomposite" "/etc/modules" "libcomposite"
sudo modprobe dwc2 && sudo modprobe libcomposite

# cmdline.txt düzenle
if ! grep -q "modules-load=dwc2" $BOOT_DIR/cmdline.txt; then
    sudo sed -i '$ s/$/ modules-load=dwc2/' $BOOT_DIR/cmdline.txt
fi

# Mount configfs
if ! mountpoint -q /sys/kernel/config; then
    sudo mount -t configfs none /sys/kernel/config
fi

# Disable WLAN power save
sudo iw wlan0 set power_save off

# Create disk image
if [ ! -f "/piusb.bin" ]; then
    echo "Creating /piusb.bin ($USB_FILE_SIZE_MB MB)..."
    sudo dd if=/dev/zero of=/piusb.bin bs=1M count=$USB_FILE_SIZE_MB
    sudo mkfs.vfat /piusb.bin -F 32 -I
fi

# Setup mount folder
if [ ! -d "$MOUNT_FOLDER" ]; then
    sudo mkdir -p "$MOUNT_FOLDER"
    sudo chmod 777 "$MOUNT_FOLDER"
fi
append_text_to_file "/piusb.bin $MOUNT_FOLDER vfat users,umask=000 0 2" "/etc/fstab" "/piusb.bin $MOUNT_FOLDER vfat users"
sudo mount -a

# Setup Samba
samba_block=$(cat <<'EOT'
[usb]
    browseable = yes
    path = /mnt/usb_share
    guest ok = yes
    read only = no
    create mask = 777
    directory mask = 777
EOT
)
append_text_to_file "$samba_block" "/etc/samba/smb.conf" "[usb]"
sudo systemctl restart smbd

# Install usbshare.py
if [ -f "usbshare.py" ]; then
    sudo cp usbshare.py /usr/local/share/usbshare.py
    sudo chmod +x /usr/local/share/usbshare.py
else
    echo "usbshare.py not found in current directory."
    exit 1
fi

# Systemd service
usbshare_service_block=$(cat <<'EOT'
[Unit]
Description=USB Gadget Watchdog (SanDisk Emulation)
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/share/usbshare.py
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOT
)
echo "$usbshare_service_block" | sudo tee /etc/systemd/system/usbshare.service >/dev/null

# Enable & start service
sudo systemctl daemon-reexec
sudo systemctl enable usbshare.service
sudo systemctl start usbshare.service

echo "Installation complete. Reboot is recommended. Reboot now? (y/n)"
read reboot_choice
[[ "$reboot_choice" =~ ^(y|yes)$ ]] && sudo reboot
