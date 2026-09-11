#!/bin/bash

set -e  # Exit on any error

# Color output for readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  SteamOS Installation Script               ║${NC}"
echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
echo ""

# ===========================
# CONFIGURATION PROMPTS
# ===========================

echo -e "${BLUE}=== Configuration ===${NC}"
echo ""

# WiFi Configuration
echo -e "${YELLOW}Network Configuration${NC}"
read -p "Configure WiFi? (y/n) [default: y]: " CONFIGURE_WIFI
CONFIGURE_WIFI=${CONFIGURE_WIFI:-y}

if [[ "$CONFIGURE_WIFI" == "y" ]]; then
    read -p "WiFi SSID: " WIFI_SSID
    read -sp "WiFi Password: " WIFI_PASSWORD
    echo ""
else
    echo -e "${GREEN}Skipping WiFi configuration (assuming wired connection)${NC}"
    WIFI_SSID=""
    WIFI_PASSWORD=""
fi
echo ""

# Disk Selection
echo ""
echo -e "${YELLOW}Available disks:${NC}"
lsblk -d -o NAME,SIZE,MODEL | grep -v "loop\|rom"
echo ""
read -p "Target disk (e.g., nvme0n1, sda): " DISK_NAME
DISK="/dev/${DISK_NAME}"

if [ ! -b "$DISK" ]; then
    echo -e "${RED}Error: Disk $DISK does not exist!${NC}"
    exit 1
fi

# SteamOS Version
echo ""
echo -e "${YELLOW}SteamOS Version${NC}"
echo -e "${YELLOW}Note: 3.8 is non-functional (kernel/repo issues) — use 3.8.1x instead.${NC}"
read -p "SteamOS version (e.g., 3.5, 3.6, 3.7, 3.8.1x, 3.9) [default: 3.8.1x]: " STEAMOS_VERSION
STEAMOS_VERSION=${STEAMOS_VERSION:-3.8.1x}
# Normalize to lowercase so "3.8.1X" and "3.8.1x" are treated the same
STEAMOS_VERSION=$(echo "$STEAMOS_VERSION" | tr '[:upper:]' '[:lower:]')

# Timezone
echo ""
echo -e "${YELLOW}Timezone Configuration${NC}"
echo "Examples: America/New_York, Europe/London, Asia/Tokyo, Asia/Manila"
read -p "Timezone [default: Asia/Manila]: " TIMEZONE
TIMEZONE=${TIMEZONE:-Asia/Manila}

# Verify timezone exists
if [ ! -f "/usr/share/zoneinfo/$TIMEZONE" ]; then
    echo -e "${RED}Warning: Timezone $TIMEZONE not found. Using UTC${NC}"
    TIMEZONE="UTC"
fi

# Hostname
echo ""
echo -e "${YELLOW}System Configuration${NC}"
read -p "Hostname [default: steamdeck]: " HOSTNAME
HOSTNAME=${HOSTNAME:-steamdeck}

# Username
read -p "Username [default: deck]: " USERNAME
USERNAME=${USERNAME:-deck}

# Swap Size
if [[ "$STEAMOS_VERSION" == "3.9" ]]; then
    SWAP_SIZE=""
    echo -e "${GREEN}Skipping swap configuration for SteamOS 3.9${NC}"
else
    echo ""
    echo -e "${YELLOW}Swap Configuration${NC}"
    echo "Enter swap file size in GB (just the number)"
    echo "Examples: 8, 16, 32"

    while true; do
        read -p "Swap file size in GB [default: 8]: " SWAP_SIZE_GB
        SWAP_SIZE_GB=${SWAP_SIZE_GB:-8}
        
        # Validate it's a number
        if [[ "$SWAP_SIZE_GB" =~ ^[0-9]+$ ]]; then
            SWAP_SIZE="${SWAP_SIZE_GB}g"
            echo -e "Swap size set to: ${GREEN}${SWAP_SIZE}${NC}"
            break
        else
            echo -e "${RED}Please enter a valid number (e.g., 8, 16, 32)${NC}"
        fi
    done
fi

# NoMachine
echo ""
echo -e "${YELLOW}Optional Software${NC}"
read -p "Install NoMachine remote desktop? Note: Doesn't work in 3.8.1x and 3.9 due to Wayland. (y/n) [default: n]: " INSTALL_NOMACHINE
INSTALL_NOMACHINE=${INSTALL_NOMACHINE:-n}

# Confirmation
echo ""
echo -e "${BLUE}=== Configuration Summary ===${NC}"
echo -e "WiFi SSID:        ${GREEN}$WIFI_SSID${NC}"
echo -e "Target Disk:      ${GREEN}$DISK${NC}"
echo -e "SteamOS Version:  ${GREEN}$STEAMOS_VERSION${NC}"
echo -e "Timezone:         ${GREEN}$TIMEZONE${NC}"
echo -e "Hostname:         ${GREEN}$HOSTNAME${NC}"
echo -e "Username:         ${GREEN}$USERNAME${NC}"
echo -e "Swap Size:        ${GREEN}$SWAP_SIZE${NC}"
echo -e "NoMachine:        ${GREEN}$INSTALL_NOMACHINE${NC}"
echo ""
echo -e "${RED}WARNING: ALL DATA ON $DISK WILL BE PERMANENTLY ERASED!${NC}"
echo ""
read -p "Proceed with installation? Type 'YES' to continue: " FINAL_CONFIRM

if [ "$FINAL_CONFIRM" != "YES" ]; then
    echo -e "${YELLOW}Installation cancelled${NC}"
    exit 0
fi

# ===========================
# FUNCTIONS
# ===========================

