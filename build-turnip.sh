#!/bin/bash -e

# Required packages for building the turnip driver
deps="meson ninja patchelf unzip curl pip flex bison zip"

# Android NDK and Mesa version
ndkver="https://dl.google.com/android/repository/android-ndk-r28-beta1-linux.zip"
ndkdir="android-ndk-r28-beta1"

mesaver="https://gitlab.freedesktop.org/mesa/mesa/-/archive/main/mesa-main.zip"
mesadir="mesa-main"

# Colors for terminal output
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

workdir="$(pwd)/turnip_workdir"
magiskdir="$workdir/turnip_module"

DRIVER_FILE="vulkan.turnip.so"
META_FILE="meta.json"
ZIP_FILE="Turnip-EMULATOR-mesa_git.zip"

clear

# Clean work directory if it exists
if [ -d "$workdir" ]; then
    echo "Work directory already exists. Cleaning before proceeding..." $'\n'
    rm -rf "$workdir"
    sleep 2
fi

echo "Checking system for required dependencies..."

# Check for required dependencies 
for deps_chk in $deps; do
    sleep 0.25
    if command -v "$deps_chk" >/dev/null 2>&1; then
        echo -e "$green - $deps_chk found $nocolor"
    else
        echo -e "$red - $deps_chk not found, cannot continue. $nocolor"
        deps_missing=1
    fi
done

# Install missing dependencies automatically
if [ "$deps_missing" == "1" ]; then
    echo "Missing dependencies, installing them now..." $'\n'
    sudo apt install -y meson patchelf unzip curl python3-pip flex bison zip python3-mako python-is-python3 &> /dev/null
fi

clear

echo "Creating and entering the work directory..." $'\n'
mkdir -p "$workdir" && cd "$_"

# Download Android NDK
echo "Downloading Android NDK..." $'\n'
curl $ndkver --output "$ndkdir".zip &> /dev/null

clear

echo "Extracting Android NDK..." $'\n'
unzip "$ndkdir".zip &> /dev/null

# Download Mesa source
echo "Downloading Latest Mesa source ..." $'\n'
curl $mesaver --output "$mesadir".zip &> /dev/null

clear

echo "Extracting Mesa source..." $'\n'
unzip "$mesadir".zip &> /dev/null
cd $mesadir

clear

