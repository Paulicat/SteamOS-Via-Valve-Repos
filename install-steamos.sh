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
echo -e "${YELLOW}WiFi Configuration${NC}"
read -p "WiFi SSID: " WIFI_SSID
read -sp "WiFi Password: " WIFI_PASSWORD
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
read -p "SteamOS version (e.g., 3.6, 3.7) [default: 3.6]: " STEAMOS_VERSION
STEAMOS_VERSION=${STEAMOS_VERSION:-3.6}

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
echo ""
echo -e "${YELLOW}Swap Configuration${NC}"
echo "Examples: 8g, 16g, 32g"
read -p "Swap file size [default: 8g]: " SWAP_SIZE
SWAP_SIZE=${SWAP_SIZE:-8g}

# NoMachine
echo ""
echo -e "${YELLOW}Optional Software${NC}"
read -p "Install NoMachine remote desktop? (y/n) [default: n]: " INSTALL_NOMACHINE
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
    
    cat > /etc/iwd/main.conf <<EOF
[General]
EnableNetworkConfiguration=true
EOF

    systemctl restart iwd
    sleep 2
    
    iwctl station wlan0 scan
    sleep 2
    echo "$WIFI_PASSWORD" | iwctl station wlan0 connect "$WIFI_SSID"
    sleep 3
    
    # Verify connection
    if ! ping -c 1 8.8.8.8 &> /dev/null; then
        echo -e "${RED}WiFi connection failed!${NC}"
        echo -e "${YELLOW}Please check your SSID and password${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ WiFi connected successfully${NC}"
}

setup_pacman_repos() {
    local config_file=$1
    
    echo -e "${GREEN}Configuring package repositories...${NC}"
    
    # Backup original
    cp "$config_file" "${config_file}.backup"
    
    # Enable parallel downloads
    sed -i 's/^#ParallelDownloads/ParallelDownloads/' "$config_file"
    
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

[community-${STEAMOS_VERSION}]
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
    
    parted -s "$DISK" mklabel gpt
    parted -s "$DISK" mkpart "EFI system partition" fat32 1MiB 512MiB
    parted -s "$DISK" set 1 esp on
    parted -s "$DISK" mkpart "SteamOS" btrfs 537MiB 100%
    
    echo -e "${GREEN}Formatting partitions...${NC}"
    
    # Determine partition naming scheme
    if [[ "$DISK" == *"nvme"* ]] || [[ "$DISK" == *"mmcblk"* ]]; then
        PART1="${DISK}p1"
        PART2="${DISK}p2"
    else
        PART1="${DISK}1"
        PART2="${DISK}2"
    fi
    
    mkfs.btrfs -f "$PART2"
    btrfs filesystem label "$PART2" SteamOS
    mkfs.fat -F 32 "$PART1"
    
    echo -e "${GREEN}Mounting partitions...${NC}"
    mount "$PART2" /mnt
    mkdir -p /mnt/boot
    mount "$PART1" /mnt/boot
    
    echo -e "${GREEN}✓ Disk partitioned and mounted${NC}"
}