setup_wifi() {
    echo -e "${GREEN}Setting up WiFi...${NC}"
    
    # Configure iwd
    cat > /etc/iwd/main.conf <<EOF
[General]
EnableNetworkConfiguration=true
EOF

    systemctl restart iwd
    sleep 3
    
    # Wait for wireless interface
    echo -e "${YELLOW}Waiting for wireless interface...${NC}"
    timeout=30
    while ! iwctl device list 2>/dev/null | grep -q "wlan0" && [ $timeout -gt 0 ]; do
        sleep 1
        ((timeout--))
    done
    
    if [ $timeout -eq 0 ]; then
        echo -e "${RED}Error: wlan0 not found${NC}"
        exit 1
    fi
    
    # Power on device
    iwctl device wlan0 set-property Powered on
    sleep 1
    
    # Scan for networks
    echo -e "${YELLOW}Scanning for networks...${NC}"
    iwctl station wlan0 scan
    sleep 5
    
    # Show available networks
    echo -e "${YELLOW}Available networks:${NC}"
    iwctl station wlan0 get-networks
    
    echo -e "${YELLOW}Connecting to $WIFI_SSID...${NC}"
    
    # Create iwd config directory
    mkdir -p /var/lib/iwd
    
    # Convert SSID to hex for filename (iwd requirement for special characters)
    SSID_HEX=$(echo -n "$WIFI_SSID" | xxd -p | tr -d '\n')
    
    # Generate PSK using wpa_passphrase
    if command -v wpa_passphrase &> /dev/null; then
        PSK=$(wpa_passphrase "$WIFI_SSID" "$WIFI_PASSWORD" 2>/dev/null | grep '^\s*psk=' | grep -v '#psk' | cut -d'=' -f2)
    else
        echo -e "${RED}wpa_passphrase not found, installing...${NC}"
        pacman -Sy --noconfirm wpa_supplicant
        PSK=$(wpa_passphrase "$WIFI_SSID" "$WIFI_PASSWORD" 2>/dev/null | grep '^\s*psk=' | grep -v '#psk' | cut -d'=' -f2)
    fi
    
    if [ -z "$PSK" ]; then
        echo -e "${RED}Failed to generate PSK${NC}"
        exit 1
    fi
    
    # Create network config using hex SSID filename
    cat > "/var/lib/iwd/=${SSID_HEX}.psk" <<EOF
[Security]
PreSharedKey=$PSK

[Settings]
AutoConnect=true
EOF
    
    # Also try the regular filename as fallback
    # Escape dots and spaces for filename
    SSID_SAFE=$(echo "$WIFI_SSID" | sed 's/\./_/g' | sed 's/ /_/g')
    cat > "/var/lib/iwd/${SSID_SAFE}.psk" <<EOF
[Security]
PreSharedKey=$PSK

[Settings]
AutoConnect=true
EOF
    
    # Restart iwd to pick up configs
    systemctl restart iwd
    sleep 3
    
    # Try to connect
    iwctl station wlan0 connect "$WIFI_SSID" &>/dev/null &
    
    # Wait and verify connection
    echo -e "${YELLOW}Waiting for connection...${NC}"
    for i in {1..20}; do
        if ping -c 1 -W 2 8.8.8.8 &> /dev/null; then
            echo -e "${GREEN}✓ WiFi connected successfully${NC}"
            # Show connection info
            ip addr show wlan0 | grep "inet " | awk '{print "  IP Address: " $2}'
            return 0
        fi
        sleep 2
        echo -n "."
    done
    echo ""
    
    # Connection failed - try manual connection
    echo -e "${YELLOW}Automatic connection failed, trying manual method...${NC}"
    
    # Kill any existing connection attempts
    pkill iwctl 2>/dev/null || true
    
    # Try using wpa_supplicant as fallback
    echo -e "${YELLOW}Trying wpa_supplicant...${NC}"
    
    # Create wpa_supplicant config
    cat > /tmp/wpa_supplicant.conf <<EOF
ctrl_interface=/var/run/wpa_supplicant
update_config=1

network={
    ssid="$WIFI_SSID"
    psk=$PSK
}
EOF
    
    # Stop iwd
    systemctl stop iwd
    sleep 1
    
    # Start wpa_supplicant
    wpa_supplicant -B -i wlan0 -c /tmp/wpa_supplicant.conf
    sleep 3
    
    # Get IP via dhcp
    dhcpcd wlan0 &
    sleep 5
    
    # Check connection
    if ping -c 1 -W 2 8.8.8.8 &> /dev/null; then
        echo -e "${GREEN}✓ WiFi connected successfully (wpa_supplicant)${NC}"
        return 0
    fi
    
    # All methods failed
    echo -e "${RED}WiFi connection failed!${NC}"
    echo -e "${YELLOW}Current network status:${NC}"
    ip addr show wlan0
    echo ""
    echo -e "${YELLOW}Available networks:${NC}"
    iwctl station wlan0 get-networks 2>/dev/null || iw dev wlan0 scan | grep SSID
    echo ""
    echo -e "${YELLOW}Troubleshooting:${NC}"
    echo "  1. Verify SSID: '$WIFI_SSID'"
    echo "  2. Check password is correct"
    echo "  3. Ensure network is in range"
    echo "  4. Try connecting manually:"
    echo "     iwctl station wlan0 connect \"$WIFI_SSID\""
    echo ""
    read -p "Continue anyway? (y/n): " continue_anyway
    if [[ "$continue_anyway" != "y" ]]; then
        exit 1
    fi
}

setup_pacman_repos() {
    local config_file=$1
    
    echo -e "${GREEN}Configuring package repositories...${NC}"
    
    # Backup original
    cp "$config_file" "${config_file}.backup"
    
    # Enable parallel downloads and set to 10
    sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 10/' "$config_file"
    sed -i 's/^ParallelDownloads.*/ParallelDownloads = 10/' "$config_file"
    
    # Comment out official repos
    sed -i '/^\[core\]/,/^$/s/^/#/' "$config_file"
    sed -i '/^\[extra\]/,/^$/s/^/#/' "$config_file"
    sed -i '/^\[multilib\]/,/^$/s/^/#/' "$config_file"
    sed -i '/^\[community\]/,/^$/s/^/#/' "$config_file"
    
    # Add SteamOS repos
    cat >> "$config_file" <<EOF

[jupiter-${STEAMOS_VERSION}]
Server = https://steamdeck-packages.steamos.cloud/archlinux-mirror/\$repo/os/\$arch
SigLevel = Never

[holo-${STEAMOS_VERSION}]
Server = https://steamdeck-packages.steamos.cloud/archlinux-mirror/\$repo/os/\$arch
SigLevel = Never

[core-${STEAMOS_VERSION}]
Server = https://steamdeck-packages.steamos.cloud/archlinux-mirror/\$repo/os/\$arch
SigLevel = Never

[extra-${STEAMOS_VERSION}]
Server = https://steamdeck-packages.steamos.cloud/archlinux-mirror/\$repo/os/\$arch
SigLevel = Never

[multilib-${STEAMOS_VERSION}]
Server = https://steamdeck-packages.steamos.cloud/archlinux-mirror/\$repo/os/\$arch
SigLevel = Never
EOF

    pacman -Sy
    echo -e "${GREEN}✓ Repositories configured${NC}"
}

partition_disk() {
    echo -e "${YELLOW}Final warning: Partitioning $DISK in 10 seconds...${NC}"
    echo -e "${YELLOW}Press Ctrl+C to cancel!${NC}"
    for i in {10..1}; do
        echo -n "$i "
        sleep 1
    done
    echo ""
    
    echo -e "${GREEN}Partitioning disk...${NC}"
    
    # Unmount if mounted
    umount -R /mnt 2>/dev/null || true
    
    # Wipe existing partition table
    wipefs -af "$DISK" 2>/dev/null || true
    
    # Create new GPT partition table
    parted -s "$DISK" mklabel gpt
    
    # Create EFI partition (1MiB to 512MiB)
    parted -s "$DISK" mkpart primary 1MiB 512MiB
    parted -s "$DISK" name 1 "EFI"
    parted -s "$DISK" set 1 esp on
    
    # Create root partition (537MiB to 100%)
    parted -s "$DISK" mkpart primary 537MiB 100%
    parted -s "$DISK" name 2 "SteamOS"
    
    # Wait for kernel to recognize partitions
    sleep 2
    partprobe "$DISK"
    sleep 2
    
    echo -e "${GREEN}Formatting partitions...${NC}"
    
    # Determine partition naming scheme
    if [[ "$DISK" == *"nvme"* ]] || [[ "$DISK" == *"mmcblk"* ]]; then
        PART1="${DISK}p1"
        PART2="${DISK}p2"
    else
        PART1="${DISK}1"
        PART2="${DISK}2"
    fi
    
    # Format partitions
    mkfs.fat -F 32 "$PART1"
    mkfs.btrfs -f "$PART2"
    btrfs filesystem label "$PART2" SteamOS
    
    echo -e "${GREEN}Mounting partitions...${NC}"
    mount "$PART2" /mnt
    mkdir -p /mnt/boot
    mount "$PART1" /mnt/boot
    
    echo -e "${GREEN}✓ Disk partitioned and mounted${NC}"
    
    # Show result
    echo -e "${YELLOW}Partition layout:${NC}"
    lsblk "$DISK"
}