# Create Meson cross file for Android
echo "Creating Meson cross file..." $'\n'
ndk_bin="$workdir/$ndkdir/toolchains/llvm/prebuilt/linux-x86_64/bin"
cat <<EOF >"android-aarch64"
[binaries]
ar = '$ndk_bin/llvm-ar'
c = ['ccache', '$ndk_bin/aarch64-linux-android33-clang', '-fno-semantic-interposition', '-O2', '-flto']
cpp = ['ccache', '$ndk_bin/aarch64-linux-android33-clang++', '-fno-semantic-interposition', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '-static-libstdc++', '-O2', '-flto']
c_ld = 'lld'
cpp_ld = 'lld'
strip = '$ndk_bin/aarch64-linux-android-strip'
pkg-config = ['env', 'PKG_CONFIG_LIBDIR=NDKDIR/pkg-config', '/usr/bin/pkg-config']
[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

# Generate build files using Meson
echo "Generating build files..." $'\n'
meson setup build-android-aarch64 --cross-file "$workdir"/"$mesadir"/android-aarch64 -Dbuildtype=release -Db_pie=true -Dplatforms=android -Dplatform-sdk-version=33 -Dandroid-stub=true -Dgallium-drivers= -Dvulkan-drivers=freedreno -Dfreedreno-kmds=kgsl -Db_lto=true -Dstrip=true &> "$workdir"/meson_log

# Compile build files using Ninja
echo "Compiling build files..." $'\n'
ninja -C build-android-aarch64 &> "$workdir"/ninja_log

echo "Using patchelf to match .so name..." $'\n'
cp "$workdir"/"$mesadir"/build-android-aarch64/src/freedreno/vulkan/libvulkan_freedreno.so "$workdir"
cd "$workdir"

if ! [ -a libvulkan_freedreno.so ]; then
    echo -e "$red Build failed! libvulkan_freedreno.so not found $nocolor" && exit 1
fi

echo "Prepare magisk module structure..." $'\n'
p1="system/vendor/lib64/hw"
mkdir -p "$magiskdir/$p1"
cd "$magiskdir"

echo "Copy necessary files from the work directory..." $'\n'
cp "$workdir"/libvulkan_freedreno.so "$workdir"/vulkan.adreno.so
cp "$workdir"/vulkan.adreno.so "$magiskdir/$p1"

meta="META-INF/com/google/android"
mkdir -p "$meta"

# Create update-binary
cat <<EOF >"$meta/update-binary"
#################
# Initialization
#################
umask 022
# echo before loading util_functions
ui_print() { echo "\$1"; }
require_new_magisk() {
  ui_print "*******************************"
  ui_print " Please install Magisk v20.4+! "
  ui_print "*******************************"
  exit 1
}
#########################
# Load util_functions.sh
#########################
OUTFD=\$2
ZIPFILE=\$3
[ -f /data/adb/magisk/util_functions.sh ] || require_new_magisk
. /data/adb/magisk/util_functions.sh
[ \$MAGISK_VER_CODE -lt 20400 ] && require_new_magisk
install_module
exit 0
EOF

# Create updater-script
cat <<EOF >"$meta/updater-script"
#MAGISK
EOF

cat <<EOF >"module.prop"
id=turnip-mesa
name=Freedreno Turnip Vulkan Driver-mesa_git
version=v24.3
versionCode=261024
author=v3kt0r-87,Str4nger01
description=Turnip is an open-source vulkan driver for devices with Adreno 6xx-7xx GPUs.
updateJson=https://raw.githubusercontent.com/str4ng3r-01/Mesa-Turnip-Builder/refs/heads/test/update.json
EOF

cat <<EOF >"customize.sh"
MODVER=\`grep_prop version \$MODPATH/module.prop\`
MODVERCODE=\`grep_prop versionCode \$MODPATH/module.prop\`

ui_print ""
ui_print "Version=\$MODVER "
ui_print "MagiskVersion=\$MAGISK_VER"
ui_print ""
ui_print "Freedreno Turnip Vulkan Driver -V3KT0R"
ui_print "Adreno Driver Support Group - Telegram"
ui_print ""
sleep 1.25

ui_print ""
ui_print "Checking Device info ..."
sleep 1.25

[ \$(getprop ro.system.build.version.sdk) -lt 33 ] && echo "Android 13 is required! Aborting ..." && abort
echo ""
echo "Everything looks fine .... proceeding"
ui_print ""
ui_print "Installing Driver Please Wait ..."
ui_print ""

sleep 1.25
set_perm_recursive \$MODPATH/system 0 0 755 u:object_r:system_file:s0
set_perm_recursive \$MODPATH/system/vendor 0 2000 755 u:object_r:vendor_file:s0
set_perm \$MODPATH/system/vendor/lib64/hw/vulkan.adreno.so 0 0 0644 u:object_r:same_process_hal_file:s0

ui_print ""
ui_print " Cleaning GPU Cache ... Please wait!"
find /data/user_de/*/*/*cache/* -iname "*shader*" -exec rm -rf {} +
find /data/data/* -iname "*shader*" -exec rm -rf {} +
find /data/data/* -iname "*graphitecache*" -exec rm -rf {} +
find /data/data/* -iname "*gpucache*" -exec rm -rf {} +
find /data_mirror/data*/*/*/*/* -iname "*shader*" -exec rm -rf {} +
find /data_mirror/data*/*/*/*/* -iname "*graphitecache*" -exec rm -rf {} +
find /data_mirror/data*/*/*/*/* -iname "*gpucache*" -exec rm -rf {} +
ui_print "- Done."
ui_print ""

ui_print "Driver installed Successfully"
sleep 1.25

ui_print ""
ui_print "All done, Please REBOOT device"
ui_print ""
ui_print "BY: @VEKT0R_87 , @Str4nger01"
ui_print ""
EOF

echo "Packing driver files into Magisk/KSU module ..." $'\n'
zip -r $workdir/Turnip-MAGISK-KSU-mesa_git.zip * &> /dev/null
if ! [ -a $workdir/Turnip-MAGISK-KSU-mesa_git.zip ]; then
    echo -e "$red-Packing failed!$nocolor" && exit 1
else
    clear

    echo " Its time to create Turnip build for EMULATOR"

    sleep 2

    cd ..

    mv vulkan.adreno.so vulkan.turnip.so

# Create meta.json file for turnip emulator
 cat <<EOF > "$META_FILE"
{
  "schemaVersion": 1,
  "name": "Freedreno Turnip Driver mesa_git",
  "description": "Compiled using Android NDK 28 Beta",
  "author": "v3kt0r-87,@Str4nger01",
  "packageVersion": "3",
  "vendor": "Mesa3D",
  "driverVersion": "Vulkan 1.3.296",
  "minApi": 33,
  "libraryName": "vulkan.turnip.so"
}
EOF

# Zip the turnip .so file and meta.json file
    if ! zip "$ZIP_FILE" "$DRIVER_FILE" "$META_FILE" > /dev/null 2>&1; then
    echo -e "$red Error: Zipping driver files failed. $nocolor"
    exit 1
    fi

    clear

    echo -e "$green-All done, you can take your drivers from here;$nocolor" $'\n'
    echo $workdir/Turnip-MAGISK-KSU-mesa_git.zip $'\n'
    echo $workdir/Turnip-EMULATOR-mesa_git.zip $'\n'
    echo -e "$green Build Finished :). $nocolor" $'\n'

# Cleanup 
    rm "$DRIVER_FILE" "$META_FILE"
fi