install_packages() {
    echo -e "${GREEN}Installing base system...${NC}"
    echo -e "${YELLOW}This will take 15-30 minutes depending on your connection${NC}"
    
    pacstrap -K /mnt a52dec aalib accounts-qml-module accountsservice acl adobe-source-code-pro-fonts adwaita-icon-theme aha alsa-card-profiles alsa-lib alsa-plugins alsa-topology-conf alsa-ucm-conf alsa-utils amd-ucode aom appstream appstream-glib appstream-qt arch-install-scripts archlinux-appstream-data archlinux-keyring argon2 ark at-spi2-core atkmm attr audit autoconf automake avahi b43-fwcutter baloo-widgets base bash bash-completion bc bind binutils bison bluedevil bluez bluez-libs bluez-plugins bluez-utils bolt boost boost-libs breeze breeze-gtk breeze-icons brltty brotli btrfs-progs bubblewrap bzip2 ca-certificates ca-certificates-mozilla ca-certificates-utils cairo cairomm cantarell-fonts cdparanoia cfitsio cheese chromaprint cifs-utils cloud-init clutter clutter-gst clutter-gtk cogl confuse convertlit coreutils cpupower cryptsetup curl cython darkhttpd dav1d db dbus dbus-glib dbus-python dconf ddrescue debugedit desktop-file-utils device-mapper dhclient dhcpcd dialog diffutils ding-libs discount discover dkms dmidecode dmraid dnsmasq dnssec-anchors dolphin dosfstools double-conversion drbl drkonqi duktape e2fsprogs ebook-tools ecryptfs-utils editorconfig-core-c edk2-shell efibootmgr efivar eglexternalplatform enchant espeak-ng espeakup ethtool exfatprogs exiv2 expat f2fs-tools faac faad2 fakeroot fatresize ffmpeg ffmpeg4.4 ffmpegthumbs ffnvcodec-headers file filesystem findutils flac flashrom flatpak flex fluidsynth fontconfig freeglut freerdp freetype2 frei0r-plugins fribidi fsarchiver fuse-common fuse2 fuse3 fwupd fwupd-efi gamemode gamescope gavl gawk gc gcab gcc gcc-libs gcr gdb gdb-common gdbm gdk-pixbuf2 geoclue geocode-glib gettext ghostscript giflib git glew glfw-x11 glib-networking glib2 glibc glibmm glslang glu gmp gnome-desktop gnome-desktop-common gnome-video-effects gnupg gnutls go gobject-introspection-runtime gpart gpgme gpm gptfdisk graphene graphite grep grml-zsh-config groff gsettings-desktop-schemas gsm gssdp gssproxy gst-plugins-bad gst-plugins-bad-libs gst-plugins-base gst-plugins-base-libs gst-plugins-good gstreamer gtk-update-icon-cache gtk3 gtkmm3 guile gupnp gupnp-igd gvfs gwenview gzip harfbuzz harfbuzz-icu hdparm hicolor-icon-theme hidapi hunspell hunspell-en_us hwdata hyphen iana-etc icu ijs imagemagick imath imlib2 iniparser iproute2 iptables iputils irssi iso-codes iw jansson jasper jbig2dec jemalloc jfsutils jq json-c json-glib jupiter-hw-support kaccounts-integration kactivitymanagerd kate kbd kde-cli-tools kde-gtk-config kdecoration kdegraphics-mobipocket kdegraphics-thumbnailers kdeplasma-addons kdialog kdsoap kdsoap-ws-discovery-client keyutils kinfocenter kio-extras kio-fuse kirigami2 kitty-terminfo kmenuedit kmod konsole kpipewire kpmcore krb5 kscreen kscreenlocker ksshaskpass ksystemstats kwallet-pam kwayland-integration kwin kwrited l-smash lame layer-shell-qt lbzip2 lcms2 ldb ldns less lftp lhasa lib32-alsa-lib lib32-alsa-plugins lib32-brotli lib32-bzip2 lib32-curl lib32-dbus lib32-e2fsprogs lib32-expat lib32-fontconfig lib32-freetype2 lib32-gamemode lib32-gamescope lib32-gcc-libs lib32-glib2 lib32-glibc lib32-harfbuzz lib32-icu lib32-keyutils lib32-krb5 lib32-libcap lib32-libdrm lib32-libelf lib32-libffi lib32-libgcrypt lib32-libglvnd lib32-libgpg-error lib32-libidn2 lib32-libldap lib32-libpciaccess lib32-libpng lib32-libpsl lib32-libssh2 lib32-libtasn1 lib32-libtirpc lib32-libunistring lib32-libunwind lib32-libva lib32-libva-mesa-driver lib32-libx11 lib32-libxau lib32-libxcb lib32-libxcrypt lib32-libxdamage lib32-libxdmcp lib32-libxext lib32-libxfixes lib32-libxinerama lib32-libxml2 lib32-libxshmfence lib32-libxss lib32-libxxf86vm lib32-llvm lib32-llvm-libs lib32-lm_sensors lib32-mangohud lib32-mesa lib32-mesa-vdpau lib32-ncurses lib32-nspr lib32-nss lib32-openssl lib32-p11-kit lib32-pam lib32-pcre2 lib32-pipewire lib32-pipewire-jack lib32-pipewire-v4l2 lib32-sqlite lib32-systemd lib32-util-linux lib32-vulkan-icd-loader lib32-vulkan-mesa-layers lib32-vulkan-radeon lib32-wayland lib32-xz lib32-zlib lib32-zstd libaccounts-glib libaccounts-qt libaio libappindicator-gtk3 libarchive libass libassuan libasyncns libatasmart libavc1394 libavtp libblockdev libbluray libbpf libbs2b libbsd libbytesize libcaca libcanberra libcap libcap-ng libcbor libcdio libcdio-paranoia libcheese libcloudproviders libcolord libcups libdaemon libdatrie libdbusmenu-glib libdbusmenu-gtk3 libdbusmenu-qt5 libdc1394 libdca libde265 libdmtx libdrm libdv libdvbpsi libdvdnav libdvdread libebml libedit libelf libepoxy libevdev libevent libexif libfdk-aac libffi libfido2 libfontenc libfreeaptx libftdi libgcrypt libglvnd libgme libgpg-error libgssglue libgudev libgusb libibus libical libice libidn libidn2 libiec61883 libimobiledevice libindicator-gtk3 libinih libinput libinstpatch libisl libjcat libjpeg-turbo libkate libkexiv2 libksba libkscreen libksysguard libldac libldap liblouis liblqr liblrdf libltc libmad libmanette libmatroska libmaxminddb libmbim libmd libmfx libmicrodns libmm-glib libmnl libmodplug libmpc libmpcdec libmpeg2 libmtp libndp libnetfilter_conntrack libnewt libnfnetlink libnftnl libnghttp2 libnice libnl libnm libnma libnma-common libnotify libnsl libogg libomxil-bellagio libopenmpt libotr libp11-kit libpackagekit-glib libpaper libpcap libpciaccess libpgm libpipeline libplacebo libplist libpng libproxy libpsl libpulse libqaccessibilityclient libqalculate libqmi libqrtr-glib libraqm libraw libraw1394 librsvg libsamplerate libsasl libseccomp libsecret libshout libsigc++ libsm libsmbios libsndfile libsodium libsonic libsoup libsoup3 libsoxr libspeechd libsrtp libssh libssh2 libstemmer libsysprof-capture libtar libtasn1 libteam libthai libtheora libtiff libtirpc libtommath libtool libunistring libunwind libupnp liburcu libusb libusb-compat libusbmuxd libutempter libuv libva libva-mesa-driver libva-utils libvdpau libverto libvorbis libvpx libwacom libwebp libwpe libx11 libxau libxaw libxcb libxcomposite libxcrypt libxcursor libxcvt libxdamage libxdmcp libxext libxfixes libxfont2 libxft libxi libxinerama libxkbcommon libxkbcommon-x11 libxkbfile libxml2 libxmlb libxmu libxpm libxrandr libxrender libxres libxshmfence libxslt libxss libxt libxtst libxv libxvmc libxxf86vm libyaml libzip licenses lilv linux-api-headers linux-atm linux-firmware-neptune linux-firmware-neptune-whence livecd-sounds llvm llvm-libs lm_sensors lmdb lrzip lsb-release lsof lsscsi lua lua52 lua53 lv2 lvm2 lynx lz4 lzo lzop m4 make man-db man-pages mangohud mc md4c mdadm media-player-info memtest86+ mesa mesa-utils mesa-vdpau meson milou minizip mjpegtools mkinitcpio mkinitcpio-busybox mkinitcpio-nfs-utils mobile-broadband-provider-info modemmanager mpfr mpg123 mtdev mtools nano nbd ncurses ndctl ndisc6 neofetch neon netplan nettle network-manager-applet networkmanager nfs-utils nfsidmap nilfs-utils ninja nm-connection-editor nmap noto-fonts noto-fonts-cjk npth nspr nss ntfs-3g nvme-cli oath-toolkit ocl-icd onboard oniguruma openal openconnect opencore-amr openexr openjpeg2 openssh openssl opus orc os-prober ostree oxygen oxygen-sounds p11-kit pacman pacman-mirrorlist pacutils pahole pam pambase pango pangomm partclone parted partimage partitionmanager patch pavucontrol pbzip2 pcaudiolib pciutils pcre pcre2 pcsclite perl perl-error perl-mailtools perl-timedate phonon-qt5 phonon-qt5-gstreamer pigz pinentry pipewire pipewire-alsa pipewire-audio pipewire-jack pipewire-pulse pipewire-v4l2 pixman pixz pkgconf plasma-browser-integration plasma-desktop plasma-disks plasma-firewall plasma-integration plasma-meta plasma-nm plasma-pa plasma-sdk plasma-systemmonitor plasma-thunderbolt plasma-vault plasma-workspace plasma-workspace-wallpapers polkit polkit-kde-agent polkit-qt5 poppler poppler-qt5 popt portaudio powerdevil ppp procps-ng protobuf protobuf-c psmisc pv python python-appdirs python-attrs python-autocommand python-cairo python-cffi python-chardet python-click python-configobj python-crcmod python-cryptography python-evdev python-gobject python-hid python-idna python-inflect python-jaraco.context python-jaraco.functools python-jaraco.text python-jinja python-jsonpatch python-jsonpointer python-jsonschema python-markupsafe python-more-itertools python-netifaces python-oauthlib python-ordered-set python-packaging python-ply python-progressbar python-pycparser python-pydantic python-pyparsing python-pyserial python-requests python-setuptools python-six python-systemd python-tomli python-trove-classifiers python-typing_extensions python-urllib3 python-utils python-validate-pyproject python-yaml qca-qt5 qpdf qrencode qt5-base qt5-declarative qt5-graphicaleffects qt5-location qt5-multimedia qt5-quickcontrols qt5-quickcontrols2 qt5-sensors qt5-speech qt5-svg qt5-tools qt5-translations qt5-wayland qt5-webchannel qt5-webengine qt6-webview qt5-x11extras raptor rav1e re2 readline reiserfsprogs rp-pppoe rpcbind rsync rtmpdump run-parts rxvt-unicode-terminfo sbc scons screen sddm-kcm sddm sdl2 sdparm seatd sed serd sg3_utils shaderc shadow shared-mime-info signon-kwallet-extension signon-plugin-oauth2 signon-ui signond slang smartmontools smbclient snappy socat sof-firmware sord sound-theme-freedesktop soundtouch source-highlight spandsp spectacle speex speexdsp spirv-tools sqlite squashfs-tools sratom srt sshfs steam-im-modules steam-jupiter-stable steamdeck-kde-presets stoken sudo svt-av1 svt-hevc sysfsutils systemd systemd-libs systemd-resolvconf systemd-sysvcompat systemsettings taglib talloc tar tcl tcpdump tdb terminus-font testdisk tevent texinfo tmux tpm2-tss tracker3 tslib ttf-dejavu ttf-hack ttf-twemoji-default twolame tzdata udftools udisks2 ufw unzip upower usb_modeswitch usbmuxd usbutils util-linux util-linux-libs v4l-utils vid.stab vim vim-runtime vlc vmaf volume_key vpnc vulkan-icd-loader vulkan-mesa-layers vulkan-radeon vulkan-tools wavpack wayland wayland-protocols wayland-utils webkit2gtk-4.1 webrtc-audio-processing wget which wildmidi wireless-regdb wireless_tools wireplumber woff2 wpa_supplicant wpebackend-fdo wvdial wvstreams x264 x265 xbindkeys xcb-proto xcb-util xcb-util-cursor xcb-util-errors xcb-util-image xcb-util-keysyms xcb-util-renderutil xcb-util-wm xdg-dbus-proxy xdg-desktop-portal xdg-desktop-portal-kde xdg-user-dirs xdg-utils xf86-input-libinput xf86-video-amdgpu xfsprogs xkeyboard-config xl2tpd xmlsec xorg-fonts-encodings xorg-server xorg-server-common xorg-setxkbmap xorg-xauth xorg-xdpyinfo xorg-xkbcomp xorg-xmessage xorg-xprop xorg-xrandr xorg-xrdb xorg-xset xorg-xsetroot xorgproto xplc xvidcore xxhash xz zbar zenity zeromq zimg zlib zsh zstd zvbi zxing-cpp jupiter-legacy-support lib32-vkd3d python-protobuf vkd3d xorg-xgamma lib32-gnutls lib32-libpulse lib32-libxcomposite lib32-opencl-icd-loader lib32-sdl2 lib32-opencl-driver acpid plymouth steam_notif_daemon pipewire-x11-bell pipewire-zeroconf linux-neptune-65 linux-neptune-65-headers paru cmake glm vulkan-headers benchmark jupiter-fan-control steamdeck-dsp noise-suppression-for-voice
    
    echo -e "${GREEN}✓ Packages installed${NC}"
}