install_packages() {
    echo -e "${GREEN}Installing base system...${NC}"
    echo -e "${YELLOW}This will take 15-30 minutes depending on your connection${NC}"
    
    if [[ "$STEAMOS_VERSION" == "3.9" ]]; then
        # SteamOS 3.9 package set (Qt6/Plasma 6)
        pacstrap -K /mnt --needed --noconfirm mesa lib32-mesa vulkan-icd-loader lib32-vulkan-icd-loader
        pacstrap -K /mnt --needed --noconfirm 7zip a52dec aalib aardvark-dns abseil-cpp accountsservice acl adwaita-cursors adwaita-fonts adwaita-icon-theme adwaita-icon-theme-legacy aha alsa-card-profiles alsa-lib alsa-plugins alsa-topology-conf alsa-ucm-conf alsa-utils amd-ucode-neptune anthy aom appstream appstream-qt arch-install-scripts archlinux-appstream-data archlinux-keyring ark aspell aspell-en assimp at-spi2-core attica attr audit aurorae avahi baloo baloo-widgets base bash bash-completion bats binutils blas bluedevil bluez bluez-deprecated-tools bluez-libs bluez-qt bluez-utils bolt boost-libs breakpad breeze breeze-cursors breeze-gtk breeze-icons brltty brotli btop btrfs-progs bubblewrap bzip2 ca-certificates ca-certificates-mozilla ca-certificates-utils cairo cairomm-1.16 cantarell-fonts caps casync catatonit cblas cdparanoia cec-audio-control cecd cfitsio cifs-utils clinfo composefs compsize conmon containers-common convertlit coreutils cpupower criu crun cryptsetup cups cups-filters cups-pdf curl dav1d db5.3 dbus dbus-broker dbus-broker-units dbus-units dconf ddcutil debuginfod default-cursors desktop-file-utils desync device-mapper diffutils ding-libs dirlock discount discover distrobox djvulibre dmemcg-booster dmidecode dolphin dos2unix dosfstools dotconf double-conversion drkonqi drm-info drm_janitor duktape e2fsprogs earlyoom ebook-tools ec-log editorconfig-core-c efibootmgr efivar elfutils ell enchant espeak-ng evtest exfatprogs exiv2 expat f3 faad2 fatresize fd ffmpeg ffmpegthumbs fftw file filelight filesystem findutils firewalld fish flac flatpak flatpak-kcm fontconfig frameworkintegration freeglut freerdp freetype2 fremont-hw-support fribidi fuse2 fuse3 fuse-common fuse-overlayfs fwupd-efi fwupd-minimal galileo-mura gamemode gamescope gawk gc gcc-libs gcr-4 gdb gdb-common gdbm gdk-pixbuf2 gettext ghostscript giflib git glew glfw glib2 glibc glibmm-2.68 glib-networking glslang glu glycin gmp gnulib-l10n gnupg gnutls gobject-introspection-runtime gocryptfs gperftools gpgme gpgmepp gpm gptfdisk gpu-trace graphene graphite grep gsettings-desktop-schemas gsettings-system-schemas gsm gssdp gssproxy gst-plugin-pipewire gst-plugins-bad-libs gst-plugins-base gst-plugins-base-libs gst-plugins-good gstreamer gtest gtk3 gtk4 gtkmm-4.0 gtk-update-icon-cache guile gumbo-parser gupnp gupnp-igd gwenview gzip harfbuzz hicolor-icon-theme hidapi highway holo-dmi-rules holo-glibc-locales holo-grant-cap-sys-nice holo-keyring holo-nfs-utils-tmpfiles holo-plymouth-themes holo-realtek-firmware-toggles holo-session-selection holo-sudo holo-upower-config holo-zram-swap htop hunspell hwdata hwloc i2c-tools iana-etc ibus ibus-anthy ibus-hangul ibus-pinyin ibus-table ibus-table-cangjie-lite icu iio-sensor-proxy ijs imath imlib2 inputattach-cec-units inputplumber intel-gmmlib intel-media-driver iotop iproute2 iptables iputils iso-codes iw iwd jansson jasper jbig2dec jbigkit jemalloc jq json-c jsoncpp json-glib jupiter-dock-updater-bin jupiter-fan-control jupiter-firewall jupiter-hw-support jupiter-legacy-support kaccounts-integration kactivitymanagerd karchive kate kauth kbd kbookmarks kcgroups kcmutils kcodecs kcolorpicker kcolorscheme kcompletion kconfig kconfigwidgets kcontacts kcoreaddons kcrash kdbusaddons kdeclarative kde-cli-tools kdeconnect kdecoration kded kde-gtk-config kdeplasma-addons kdesu kdialog kdnssd kdsoap kdsoap-ws-discovery-client kdumpst kexec-tools keyutils kfilemetadata kglobalaccel kglobalacceld kguiaddons kholidays ki18n kiconthemes kidletime kimageannotator kimageformats kinfocenter kio kio-extras kio-fuse kirigami kirigami-addons kitemmodels kitemviews kitty-terminfo kjobwidgets kmenuedit kmod knewstuff knighttime knotifications knotifyconfig konsole kpackage kparts kpeople kpipewire kpmcore kpty kquickcharts kquickimageeditor krb5 krdp krunner kscreen kscreenlocker kservice ksshaskpass kstatusnotifieritem ksvg ksystemstats ktexteditor ktextwidgets kunitconversion kuserfeedback kwallet kwallet-pam kwayland kwidgetsaddons kwin kwindowsystem kwin-x11 kwrited kxmlgui lame lapack layer-shell-qt lcms2 ldb leancrypto leptonica less lib32-alsa-lib lib32-alsa-plugins lib32-brotli lib32-bzip2 lib32-curl lib32-dbus lib32-e2fsprogs lib32-expat lib32-flac lib32-fontconfig lib32-freetype2 lib32-gamemode lib32-gamescope lib32-gcc-libs lib32-glib2 lib32-glibc lib32-gmp lib32-gnutls lib32-icu lib32-json-c lib32-keyutils lib32-krb5 lib32-libasyncns lib32-libdisplay-info lib32-libdrm lib32-libelf lib32-libffi lib32-libgcrypt lib32-libglvnd lib32-libgpg-error lib32-libidn2 lib32-libldap lib32-libnghttp2 lib32-libnghttp3 lib32-libngtcp2 lib32-libnm lib32-libogg lib32-libpciaccess lib32-libpipewire lib32-libpng lib32-libpsl lib32-libpulse lib32-libsndfile lib32-libssh2 lib32-libtasn1 lib32-libunistring lib32-libva lib32-libvdpau lib32-libvorbis lib32-libx11 lib32-libxau lib32-libxcb lib32-libxcrypt lib32-libxcrypt-compat lib32-libxdmcp lib32-libxext lib32-libxfixes lib32-libxinerama lib32-libxml2 lib32-libxshmfence lib32-libxss lib32-libxxf86vm lib32-llvm-libs lib32-lm_sensors lib32-mangohud lib32-ncurses lib32-nettle lib32-nspr lib32-nss lib32-openal lib32-openssl lib32-opus lib32-p11-kit lib32-pcre2 lib32-pipewire lib32-renderdoc-minimal lib32-spirv-llvm-translator lib32-spirv-tools lib32-sqlite lib32-systemd lib32-util-linux lib32-vulkan-intel lib32-vulkan-mesa-implicit-layers lib32-vulkan-nouveau lib32-vulkan-radeon lib32-vulkan-virtio lib32-wayland lib32-xcb-util-keysyms lib32-xz lib32-zlib lib32-zstd libaccounts-glib libaccounts-qt libaio libao libarchive libasan libass libassuan libasyncns libatasmart libatomic libavc1394 libavif libb2 libblake3 libblockdev libblockdev-btrfs libblockdev-crypto libblockdev-fs libblockdev-loop libblockdev-lvm libblockdev-mdraid libblockdev-nvme libblockdev-part libblockdev-smart libblockdev-swap libbluray libbpf libbs2b libbsd libbytesize libcaca libcanberra libcap libcap-ng libcbor libcloudproviders libcolord libcups libcupsfilters libdaemon libdatrie libdbusmenu-glib libdbusmenu-gtk3 libdc1394 libdecor libdeflate libdisplay-info libdmtx libdovi libdrm libdv libdvdnav libdvdread libebml libebur128 libedit libei libelf libepoxy libevdev libevent libexif libfakekey libfdk-aac libffi libfido2 libfontenc libfreeaptx libfyaml libgcc libgcrypt libgfortran libgirepository libglvnd libgomp libgpg-error libgudev libhangul libhwasan libibus libice libidn libidn2 libiec61883 libiio libimobiledevice libimobiledevice-glue libinih libinput libjpeg-turbo libjxl libkdcraw libkexiv2 libksba libkscreen libksysguard liblc3 libldac libldap liblouis liblsan libmakepkg-dropins libmalcontent libmatroska libmbim libmd libmicrohttpd libmm-glib libmng libmnl libmodplug libmtp libmysofa libndp libnet libnetfilter_conntrack libnewt libnfnetlink libnftnl libnghttp2 libnghttp3 libngtcp2 libnice libnl libnm libnma-common libnma-gtk4 libnotify libnsl libntfs-3g libnvme libobjc libogg libopenmpt libp11-kit libpaper libpcap libpciaccess libpfm libpgm libpipewire libplacebo libplasma libplist libpng libppd libproxy libpsl libpulse libqaccessibilityclient-qt6 libqalculate libqmi libqrtr-glib libquadmath libraw libraw1394 librsvg libsamplerate libsasl libseccomp libsecret libserialport libshout libsigc++-3.0 libsm libsndfile libsodium libsonic libsoup3 libsoxr libspectre libspeechd libssc libssh libssh2 libstdc++ libstemmer libsysprof-capture libtasn1 libtatsu libteam libthai libtheora libtiff libtirpc libtommath libtool libtraceevent libtracefs libtsan libubsan libunibreak libunistring libunwind liburing libusb libusbmuxd libutempter libva libva-intel-driver libvdpau libverto libvlc libvorbis libvpl libvpx libwacom libwbclient libwebp libwireplumber libwnck3 libx11 libxau libxaw libxcb libxcomposite libxcrypt libxcrypt-compat libxcursor libxcvt libxdamage libxdmcp libxext libxfixes libxfont2 libxft libxi libxinerama libxkbcommon libxkbcommon-x11 libxkbfile libxml2 libxmlb libxmu libxpm libxrandr libxrender libxres libxshmfence libxslt libxss libxt libxtst libxv libxxf86vm libyaml libyuv libzip licenses lilv linux-api-headers linuxconsole linux-firmware-neptune linux-firmware-neptune-whence litehtml0.9 llhttp llvm-libs lmdb lm_sensors lsb-release l-smash lsof lua lua54 luajit lv2 lvm2 lz4 lzo makedumpfile mandoc mangohud md4c mdadm media-player-info mesa mesa-utils milou minizip mkinitcpio mkinitcpio-busybox mobile-broadband-provider-info modemmanager modemmanager-qt mpdecimal mpfr mpg123 mtdev nano ncdu ncurses netavark nethogs nettle networkmanager networkmanager-openvpn networkmanager-qt networkmanager-vpn-plugin-openvpn nfsidmap nfs-utils nftables noisetorch noto-fonts noto-fonts-cjk npth nspr nss nss-mdns ntfs-3g numactl nvme-cli ocean-sound-theme ocl-icd okular onetbb oniguruma openal opencore-amr opencv openexr openh264 openjpeg2 openjph openssh openssl openvpn openxr opus orc orca ostree oxygen oxygen-cursors oxygen-icons oxygen-sounds p11-kit pacman pacman-mirrorlist pam pambase pango pangomm-2.48 parallel parted partitionmanager paru passt pavucontrol pcaudiolib pciutils pcre pcre2 pcsclite perf perl perl-error perl-mailtools perl-timedate phonon-qt6 phonon-qt6-vlc pinentry pipewire pipewire-alsa pipewire-audio pipewire-jack pipewire-pulse pipewire-v4l2 pipewire-x11-bell pixman pkcs11-helper plasma5support plasma-activities plasma-activities-stats plasma-browser-integration plasma-desktop plasma-disks plasma-firewall plasma-foreground-booster plasma-integration plasma-keyboard plasma-login-manager plasma-meta plasma-nm plasma-pa plasma-systemmonitor plasma-thunderbolt plasma-vault plasma-wayland-protocols plasma-welcome plasma-workspace plymouth podman polkit polkit-kde-agent polkit-qt6 poppler poppler-data poppler-qt6 popt portaudio powerdevil powertop ppp print-manager prison procps-ng protobuf protobuf-c psmisc pulseaudio-qt purpose python python-aiohappyeyeballs python-aiohttp python-aiosignal python-anyio python-attrs python-cairo python-capng python-certifi python-click python-crcmod python-dbus python-dbus-next python-evdev python-firewall python-frozenlist python-gobject python-h11 python-hid python-httpcore python-httpx python-idna python-minidump python-multidict python-progressbar python-propcache python-protobuf python-psutil python-pyalsa python-pyaml python-pycups python-pyelftools python-pyenchant python-pygdbmi python-pyxdg python-semantic-version python-sentry_sdk python-setproctitle python-typing_extensions python-urllib3 python-utils python-yaml python-yarl pyzy qca-qt6 qcoro qpdf qqc2-breeze-style qqc2-desktop-style qrca qrencode qt5-base qt5-tools qt5-translations qt6-5compat qt6-base qt6-connectivity qt6-declarative qt6-imageformats qt6-location qt6-multimedia qt6-multimedia-ffmpeg qt6-positioning qt6-quick3d qt6-quicktimeline qt6-sensors qt6-shadertools qt6-speech qt6-svg qt6-tools qt6-translations qt6-virtualkeyboard qt6-webchannel qt6-webengine qt6-websockets qt6-webview qtkeychain-qt6 rauc rav1e re2 readline renderdoc-minimal ripgrep ripgrep-all rpcbind rsync rtkit rubberband rxvt-unicode-terminfo sbc scx-scheds sddm sdl2-compat sdl3 sdl3_ttf seatd sed serd shaderc shadow shared-mime-info signond signon-kwallet-extension signon-plugin-oauth2 signon-ui slang smartmontools smbclient snappy sndio socat sof-firmware solid sonnet sord sound-theme-freedesktop source-highlight spandsp spectacle speech-dispatcher speex speexdsp spirv-llvm-translator spirv-tools sqlite squashfs-tools sratom srt sshfs startup-notification steamdeck-dsp steamdeck-kde-presets steam-im-modules steam-jupiter-stable steam_notif_daemon steamos-powerbuttond strace sudo svt-av1 syndication syntax-highlighting system-config-printer systemd systemd-libs systemd-sysvcompat systemsettings taglib talloc tar tcl tdb tesseract tesseract-data-afr tesseract-data-osd tevent thin-provisioning-tools threadweaver tinysparql tk tmux tpm2-tss trace-cmd tree tslib ttf-dejavu ttf-hack ttf-twemoji-default twolame tzdata udisks2 udisks2-btrfs udisks2-lvm2 umr unrar unzip upower usbhid-gadget-passthru usb_modeswitch usbutils util-linux util-linux-libs v4l-utils vapoursynth verdict vid.stab vim vim-runtime vkmark vlc-plugin-a52dec vlc-plugin-alsa vlc-plugin-archive vlc-plugin-dav1d vlc-plugin-dbus vlc-plugin-dbus-screensaver vlc-plugin-faad2 vlc-plugin-flac vlc-plugin-gnutls vlc-plugin-inflate vlc-plugin-journal vlc-plugin-jpeg vlc-plugin-matroska vlc-plugin-mpg123 vlc-plugin-ogg vlc-plugin-opus vlc-plugin-png vlc-plugins-base vlc-plugin-shout vlc-plugin-speex vlc-plugin-tag vlc-plugin-theora vlc-plugin-twolame vlc-plugin-vorbis vlc-plugin-vpx vlc-plugin-xml vmaf volume_key vpower vulkan-icd-loader vulkan-intel vulkan-mesa-implicit-layers vulkan-nouveau vulkan-radeon vulkan-tools vulkan-virtio wavpack wayland wayland-utils webrtc-audio-processing-1 wget which wireguard-tools wireless-domain-setter wireless-regdb wireless_tools wireplumber wpa_supplicant x264 x265 xcb-proto xcb-util xcb-util-cursor xcb-util-errors xcb-util-image xcb-util-keysyms xcb-util-renderutil xcb-util-wm xdg-dbus-proxy xdg-desktop-portal xdg-desktop-portal-gamescope xdg-desktop-portal-gtk xdg-desktop-portal-holo xdg-desktop-portal-kde xdg-user-dirs xdg-utils xdotool xf86-input-libinput xf86-video-amdgpu xkeyboard-config xorg-fonts-encodings xorgproto xorg-server xorg-server-common xorg-setxkbmap xorg-xauth xorg-xdpyinfo xorg-xhost xorg-xkbcomp xorg-xmessage xorg-xmodmap xorg-xprop xorg-xrandr xorg-xrdb xorg-xwayland xorg-xwininfo xsettingsd xterm xvidcore xxhash xz zenity-gtk3 zeromq zimg zint zip zix zlib zlib-ng zram-generator zsh zstd zxing-cpp
    else
        # SteamOS 3.5 - 3.8.1x package set (Qt5/KF5)
        pacstrap -K /mnt --needed --noconfirm mesa lib32-libva-mesa-driver lib32-mesa lib32-opencl-mesa libva-mesa-driver
        pacstrap -K /mnt --needed --noconfirm a52dec aalib accounts-qml-module accountsservice acl adobe-source-code-pro-fonts adwaita-icon-theme aha alsa-card-profiles alsa-lib alsa-plugins alsa-topology-conf alsa-ucm-conf alsa-utils amd-ucode aom appstream appstream-glib appstream-qt arch-install-scripts archlinux-appstream-data archlinux-keyring argon2 ark at-spi2-core atkmm attr audit autoconf automake avahi baloo-widgets base bash bash-completion bc bind binutils bison bluedevil bluez bluez-libs bluez-plugins bluez-utils bolt boost boost-libs breeze breeze-gtk breeze-icons brltty brotli btrfs-progs bubblewrap bzip2 ca-certificates ca-certificates-mozilla ca-certificates-utils cairo cairomm cantarell-fonts cdparanoia cfitsio cheese chromaprint cifs-utils cloud-init clutter clutter-gst clutter-gtk cogl confuse convertlit coreutils cpupower cryptsetup curl cython darkhttpd dav1d db dbus dbus-glib dbus-python dconf ddrescue debugedit desktop-file-utils device-mapper dhclient dhcpcd dialog diffutils ding-libs discount discover dkms dmidecode dmraid dnsmasq dnssec-anchors dolphin dosfstools double-conversion drbl drkonqi duktape e2fsprogs ebook-tools ecryptfs-utils editorconfig-core-c edk2-shell efibootmgr efivar eglexternalplatform enchant espeak-ng espeakup ethtool exfatprogs exiv2 expat f2fs-tools faac faad2 fakeroot fatresize ffmpeg ffmpegthumbs ffnvcodec-headers file filesystem findutils flac flashrom flatpak flex fluidsynth fontconfig freeglut freerdp freetype2 frei0r-plugins fribidi fsarchiver fuse-common fuse2 fuse3 fwupd fwupd-efi gamemode gamescope gavl gawk gc gcab gcc gcc-libs gcr gdb gdb-common gdbm gdk-pixbuf2 geoclue geocode-glib gettext ghostscript giflib git glew glfw-x11 glib-networking glib2 glibc glibmm glslang glu gmp gnome-desktop gnome-desktop-common gnome-video-effects gnupg gnutls go gobject-introspection-runtime gpart gpgme gpm gptfdisk graphene graphite grep grml-zsh-config groff gsettings-desktop-schemas gsm gssdp gssproxy gst-plugins-bad gst-plugins-bad-libs gst-plugins-base gst-plugins-base-libs gst-plugins-good gstreamer gtk-update-icon-cache gtk3 gtkmm3 guile gupnp gupnp-igd gvfs gwenview gzip harfbuzz harfbuzz-icu hdparm hicolor-icon-theme hidapi hunspell hunspell-en_us hwdata hyphen iana-etc icu ijs imagemagick imath imlib2 iniparser iproute2 iptables iputils irssi iso-codes iw jansson jasper jbig2dec jemalloc jfsutils jq json-c json-glib jupiter-hw-support kaccounts-integration kactivitymanagerd kate kbd kde-cli-tools kde-gtk-config kdecoration kdegraphics-mobipocket kdegraphics-thumbnailers kdeplasma-addons kdialog kdsoap kdsoap-ws-discovery-client keyutils kinfocenter kio-extras kio-fuse kirigami2 kitty-terminfo kmenuedit kmod konsole kpipewire kpmcore krb5 kscreen kscreenlocker ksshaskpass ksystemstats kwallet-pam kwayland-integration kwin kwrited l-smash lame layer-shell-qt lbzip2 lcms2 ldb ldns less lftp lhasa lib32-alsa-lib lib32-alsa-plugins lib32-brotli lib32-bzip2 lib32-curl lib32-dbus lib32-e2fsprogs lib32-expat lib32-fontconfig lib32-freetype2 lib32-gamemode lib32-gamescope lib32-gcc-libs lib32-glib2 lib32-glibc lib32-gnutls lib32-harfbuzz lib32-icu lib32-keyutils lib32-krb5 lib32-libcap lib32-libdrm lib32-libelf lib32-libffi lib32-libgcrypt lib32-libglvnd lib32-libgpg-error lib32-libidn2 lib32-libldap lib32-libpciaccess lib32-libpng lib32-libpsl lib32-libpulse lib32-libssh2 lib32-libtasn1 lib32-libtirpc lib32-libunistring lib32-libunwind lib32-libva lib32-libva-mesa-driver lib32-libx11 lib32-libxau lib32-libxcb lib32-libxcomposite lib32-libxcrypt lib32-libxdamage lib32-libxdmcp lib32-libxext lib32-libxfixes lib32-libxinerama lib32-libxml2 lib32-libxshmfence lib32-libxss lib32-libxxf86vm lib32-llvm lib32-llvm-libs lib32-lm_sensors lib32-mangohud lib32-mesa lib32-mesa-vdpau lib32-ncurses lib32-nspr lib32-nss lib32-opencl-driver lib32-opencl-icd-loader lib32-openssl lib32-p11-kit lib32-pam lib32-pcre2 lib32-pipewire lib32-pipewire-jack lib32-pipewire-v4l2 lib32-sdl2 lib32-sqlite lib32-systemd lib32-util-linux lib32-vkd3d lib32-vulkan-icd-loader lib32-vulkan-mesa-layers lib32-vulkan-radeon lib32-wayland lib32-xz lib32-zlib lib32-zstd libaccounts-glib libaccounts-qt libaio libappindicator-gtk3 libarchive libass libassuan libasyncns libatasmart libavc1394 libavtp libblockdev libbluray libbpf libbs2b libbsd libbytesize libcaca libcanberra libcap libcap-ng libcbor libcdio libcdio-paranoia libcheese libcloudproviders libcolord libcups libdaemon libdatrie libdbusmenu-glib libdbusmenu-gtk3 libdbusmenu-qt5 libdc1394 libdca libde265 libdmtx libdrm libdv libdvbpsi libdvdnav libdvdread libebml libedit libelf libepoxy libevdev libevent libexif libfdk-aac libffi libfido2 libfontenc libfreeaptx libftdi libgcrypt libglvnd libgme libgpg-error libgssglue libgudev libgusb libibus libical libice libidn libidn2 libiec61883 libimobiledevice libindicator-gtk3 libinih libinput libinstpatch libisl libjcat libjpeg-turbo libkate libkexiv2 libksba libkscreen libksysguard libldac libldap liblouis liblqr liblrdf libltc libmad libmanette libmatroska libmaxminddb libmbim libmd libmfx libmicrodns libmm-glib libmnl libmodplug libmpc libmpcdec libmpeg2 libmtp libndp libnetfilter_conntrack libnewt libnfnetlink libnftnl libnghttp2 libnice libnl libnm libnma libnma-common libnotify libnsl libogg libomxil-bellagio libopenmpt libotr libp11-kit libpackagekit-glib libpaper libpcap libpciaccess libpgm libpipeline libplacebo libplist libpng libproxy libpsl libpulse libqaccessibilityclient libqalculate libqmi libqrtr-glib libraqm libraw libraw1394 librsvg libsamplerate libsasl libseccomp libsecret libshout libsigc++ libsm libsmbios libsndfile libsodium libsonic libsoup libsoup3 libsoxr libspeechd libsrtp libssh libssh2 libstemmer libsysprof-capture libtar libtasn1 libteam libthai libtheora libtiff libtirpc libtommath libtool libunistring libunwind libupnp liburcu libusb libusb-compat libusbmuxd libutempter libuv libva libva-mesa-driver libva-utils libvdpau libverto libvorbis libvpx libwacom libwebp libwpe libx11 libxau libxaw libxcb libxcomposite libxcrypt libxcursor libxcvt libxdamage libxdmcp libxext libxfixes libxfont2 libxft libxi libxinerama libxkbcommon lib32-xkbcommon libxkbcommon-x11 libxkbfile libxml2 libxmlb libxmu libxpm libxrandr libxrender libxres libxshmfence libxslt libxss libxt libxtst libxv libxvmc libxxf86vm libyaml libzip licenses lilv linux-api-headers linux-atm linux-firmware-neptune linux-firmware-neptune-whence livecd-sounds llvm llvm-libs lm_sensors lmdb lrzip lsb-release lsof lsscsi lua lua52 lua53 lv2 lvm2 lynx lz4 lzo lzop m4 make man-db man-pages mangohud mc md4c mdadm media-player-info memtest86+ mesa mesa-utils mesa-vdpau meson milou minizip mjpegtools mkinitcpio mkinitcpio-busybox mkinitcpio-nfs-utils mobile-broadband-provider-info modemmanager mpfr mpg123 mtdev mtools nano nbd ncurses ndctl ndisc6 neon netplan nettle network-manager-applet networkmanager nfs-utils nfsidmap nilfs-utils ninja nm-connection-editor nmap noto-fonts noto-fonts-cjk npth nspr nss ntfs-3g nvme-cli oath-toolkit ocl-icd onboard oniguruma openal openconnect opencore-amr openexr openjpeg2 openssh openssl opus orc os-prober ostree oxygen oxygen-sounds p11-kit pacman pacman-mirrorlist pacutils pahole pam pambase pango pangomm partclone parted partimage partitionmanager patch pavucontrol pbzip2 pcaudiolib pciutils pcre pcre2 pcsclite perl perl-error perl-mailtools pigz pinentry pipewire pipewire-alsa pipewire-audio pipewire-jack pipewire-pulse pipewire-v4l2 pipewire-x11-bell pipewire-zeroconf pixman pixz pkgconf plasma-browser-integration plasma-desktop plasma-disks plasma-firewall plasma-integration plasma-meta plasma-nm plasma-pa plasma-sdk plasma-systemmonitor plasma-thunderbolt plasma-vault plasma-workspace plasma-workspace-wallpapers polkit polkit-kde-agent polkit-qt5 poppler poppler-qt5 popt portaudio powerdevil ppp procps-ng protobuf protobuf-c psmisc pv python python-appdirs python-attrs python-autocommand python-cairo python-cffi python-chardet python-click python-configobj python-crcmod python-cryptography python-evdev python-gobject python-hid python-idna python-inflect python-jaraco.context python-jaraco.functools python-jaraco.text python-jinja python-jsonpatch python-jsonpointer python-jsonschema python-markupsafe python-more-itertools python-netifaces python-oauthlib python-ordered-set python-packaging python-ply python-progressbar python-protobuf python-pycparser python-pydantic python-pyparsing python-pyserial python-requests python-setuptools python-six python-systemd python-tomli python-trove-classifiers python-typing_extensions python-urllib3 python-utils python-validate-pyproject python-yaml qca-qt5 qpdf qrencode qt5-base qt5-declarative qt5-graphicaleffects qt5-location qt5-multimedia qt5-quickcontrols qt5-quickcontrols2 qt5-sensors qt5-speech qt5-svg qt5-tools qt5-translations qt5-wayland qt5-webchannel qt5-webengine qt5-x11extras qt6-webview raptor rav1e re2 readline rp-pppoe rpcbind rsync rtmpdump run-parts rxvt-unicode-terminfo sbc scons screen sddm sddm-kcm sdl2 sdparm seatd sed serd sg3_utils shaderc shadow shared-mime-info signon-kwallet-extension signon-plugin-oauth2 signon-ui signond slang smartmontools smbclient snappy socat sof-firmware sord sound-theme-freedesktop soundtouch source-highlight spandsp spectacle speex speexdsp spirv-tools sqlite squashfs-tools sratom srt sshfs steam-im-modules steam-jupiter-stable steam_notif_daemon steamdeck-dsp steamdeck-kde-presets stoken sudo svt-av1 svt-hevc sysfsutils systemd systemd-libs systemd-resolvconf systemd-sysvcompat systemsettings taglib talloc tar tcl tcpdump tdb terminus-font testdisk tevent texinfo tmux tpm2-tss tracker3 tslib ttf-dejavu ttf-hack ttf-twemoji-default twolame tzdata udftools udisks2 ufw unzip 7zip upower usb_modeswitch usbmuxd usbutils util-linux util-linux-libs v4l-utils vid.stab vim vim-runtime vkd3d vlc vmaf volume_key vpnc vulkan-icd-loader vulkan-mesa-layers vulkan-radeon vulkan-tools wavpack wayland wayland-protocols wayland-utils webkit2gtk-4.1 webrtc-audio-processing wget which wildmidi wireless-regdb wireless_tools wireplumber woff2 wpa_supplicant wpebackend-fdo wvdial wvstreams x264 x265 xbindkeys xcb-proto xcb-util xcb-util-cursor xcb-util-errors xcb-util-image xcb-util-keysyms xcb-util-renderutil xcb-util-wm xdg-dbus-proxy xdg-desktop-portal xdg-desktop-portal-kde xdg-user-dirs xdg-utils xf86-input-libinput xf86-video-amdgpu xfsprogs xkeyboard-config xl2tpd xmlsec xorg-fonts-encodings xorg-server xorg-server-common xorg-setxkbmap xorg-xauth xorg-xdpyinfo xorg-xgamma xorg-xkbcomp xorg-xmessage xorg-xprop xorg-xrandr xorg-xrdb xorg-xset xorg-xsetroot xorgproto xvidcore xxhash xz zbar zenity zeromq zimg zlib zsh zstd zvbi zxing-cpp jupiter-legacy-support jupiter-fan-control paru cmake glm vulkan-headers benchmark noise-suppression-for-voice
    fi    
    
    echo -e "${GREEN}✓ Main packages installed (some may have been skipped if unavailable)${NC}"

    echo -e "${GREEN}Installing latest kernel for your specific OS release${NC}"

    # Version specific kernels
    case "$STEAMOS_VERSION" in
    3.5)
        pacstrap -K /mnt --needed --noconfirm linux-neptune-61 linux-neptune-61-headers
        ;;
    3.6)
        pacstrap -K /mnt --needed --noconfirm linux-neptune-65 linux-neptune-65-headers
        ;;
    3.7)
        pacstrap -K /mnt --needed --noconfirm linux-neptune-611 linux-neptune-611-headers
        ;;
    # NOTE: 3.8 is non-functional (kernel/repo issues) - only 3.8.1x is supported
    3.8.1x)
        pacstrap -K /mnt --needed --noconfirm linux-neptune-616 linux-neptune-616-headers
        ;;
    3.9)
        pacstrap -K /mnt --needed --noconfirm linux-neptune-72 linux-neptune-72-headers
        ;;
    *)
        echo -e "${RED}Warning: No kernel mapping for STEAMOS_VERSION='${STEAMOS_VERSION}'.${NC}"
        echo -e "${YELLOW}Attempting to auto-detect the newest available linux-neptune package...${NC}"
        AUTO_KERNEL=$(pacman -Ss '^linux-neptune-[0-9]' 2>/dev/null | grep '^jupiter\|^holo' | awk '{print $1}' | cut -d'/' -f2 | grep -v headers | sort -V | tail -1)
        if [ -n "$AUTO_KERNEL" ]; then
            echo -e "${GREEN}Found: ${AUTO_KERNEL}${NC}"
            pacstrap -K /mnt --needed --noconfirm "$AUTO_KERNEL" "${AUTO_KERNEL}-headers"
        else
            echo -e "${RED}ERROR: Could not auto-detect a kernel package. Aborting.${NC}"
            exit 1
        fi
        ;;
    esac
    
    echo -e "${GREEN}✓ Latest kernel installed${NC}"
    
    case "$STEAMOS_VERSION" in
    3.7)
        pacstrap -K /mnt --needed --noconfirm steamos-powerbuttond || true
        ;;
    3.8.1x)
        pacstrap -K /mnt --needed --noconfirm steamos-powerbuttond plasma-x11-session steamos-manager || true
        ;;
    3.9)
        pacstrap -K /mnt --needed --noconfirm steamos-manager || true
        ;;
    esac
    
    echo -e "${GREEN}✓ Version specific packages installed${NC}"
}

configure_system() {
    echo -e "${GREEN}Configuring system in chroot...${NC}"
    
    # Generate fstab
    genfstab -U /mnt >> /mnt/etc/fstab
    
    # Create chroot configuration script - NOTE: Using double quotes on EOF delimiter
    cat > /mnt/root/configure.sh <<"CHROOT_EOF"
#!/bin/bash
set -e

# Time and locale
sed -i 's/#NTP=/NTP=time.google.com/' /etc/systemd/timesyncd.conf
ln -sf /usr/share/zoneinfo/__TIMEZONE__ /etc/localtime
hwclock --systohc
echo "__HOSTNAME__" > /etc/hostname

# Root password
echo "root:__ROOT_PASSWORD__" | chpasswd

# Bootloader
bootctl install

# Create loader.conf
cat > /boot/loader/loader.conf << 'LOADER_EOF'
default    SteamOS
timeout    0
console-mode max
editor     no
LOADER_EOF

# Detect kernel
KERNEL_PKG=$(pacman -Qq | grep '^linux-neptune' | head -1)
if [ -z "$KERNEL_PKG" ]; then
    echo "ERROR: No neptune kernel found!"
    exit 1
fi

# Create boot entry
cat > /boot/loader/entries/steamos.conf << BOOT_EOF
title   SteamOS
linux   /vmlinuz-${KERNEL_PKG}
initrd  /initramfs-${KERNEL_PKG}.img
options root="LABEL=SteamOS" rw quiet compress=zstd splash loglevel=3 rd.systemd.show_status=false vt.global_cursor_default=0 rd.udev.log_level=3 nowatchdog clearcpuid=514 amd_iommu=off audit=0 rd.luks=0 rd.lvm=0 rd.md=0 rd.dm=0 log_buf_len=4M amd_pstate=active preempt=full
BOOT_EOF


# Fix /tmp/.X11-unix losing its sticky bit (drwxrwxrwt) and being left
# owned by the login user instead of root. Root cause: gamescope-session's
# own wlserver code (xwayland/sockets.c) unconditionally recreates
# /tmp/.X11-unix itself every time it starts (every boot, since SteamOS
# always boots into Game Mode first), using plain mkdir() with no sticky
# bit. This happens AFTER systemd-tmpfiles-setup.service already runs at
# boot, so a normal tmpfiles.d rule can never win - gamescope-session
# always overwrites it afterward. A path unit that watches for changes
# and re-applies chmod 1777 is what actually works, confirmed by testing.
# Version-specific service enablement
if [ "__STEAMOS_VERSION__" = "3.9" ]; then
cat > /etc/systemd/system/fix-x11-unix.path << 'PATH_UNIT_EOF'
[Path]
PathChanged=/tmp/.X11-unix
Unit=fix-x11-unix.service

[Install]
WantedBy=multi-user.target
PATH_UNIT_EOF

cat > /etc/systemd/system/fix-x11-unix.service << 'SERVICE_UNIT_EOF'
[Service]
Type=oneshot
ExecStart=/usr/bin/chmod 1777 /tmp/.X11-unix
SERVICE_UNIT_EOF

systemctl enable fix-x11-unix.path
fi

# Enable services
systemctl enable NetworkManager bluetooth systemd-resolved sshd upower systemd-timesyncd jupiter-fan-control sddm

# Version-specific service enablement
if [ "__STEAMOS_VERSION__" = "3.9" ]; then
    systemctl enable steamos-manager
    mkdir -p /usr/bin/steamos-polkit-helpers
    ln -sf /usr/bin/holo-polkit-helpers/holo-priv-write /usr/bin/steamos-polkit-helpers/steamos-priv-write
    ln -s /usr/bin/holo-polkit-helpers/holo-devkit-mode /usr/bin/steamos-polkit-helpers/steamos-devkit-mode
    ln -s /usr/bin/holo-polkit-helpers/holo-disable-wireless-power-management /usr/bin/steamos-polkit-helpers/steamos-disable-wireless-power-management
    ln -s /usr/bin/holo-polkit-helpers/holo-enable-sshd /usr/bin/steamos-polkit-helpers/steamos-enable-sshd
    ln -s /usr/bin/holo-polkit-helpers/holo-factory-reset-config /usr/bin/steamos-polkit-helpers/steamos-factory-reset-config
    ln -s /usr/bin/holo-polkit-helpers/holo-format-device /usr/bin/steamos-polkit-helpers/steamos-format-device
    ln -s /usr/bin/holo-polkit-helpers/holo-format-sdcard /usr/bin/steamos-polkit-helpers/steamos-format-sdcard
    ln -s /usr/bin/holo-polkit-helpers/holo-grant-cap-sys-nice /usr/bin/steamos-polkit-helpers/steamos-grant-cap-sys-nice
    ln -s /usr/bin/holo-polkit-helpers/holo-poweroff-now /usr/bin/steamos-polkit-helpers/steamos-poweroff-now
    ln -s /usr/bin/holo-polkit-helpers/holo-realtek-firmware-toggles /usr/bin/steamos-polkit-helpers/steamos-realtek-firmware-toggles
    ln -s /usr/bin/holo-polkit-helpers/holo-reboot-now /usr/bin/steamos-polkit-helpers/steamos-reboot-now
    ln -s /usr/bin/holo-polkit-helpers/holo-reboot-other /usr/bin/steamos-polkit-helpers/steamos-reboot-other
    ln -s /usr/bin/holo-polkit-helpers/holo-restart-sddm /usr/bin/steamos-polkit-helpers/steamos-restart-sddm
    ln -s /usr/bin/holo-polkit-helpers/holo-select-branch /usr/bin/steamos-polkit-helpers/steamos-select-branch
    ln -s /usr/bin/holo-polkit-helpers/holo-set-hostname /usr/bin/steamos-polkit-helpers/steamos-set-hostname
    ln -s /usr/bin/holo-polkit-helpers/holo-set-timezone /usr/bin/steamos-polkit-helpers/steamos-set-timezone
    ln -s /usr/bin/holo-polkit-helpers/holo-trim-devices /usr/bin/steamos-polkit-helpers/steamos-trim-devices
    ln -s /usr/bin/holo-polkit-helpers/holo-update /usr/bin/steamos-polkit-helpers/steamos-update
fi

# Create user
useradd -m -s /bin/bash -G polkitd,geoclue,flatpak,rfkill,video,render,input,audio,wheel,power,network,games __USERNAME__

sed -i 's/__USERNAME__:x:[0-9]*:[0-9]*::/__USERNAME__:x:1000:1000::/' /etc/passwd

passwd -d __USERNAME__

# Sudoers
sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Swap file
if [[ "__STEAMOS_VERSION__" == "3.9" ]]; then
    echo "Skipping swap file creation for SteamOS 3.9"
else
    btrfs subvolume create /swap
    btrfs filesystem mkswapfile --size __SWAP_SIZE__ --uuid clear /swap/swapfile
    swapon /swap/swapfile
    echo "/swap/swapfile none swap defaults 0 0" >> /etc/fstab
fi

# steamos-update stub
rm -f /usr/bin/steamos-update
cat > /usr/bin/steamos-update << 'UPDATE_STUB_EOF'
#!/bin/bash
exit 7
UPDATE_STUB_EOF
chmod +x /usr/bin/steamos-update

# steamos-polkit-helpers/steamos-update stub
mkdir -p /usr/bin/steamos-polkit-helpers
rm -f /usr/bin/steamos-polkit-helpers/steamos-update
cat > /usr/bin/steamos-polkit-helpers/steamos-update << 'POLKIT_UPDATE_STUB_EOF'
#!/bin/bash
exit 7
POLKIT_UPDATE_STUB_EOF
chmod +x /usr/bin/steamos-polkit-helpers/steamos-update

# steamos-select-branch stub
rm -f /usr/bin/steamos-select-branch
cat > /usr/bin/steamos-select-branch << 'BRANCH_STUB_EOF'
#!/bin/bash
exit 7
BRANCH_STUB_EOF
chmod +x /usr/bin/steamos-select-branch

echo "Chroot configuration complete!"
CHROOT_EOF

    # Replace placeholders
    sed -i "s|__TIMEZONE__|$TIMEZONE|g" /mnt/root/configure.sh
    sed -i "s|__HOSTNAME__|$HOSTNAME|g" /mnt/root/configure.sh
    sed -i "s|__USERNAME__|$USERNAME|g" /mnt/root/configure.sh
    sed -i "s|__SWAP_SIZE__|$SWAP_SIZE|g" /mnt/root/configure.sh
    sed -i "s|__STEAMOS_VERSION__|$STEAMOS_VERSION|g" /mnt/root/configure.sh
    
    chmod +x /mnt/root/configure.sh
    
    # Setup pacman repos in chroot
    setup_pacman_repos /mnt/etc/pacman.conf
    
    # Execute chroot configuration
    arch-chroot /mnt /root/configure.sh
    
    echo -e "${GREEN}✓ System configured${NC}"
}