configure_system() {
    echo -e "${GREEN}Configuring system in chroot...${NC}"
    
    # Generate fstab
    genfstab -U /mnt >> /mnt/etc/fstab
    
    # Create chroot configuration script
    cat > /mnt/root/configure.sh <<'CHROOT_EOF'
#!/bin/bash
set -e

# Plymouth configuration
sed -i 's/HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block filesystems fsck)/HOOKS=(base udev autodetect plymouth modconf kms keyboard keymap consolefont block filesystems fsck)/' /etc/mkinitcpio.conf

# Check if steamos-jupiter.png exists, otherwise use steamos.png
if [ -f /usr/share/plymouth/themes/steamos/steamos-jupiter.png ]; then
    sed -i 's/image = Image("steamos.png");/image = Image("steamos-jupiter.png");/' /usr/share/plymouth/themes/steamos/steamos.script
fi

plymouth-set-default-theme steamos
mkinitcpio -P

# Time and locale
sed -i 's/#NTP=/NTP=time.google.com/' /etc/systemd/timesyncd.conf
ln -sf /usr/share/zoneinfo/__TIMEZONE__ /etc/localtime
hwclock --systohc
sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "__HOSTNAME__" > /etc/hostname

# Root password
echo "Set root password:"
passwd

# Bootloader
bootctl install
cat > /boot/loader/loader.conf <<EOF
default    SteamOS
timeout    3
console-mode max
editor     no
EOF

# Detect kernel
KERNEL_PKG=\$(pacman -Qq | grep '^linux-neptune' | head -1)
if [ -z "\$KERNEL_PKG" ]; then
    echo "ERROR: No neptune kernel found!"
    exit 1
fi

cat > /boot/loader/entries/steamos.conf <<EOF
title   SteamOS
linux   /vmlinuz-\${KERNEL_PKG}
initrd  /initramfs-\${KERNEL_PKG}.img
options root="LABEL=SteamOS" rw quiet compress=zstd splash loglevel=3 rd.systemd.show_status=false vt.global_cursor_default=0 rd.udev.log_level=3 nowatchdog clearcpuid=514 amd_iommu=off audit=0 rd.luks=0 rd.lvm=0 rd.md=0 rd.dm=0 log_buf_len=4M amd_pstate=active preempt=full
EOF

# Enable services
systemctl enable NetworkManager bluetooth systemd-resolved sshd upower systemd-timesyncd jupiter-fan-control sddm

# Create user
useradd -m -G polkitd,geoclue,flatpak,rfkill,video,render,input,audio,wheel,power,network,games __USERNAME__
sed -i 's/__USERNAME__:x:[0-9]*:[0-9]*::/__USERNAME__:x:1000:1000::/' /etc/passwd

echo "Set password for __USERNAME__:"
passwd __USERNAME__

# Sudoers
sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Swap file
btrfs subvolume create /swap
btrfs filesystem mkswapfile --size __SWAP_SIZE__ --uuid clear /swap/swapfile
swapon /swap/swapfile
echo "/swap/swapfile none swap defaults 0 0" >> /etc/fstab

# steamos-update stub
rm -f /usr/bin/steamos-update
cat > /usr/bin/steamos-update <<'EOF'
#!/bin/bash
if command -v frzr-deploy > /dev/null; then
    if [ "$1" == "check" ]; then
        frzr-deploy --check
    elif [ "$1" == "--supports-duplicate-detection" ]; then
        exit 0
    else
        frzr-deploy --steam-progress
    fi
else
    exit 7
fi
EOF
chmod +x /usr/bin/steamos-update

# steamos-select-branch stub
rm -f /usr/bin/steamos-select-branch
cat > /usr/bin/steamos-select-branch <<'EOF'
#!/bin/bash
STEAMOS_BRANCH_SCRIPT="/usr/lib/os-branch-select"
if [ -f $STEAMOS_BRANCH_SCRIPT ]; then
    ${STEAMOS_BRANCH_SCRIPT} $@
else
    echo "No branch script was found"
fi
EOF
chmod +x /usr/bin/steamos-select-branch

echo "Chroot configuration complete!"
CHROOT_EOF

    # Replace placeholders
    sed -i "s|__TIMEZONE__|$TIMEZONE|g" /mnt/root/configure.sh
    sed -i "s|__HOSTNAME__|$HOSTNAME|g" /mnt/root/configure.sh
    sed -i "s|__USERNAME__|$USERNAME|g" /mnt/root/configure.sh
    sed -i "s|__SWAP_SIZE__|$SWAP_SIZE|g" /mnt/root/configure.sh
    
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
setup_wifi
setup_pacman_repos /etc/pacman.conf
partition_disk
install_packages
configure_system
post_install_user_setup
install_nomachine

echo ""
echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║     Installation Complete!            ║${NC}"
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