post_install_user_setup() {
    echo -e "${GREEN}Running post-install user setup...${NC}"
    
    cat > /mnt/home/$USERNAME/setup.sh <<'USER_EOF'
#!/bin/bash
cd ~
mkdir -p ~/.themes ~/.icons
cp -R /usr/share/themes/Breeze-Dark/ ~/.themes

# Flatpak overrides
sudo flatpak override --filesystem=$HOME/.local/share/applications
sudo flatpak override --filesystem=$HOME/.local/share/icons
sudo flatpak override --filesystem=$HOME/.themes
sudo flatpak override --filesystem=$HOME/.icons
sudo flatpak override --env=GTK_THEME=Breeze-Dark

echo "User setup complete!"
USER_EOF

    chmod +x /mnt/home/$USERNAME/setup.sh
    chown 1000:1000 /mnt/home/$USERNAME/setup.sh
    
    arch-chroot /mnt su - $USERNAME -c "/home/$USERNAME/setup.sh"
    
    echo -e "${GREEN}✓ User setup complete${NC}"
}

install_nomachine() {
    if [[ "$INSTALL_NOMACHINE" == "y" ]]; then
        echo -e "${GREEN}Installing NoMachine...${NC}"
        arch-chroot /mnt bash <<'NX_EOF'
cd /tmp
wget https://web9001.nomachine.com/download/9.3/Linux/nomachine_9.3.7_1_x86_64.tar.gz
tar zxvf nomachine_9.3.7_1_x86_64.tar.gz
mv NX /usr/
/usr/NX/nxserver --install redhat
systemctl enable nxserver
rm -rf /tmp/nomachine*
NX_EOF
        echo -e "${GREEN}✓ NoMachine installed${NC}"
    fi
}

# ===========================
# MAIN EXECUTION
# ===========================

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root${NC}"
    exit 1
fi

echo ""
echo -e "${BLUE}=== Starting Installation ===${NC}"
echo ""

# Execute installation steps
if [[ "$CONFIGURE_WIFI" == "y" ]]; then
    setup_wifi
else
    echo -e "${GREEN}Skipping WiFi setup - using wired connection${NC}"
    # Test network connectivity
    if ping -c 1 -W 2 8.8.8.8 &> /dev/null; then
        echo -e "${GREEN}✓ Network connection verified${NC}"
    else
        echo -e "${RED}No network connection detected!${NC}"
        read -p "Continue anyway? (y/n): " continue_no_net
        if [[ "$continue_no_net" != "y" ]]; then
            exit 1
        fi
    fi
fi
setup_pacman_repos /etc/pacman.conf
partition_disk
install_packages
configure_system
post_install_user_setup
install_nomachine

echo ""
echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║     Installation Complete!                 ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo -e "  1. ${BLUE}umount -R /mnt${NC}"
echo -e "  2. ${BLUE}reboot${NC}"
echo -e "  3. Remove installation media"
echo ""
echo -e "${GREEN}Your SteamOS ${STEAMOS_VERSION} installation is ready!${NC}"
echo -e "Login as: ${GREEN}$USERNAME${NC}"
echo ""
