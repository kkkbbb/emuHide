#!/system/bin/sh

MODDIR=${MODDIR:-${0%/*}}
WORK_DIR=/data/adb/hunter_env_stealth
LOG_DIR=$WORK_DIR/log
PROFILE=hunter_pixel
HUNTER_PACKAGE=com.zhenxi.hunter
BOOTCONFIG_FILE=$WORK_DIR/fake_bootconfig
KEYMINT_TARGET=/vendor/lib64/libpuresoftkeymasterdevice.so
KEYMINT_PATCH_FILE=$WORK_DIR/keymint/vendor_libpuresoftkeymasterdevice.so
SENSOR_TARGET=/vendor/lib64/hw/android.hardware.sensors@2.1-impl.ranchu.so
SENSOR_PATCH_FILE=$WORK_DIR/sensor/android.hardware.sensors@2.1-impl.ranchu.so
ALIAS_ROOT=$WORK_DIR/vendor_alias
PRODUCT_OVERLAY_ALIAS_ROOT=$WORK_DIR/product_overlay_alias
DEV_ORIGINAL=/dev/goldfish_address_space
DEV_ALIAS=/dev/mali_address_space
BLOCKED_PROP_AREA=$WORK_DIR/blocked_property_area
PROPCTL=$MODDIR/bin/propctl
PATCHCTL=$MODDIR/bin/patchctl
SERIAL_SYNC_PID_FILE=$WORK_DIR/prop-serial-sync.pid
PROFILE_WORKER_PID_FILE=$WORK_DIR/profile-worker.pid
EMULATOR_PROP_PATTERN="qemu|ranchu|goldfish|emulator|gfxxx"

chcon_tree() {
  local context="$1"
  local path="$2"
  [ -e "$path" ] || return 0
  chcon -R "$context" "$path" 2>/dev/null || true
  find "$path" -type l -exec chcon -h "$context" {} \; 2>/dev/null || true
}

ensure_module_permissions() {
  chmod 755 "$MODDIR/post-fs-data.sh" "$MODDIR/service.sh" "$MODDIR/uninstall.sh" 2>/dev/null || true
  [ -f "$PROPCTL" ] && chmod 755 "$PROPCTL" 2>/dev/null || true
  [ -f "$PATCHCTL" ] && chmod 755 "$PATCHCTL" 2>/dev/null || true
  chcon_tree u:object_r:system_file:s0 "$MODDIR"
}

log() {
  mkdir -p "$LOG_DIR"
  echo "[$(date '+%F %T')] $*" >>"$LOG_DIR/module.log"
}

run_cmd() {
  log "+ $*"
  "$@" >>"$LOG_DIR/module.log" 2>&1
}

unmount_path() {
  local path="$1"
  local pid ns seen i
  if ! command -v nsenter >/dev/null 2>&1; then
    grep -qs " $path " /proc/mounts && /system/bin/umount -l "$path" >>"$LOG_DIR/module.log" 2>&1 || true
    return 0
  fi
  seen=
  for pid in 1 $(pidof zygote64 2>/dev/null) $(pidof zygote 2>/dev/null); do
    [ -d "/proc/$pid/ns" ] || continue
    ns=$(readlink "/proc/$pid/ns/mnt" 2>/dev/null)
    case " $seen " in *" $ns "*) continue ;; esac
    seen="$seen $ns"
    nsenter -t "$pid" -m -- /system/bin/sh -c "grep -qs ' $path ' /proc/mounts && /system/bin/umount -l '$path' || true" >>"$LOG_DIR/module.log" 2>&1 || true
  done
}

bind_path_global() {
  local src="$1"
  local dst="$2"
  local pid ns seen rc
  rc=0
  if ! command -v nsenter >/dev/null 2>&1; then
    unmount_path "$dst"
    /system/bin/mount --bind "$src" "$dst" >>"$LOG_DIR/module.log" 2>&1
    return $?
  fi
  seen=
  unmount_path "$dst"
  for pid in 1 $(pidof zygote64 2>/dev/null) $(pidof zygote 2>/dev/null); do
    [ -d "/proc/$pid/ns" ] || continue
    ns=$(readlink "/proc/$pid/ns/mnt" 2>/dev/null)
    case " $seen " in *" $ns "*) continue ;; esac
    seen="$seen $ns"
    nsenter -t "$pid" -m -- /system/bin/mount --bind "$src" "$dst" >>"$LOG_DIR/module.log" 2>&1 || rc=1
  done
  return "$rc"
}

bind_file() {
  local src="$1"
  local dst="$2"
  [ -f "$src" ] || {
    log "missing bind source: $src"
    return 1
  }
  [ -e "$dst" ] || {
    log "missing bind target: $dst"
    return 1
  }
  bind_path_global "$src" "$dst"
}

bind_dir() {
  local src="$1"
  local dst="$2"
  [ -d "$src" ] || {
    log "missing bind source: $src"
    return 1
  }
  [ -d "$dst" ] || {
    log "missing bind target: $dst"
    return 1
  }
  bind_path_global "$src" "$dst"
}

setup_bootconfig() {
  mkdir -p "$WORK_DIR"
  cat >"$BOOTCONFIG_FILE" <<'EOF'
androidboot.boot_devices = "14700000.ufs"
androidboot.dalvik.vm.heapsize = "576m"
androidboot.debug.hwui.renderer = "skiagl"
androidboot.hardware = "gs201"
androidboot.hardware.gltransport = "mali"
androidboot.hardware.vulkan = "mali"
androidboot.logcat = "*:I"
androidboot.opengles.version = "196608"
androidboot.serialno = "3A021JEHN02756"
androidboot.bootloader = "cloudripper-14.0-11200000"
androidboot.bootmode = "normal"
androidboot.verifiedbootstate = "green"
androidboot.flash.locked = "1"
androidboot.vbmeta.device_state = "locked"
androidboot.vbmeta.digest = "60c39051c6cfdb18db2fd0ad8068b41e55a0a96e16bffe5156c0ee61a22b00bf"
androidboot.vbmeta.hash_alg = "sha256"
androidboot.vbmeta.size = "6656"
androidboot.veritymode = "enforcing"
EOF
  chown root:root "$BOOTCONFIG_FILE"
  chmod 444 "$BOOTCONFIG_FILE"
  chcon u:object_r:system_file:s0 "$BOOTCONFIG_FILE" 2>/dev/null || true
  [ -e /proc/bootconfig ] && bind_file "$BOOTCONFIG_FILE" /proc/bootconfig
}

setup_keymint() {
  [ -x "$PATCHCTL" ] || {
    log "missing patchctl, skipping KeyMint patch"
    return 0
  }
  [ -f "$KEYMINT_TARGET" ] || {
    log "missing KeyMint source: $KEYMINT_TARGET"
    return 0
  }
  unmount_path "$KEYMINT_TARGET"
  mkdir -p "${KEYMINT_PATCH_FILE%/*}"
  if "$PATCHCTL" keymint "$KEYMINT_TARGET" "$KEYMINT_PATCH_FILE" >>"$LOG_DIR/module.log" 2>&1; then
    chown root:root "$KEYMINT_PATCH_FILE" 2>/dev/null || true
    chmod 644 "$KEYMINT_PATCH_FILE" 2>/dev/null || true
    chcon u:object_r:vendor_file:s0 "$KEYMINT_PATCH_FILE" 2>/dev/null || true
    bind_file "$KEYMINT_PATCH_FILE" "$KEYMINT_TARGET" || true
  else
    log "KeyMint patch failed"
  fi
  setprop ctl.restart vendor.keymint-default 2>/dev/null || true
  setprop ctl.restart keystore2 2>/dev/null || true
}

setup_sensor() {
  [ -x "$PATCHCTL" ] || {
    log "missing patchctl, skipping sensor patch"
    return 0
  }
  [ -f "$SENSOR_TARGET" ] || {
    log "missing sensor source: $SENSOR_TARGET"
    return 0
  }
  unmount_path "$SENSOR_TARGET"
  mkdir -p "${SENSOR_PATCH_FILE%/*}"
  if "$PATCHCTL" sensor "$SENSOR_TARGET" "$SENSOR_PATCH_FILE" >>"$LOG_DIR/module.log" 2>&1; then
    chown root:root "$SENSOR_PATCH_FILE" 2>/dev/null || true
    chmod 644 "$SENSOR_PATCH_FILE" 2>/dev/null || true
    chcon u:object_r:same_process_hal_file:s0 "$SENSOR_PATCH_FILE" 2>/dev/null || true
    bind_file "$SENSOR_PATCH_FILE" "$SENSOR_TARGET" || true
  else
    log "sensor patch failed"
  fi
}

restore_runtime_mounts() {
  restore_property_profile_mounts
  unmount_path "$KEYMINT_TARGET"
  unmount_path "$SENSOR_TARGET"
  unmount_path "$ALIAS_ROOT/hw/${SENSOR_TARGET##*/}"
  unmount_path /proc/bootconfig
  unmount_path /vendor/lib64/egl
  unmount_path /vendor/lib64/hw
  unmount_path /vendor/lib64
  unmount_path /product/overlay
}

setup_vendor_aliases() {
  restore_runtime_mounts
  rm -rf "$ALIAS_ROOT"
  mkdir -p "$ALIAS_ROOT/egl" "$ALIAS_ROOT/hw"
  cp -a /vendor/lib64/egl/. "$ALIAS_ROOT/egl/"
  cp -a /vendor/lib64/hw/. "$ALIAS_ROOT/hw/"

  cd "$ALIAS_ROOT/egl" || return 1
  ln -f libEGL_emulation.so libEGL_mali.so 2>/dev/null || cp -a libEGL_emulation.so libEGL_mali.so
  ln -f libGLESv1_CM_emulation.so libGLESv1_CM_mali.so 2>/dev/null || cp -a libGLESv1_CM_emulation.so libGLESv1_CM_mali.so
  ln -f libGLESv2_emulation.so libGLESv2_mali.so 2>/dev/null || cp -a libGLESv2_emulation.so libGLESv2_mali.so
  rm -f libEGL_emulation.so libGLESv1_CM_emulation.so libGLESv2_emulation.so
  ln -s libEGL_mali.so libEGL_emulation.so
  ln -s libGLESv1_CM_mali.so libGLESv1_CM_emulation.so
  ln -s libGLESv2_mali.so libGLESv2_emulation.so

  cd "$ALIAS_ROOT/hw" || return 1
  ln -f gralloc.default.so gralloc.gs201.so 2>/dev/null || cp -a gralloc.default.so gralloc.gs201.so
  [ ! -f power.default.so ] || ln -f power.default.so power.gs201.so 2>/dev/null || cp -a power.default.so power.gs201.so
  [ ! -f vulkan.ranchu.so ] || ln -f vulkan.ranchu.so vulkan.mali.so 2>/dev/null || cp -a vulkan.ranchu.so vulkan.mali.so
  if [ -f android.hardware.graphics.mapper@3.0-impl-ranchu.so ]; then
    ln -f android.hardware.graphics.mapper@3.0-impl-ranchu.so android.hardware.graphics.mapper@3.0-impl-gs201.so 2>/dev/null || cp -a android.hardware.graphics.mapper@3.0-impl-ranchu.so android.hardware.graphics.mapper@3.0-impl-gs201.so
    rm -f android.hardware.graphics.mapper@3.0-impl-ranchu.so
    ln -s android.hardware.graphics.mapper@3.0-impl-gs201.so android.hardware.graphics.mapper@3.0-impl-ranchu.so
  elif [ -f mapper.ranchu.so ]; then
    ln -f mapper.ranchu.so mapper.gs201.so 2>/dev/null || cp -a mapper.ranchu.so mapper.gs201.so
    rm -f mapper.ranchu.so
    ln -s mapper.gs201.so mapper.ranchu.so
  fi
  if [ -e vulkan.mali.so ]; then
    rm -f vulkan.ranchu.so
    ln -s vulkan.mali.so vulkan.ranchu.so
  fi

  chown -R root:root "$ALIAS_ROOT"
  chmod -R a+rX "$ALIAS_ROOT"
  chcon_tree u:object_r:same_process_hal_file:s0 "$ALIAS_ROOT/egl"
  chcon_tree u:object_r:same_process_hal_file:s0 "$ALIAS_ROOT/hw"
  bind_dir "$ALIAS_ROOT/egl" /vendor/lib64/egl
  bind_dir "$ALIAS_ROOT/hw" /vendor/lib64/hw
}

setup_non_so_aliases() {
  if [ -e "$DEV_ORIGINAL" ] && [ ! -L "$DEV_ORIGINAL" ] && [ ! -e "$DEV_ALIAS" ]; then
    mv "$DEV_ORIGINAL" "$DEV_ALIAS"
  fi
  if [ -e "$DEV_ALIAS" ]; then
    rm -f "$DEV_ORIGINAL"
    ln -s "$DEV_ALIAS" "$DEV_ORIGINAL"
    chown -h system:system "$DEV_ORIGINAL" 2>/dev/null || true
    chcon -h u:object_r:qemu_device:s0 "$DEV_ORIGINAL" 2>/dev/null || true
  fi

  if [ -d /product/overlay ]; then
    rm -rf "$PRODUCT_OVERLAY_ALIAS_ROOT"
    mkdir -p "$PRODUCT_OVERLAY_ALIAS_ROOT"
    cp -a /product/overlay/. "$PRODUCT_OVERLAY_ALIAS_ROOT/"
    cd "$PRODUCT_OVERLAY_ALIAS_ROOT" || return 0
    if [ -f RanchuCommonOverlay.apk ]; then
      ln -f RanchuCommonOverlay.apk PixelCommonOverlay.apk 2>/dev/null || cp -a RanchuCommonOverlay.apk PixelCommonOverlay.apk
      rm -f RanchuCommonOverlay.apk
      ln -s PixelCommonOverlay.apk RanchuCommonOverlay.apk
    fi
    chown -R root:root "$PRODUCT_OVERLAY_ALIAS_ROOT"
    chmod -R a+rX "$PRODUCT_OVERLAY_ALIAS_ROOT"
    chcon_tree u:object_r:system_file:s0 "$PRODUCT_OVERLAY_ALIAS_ROOT"
    bind_dir "$PRODUCT_OVERLAY_ALIAS_ROOT" /product/overlay
  fi

  if [ -d /data/resource-cache ]; then
    cd /data/resource-cache || return 0
    [ -L product@overlay@RanchuCommonOverlay.apk@idmap ] && rm -f product@overlay@RanchuCommonOverlay.apk@idmap
    [ -L product@overlay@PixelCommonOverlay.apk@idmap ] && rm -f product@overlay@PixelCommonOverlay.apk@idmap
  fi
}

restore_non_so_aliases() {
  if [ -L "$DEV_ORIGINAL" ] && [ "$(readlink "$DEV_ORIGINAL" 2>/dev/null)" = "$DEV_ALIAS" ] && [ -e "$DEV_ALIAS" ]; then
    rm -f "$DEV_ORIGINAL"
    mv "$DEV_ALIAS" "$DEV_ORIGINAL" 2>/dev/null || true
    chown system:system "$DEV_ORIGINAL" 2>/dev/null || true
    chmod 666 "$DEV_ORIGINAL" 2>/dev/null || true
    chcon u:object_r:qemu_device:s0 "$DEV_ORIGINAL" 2>/dev/null || true
  fi
}

load_kpms() {
  [ -x /data/adb/ksud ] || return 0
  for module in "$MODDIR"/kpm/*.kpm; do
    [ -f "$module" ] || continue
    name=$(basename "$module" .kpm)
    /data/adb/ksud kpm list 2>/dev/null | grep -qx "$name" && continue
    /data/adb/ksud kpm load "$module" >>"$LOG_DIR/module.log" 2>&1 || true
  done
}

unload_kpms() {
  [ -x /data/adb/ksud ] || return 0
  /data/adb/ksud kpm control anti-detect "hide-path clear" >/dev/null 2>>"$LOG_DIR/module.log" || true
  /data/adb/ksud kpm unload anti-detect >>"$LOG_DIR/module.log" 2>&1 || true
  /data/adb/ksud kpm unload kpm-hide-maps >>"$LOG_DIR/module.log" 2>&1 || true
}

anti_detect_control() {
  [ -x /data/adb/ksud ] || return 0
  /data/adb/ksud kpm list 2>/dev/null | grep -qx anti-detect || return 0
  log "anti-detect control: $1"
  /data/adb/ksud kpm control anti-detect "$1" >/dev/null 2>>"$LOG_DIR/module.log" || true
}

sync_profile_serial() {
  local dst="/dev/__properties__/.profiles/$PROFILE/properties_serial"
  [ -f /dev/__properties__/properties_serial ] || return 0
  [ -d "/dev/__properties__/.profiles/$PROFILE" ] || return 0
  cp /dev/__properties__/properties_serial "$dst" 2>/dev/null || return 0
  chown root:root "$dst" 2>/dev/null || true
  chmod 444 "$dst" 2>/dev/null || true
  chcon u:object_r:properties_serial:s0 "$dst" 2>/dev/null || true
}

start_profile_serial_sync_daemon() {
  if [ -f "$SERIAL_SYNC_PID_FILE" ]; then
    old=$(cat "$SERIAL_SYNC_PID_FILE" 2>/dev/null)
    [ -n "$old" ] && kill "$old" 2>/dev/null || true
  fi
  (
    while [ -d "/dev/__properties__/.profiles/$PROFILE" ]; do
      if ! cmp -s /dev/__properties__/properties_serial "/dev/__properties__/.profiles/$PROFILE/properties_serial" 2>/dev/null; then
        sync_profile_serial
      fi
      sleep 1
    done
  ) >>"$LOG_DIR/module.log" 2>&1 &
  echo $! >"$SERIAL_SYNC_PID_FILE"
}

profile_set_prop() {
  "$PROPCTL" set-prop "$PROFILE" "$1" >>"$LOG_DIR/propctl-profile.log" 2>&1 || true
}

profile_del_prop() {
  case "$1" in
    vendor.qemu.sf.fake_camera) return 0 ;;
  esac
  "$PROPCTL" del-prop "$PROFILE" "$1" >>"$LOG_DIR/propctl-profile.log" 2>&1 || true
}

clean_runtime_emulator_props() {
  getprop 2>/dev/null |
    sed -n 's/^\[\([^]]*\)\]: \[\(.*\)\]$/\1=\2/p' |
    grep -Ei "$EMULATOR_PROP_PATTERN" |
    while IFS='=' read -r key value; do
      [ -n "$key" ] || continue
      case "$value" in
        *ranchu*|*Ranchu*|*goldfish*|*Goldfish*|*qemu*|*QEMU*|*emulator*|*Emulator*|*gfxxx*)
          profile_del_prop "$key"
          ;;
      esac
    done
}

clean_profile_emulator_string_props() {
  local profile_dir="/dev/__properties__/.profiles/$PROFILE"
  [ -d "$profile_dir" ] || return 0
  find "$profile_dir" -maxdepth 1 -type f 2>/dev/null |
    while IFS= read -r file; do
      case "${file##*/}" in
        properties_serial|property_info) continue ;;
      esac
      strings "$file" 2>/dev/null
    done |
    grep -Ei "$EMULATOR_PROP_PATTERN" |
    grep -E '^[A-Za-z0-9_.-]+[.][A-Za-z0-9_.-]+$' |
    sort -u |
    while IFS= read -r key; do
      [ -n "$key" ] && profile_del_prop "$key"
    done
}

set_runtime_profile_props() {
  while IFS= read -r prop; do
    [ -n "$prop" ] && profile_set_prop "$prop"
  done <<'EOF'
ro.boot.hardware=gs201
ro.hardware=gs201
ro.board.platform=gs201
ro.hardware.egl=mali
ro.hardware.gralloc=gs201
ro.hardware.vulkan=mali
ro.hardware.power=gs201
ro.product.model=Pixel 7 Pro
ro.product.manufacturer=Google
ro.product.brand=google
ro.product.name=cheetah
ro.product.device=cheetah
ro.product.board=cheetah
ro.build.product=cheetah
ro.build.characteristics=nosdcard
ro.build.flavor=cheetah-user
ro.build.id=AP1A.240505.005
ro.build.display.id=AP1A.240505.005.11677807
ro.build.version.incremental=11677807
ro.build.version.security_patch=2024-05-05
ro.build.description=cheetah-user 14 AP1A.240505.005 11677807 release-keys
ro.build.fingerprint=google/cheetah/cheetah:14/AP1A.240505.005/11677807:user/release-keys
ro.product.build.fingerprint=google/cheetah/cheetah:14/AP1A.240505.005/11677807:user/release-keys
ro.vendor.build.fingerprint=google/cheetah/cheetah:14/AP1A.240505.005/11677807:user/release-keys
ro.system.build.fingerprint=google/cheetah/cheetah:14/AP1A.240505.005/11677807:user/release-keys
ro.odm.build.fingerprint=google/cheetah/cheetah:14/AP1A.240505.005/11677807:user/release-keys
ro.bootimage.build.fingerprint=google/cheetah/cheetah:14/AP1A.240505.005/11677807:user/release-keys
ro.bootimage.build.id=AP1A.240505.005
ro.bootimage.build.display.id=AP1A.240505.005.11677807
ro.bootimage.build.version.incremental=11677807
ro.bootimage.build.version.release=14
ro.bootimage.build.version.release_or_codename=14
ro.bootimage.build.version.sdk=34
ro.bootimage.build.type=user
ro.bootimage.build.tags=release-keys
ro.bootimage.build.date=Fri May 3 12:00:00 UTC 2024
ro.bootimage.build.date.utc=1714737600
ro.product.bootimage.brand=google
ro.product.bootimage.device=cheetah
ro.product.bootimage.manufacturer=Google
ro.product.bootimage.model=Pixel 7 Pro
ro.product.bootimage.name=cheetah
ro.build.type=user
ro.build.tags=release-keys
ro.boot.verifiedbootstate=green
ro.boot.flash.locked=1
ro.boot.vbmeta.device_state=locked
ro.boot.veritymode=enforcing
ro.boot.hardware.vulkan=mali
ro.soc.model=Tensor G2
vendor.qemu.sf.fake_camera=both
EOF
}

alias_property_area_name() {
  local name="$1"
  local alias
  case "$name" in
    *qemu*|*goldfish*|*ranchu*|*emulation*)
      alias=$(printf '%s' "$name" | sed 's/qemu/gs20/g; s/goldfish/cheetahx/g; s/ranchu/gs201x/g; s/emulation/physicalx/g')
      [ "$alias" != "$name" ] && printf '%s\n' "$alias"
      ;;
  esac
}

is_emulator_property_area_name() {
  case "$1" in
    *qemu*|*goldfish*|*ranchu*|*emulation*) return 0 ;;
    *) return 1 ;;
  esac
}

prepare_property_area_aliases() {
  local profile_dir="/dev/__properties__/.profiles/$PROFILE"
  local src name alias dst
  [ -d "$profile_dir" ] || return 0
  for src in "$profile_dir"/*; do
    [ -f "$src" ] || continue
    name=${src##*/}
    case "$name" in
      props.txt|properties_serial|property_info) continue ;;
    esac
    alias=$(alias_property_area_name "$name")
    [ -n "$alias" ] || continue
    dst="$profile_dir/$alias"
    cp -p "$src" "$dst" 2>/dev/null || cp "$src" "$dst" || continue
    chown root:root "$dst" 2>/dev/null || true
    chmod 444 "$dst" 2>/dev/null || true
    log "property area alias: $name -> $alias"
  done
}

sanitize_property_info() {
  local dst="/dev/__properties__/.profiles/$PROFILE/property_info"
  [ -x "$PATCHCTL" ] || return 0
  [ -f "$dst" ] || return 0
  "$PATCHCTL" property-info "$dst" "$dst" >>"$LOG_DIR/module.log" 2>&1 || {
    log "property_info patch failed"
    return 0
  }
  chown root:root "$dst" 2>/dev/null || true
  chmod 444 "$dst" 2>/dev/null || true
  chcon u:object_r:property_info:s0 "$dst" 2>/dev/null || true
}

create_profile_with_propctl() {
  [ -x "$PROPCTL" ] || return 1
  rm -f "$LOG_DIR/propctl-profile.log"
  restore_property_profile_mounts
  rm -rf "/dev/__properties__/.profiles/$PROFILE"
  mkdir -p /dev/__properties__/.profiles
  cd "$WORK_DIR" || return 1
  log "creating runtime property profile: $PROFILE"
  "$PROPCTL" dump-props "$PROFILE" >>"$LOG_DIR/propctl-profile.log" 2>&1 || return 1
  clean_runtime_emulator_props
  clean_profile_emulator_string_props
  set_runtime_profile_props
  rm -f "/dev/__properties__/.profiles/$PROFILE/props.txt"
  sanitize_property_info
  "$PROPCTL" repack-props "$PROFILE" >>"$LOG_DIR/propctl-profile.log" 2>&1 || true
  prepare_property_area_aliases
  rm -f "/dev/__properties__/.profiles/$PROFILE/props.txt"
  sync_profile_serial
}

ensure_profile() {
  create_profile_with_propctl || log "profile setup failed"
}

restore_property_profile_mounts() {
  local profile_dir="/dev/__properties__/.profiles/$PROFILE"
  local src name target
  unmount_path /dev/__properties__
  [ -d "$profile_dir" ] || return 0
  for src in "$profile_dir"/*; do
    [ -f "$src" ] || continue
    name=${src##*/}
    [ "$name" = "props.txt" ] && continue
    target="/dev/__properties__/$name"
    [ -e "$target" ] && unmount_path "$target"
  done
}

apply_global_property_profile() {
  local profile_dir="/dev/__properties__/.profiles/$PROFILE"
  local src name target failed alias
  [ -d "$profile_dir" ] || return 1
  log "applying property profile by global file bind mounts"
  sync_profile_serial
  rm -f /dev/__properties__/.active 2>/dev/null || true
  : >"$BLOCKED_PROP_AREA"
  chown root:root "$BLOCKED_PROP_AREA" 2>/dev/null || true
  chmod 000 "$BLOCKED_PROP_AREA" 2>/dev/null || true
  chcon u:object_r:properties_device:s0 "$BLOCKED_PROP_AREA" 2>/dev/null || true
  failed=0
  for src in "$profile_dir"/*; do
    [ -f "$src" ] || continue
    name=${src##*/}
    [ "$name" = "props.txt" ] && continue
    if is_emulator_property_area_name "$name"; then
      alias=$(alias_property_area_name "$name")
      [ -n "$alias" ] && [ -f "$profile_dir/$alias" ] && continue
    fi
    target="/dev/__properties__/$name"
    if [ ! -e "$target" ]; then
      : >"$target" 2>/dev/null || {
        log "missing property target: $target"
        failed=1
        continue
      }
      chown root:root "$target" 2>/dev/null || true
      chmod 444 "$target" 2>/dev/null || true
    fi
    bind_path_global "$src" "$target" || {
      log "failed to bind property file: $name"
      failed=1
    }
  done
  for src in "$profile_dir"/*; do
    [ -f "$src" ] || continue
    name=${src##*/}
    is_emulator_property_area_name "$name" || continue
    target="/dev/__properties__/$name"
    [ -e "$target" ] || continue
    bind_path_global "$BLOCKED_PROP_AREA" "$target" || log "failed to block property file: $name"
  done
  register_hidden_property_area_paths
  return "$failed"
}

register_hidden_property_area_paths() {
  local profile_dir="/dev/__properties__/.profiles/$PROFILE"
  local src name
  [ -d "$profile_dir" ] || return 0
  anti_detect_control "hide-path clear"
  for src in "$profile_dir"/*; do
    [ -f "$src" ] || continue
    name=${src##*/}
    is_emulator_property_area_name "$name" || continue
    anti_detect_control "hide-path add /dev/__properties__/$name"
  done
  anti_detect_control "hide-path list"
}

start_runtime_profile_worker() {
  if [ -f "$PROFILE_WORKER_PID_FILE" ]; then
    old=$(cat "$PROFILE_WORKER_PID_FILE" 2>/dev/null)
    [ -n "$old" ] && kill "$old" 2>/dev/null || true
  fi
  (
    i=0
    while [ "$i" -lt 180 ]; do
      [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ] && break
      sleep 1
      i=$((i + 1))
    done
    sleep 5
    ensure_profile
    apply_global_property_profile || log "global property mount failed"
    restart_runtime_services
    am force-stop "$HUNTER_PACKAGE" 2>/dev/null || true
    sleep 3
    write_status
    log "runtime profile worker done"
  ) >>"$LOG_DIR/module.log" 2>&1 &
  echo $! >"$PROFILE_WORKER_PID_FILE"
}

restart_runtime_services() {
  setprop ctl.restart vendor.keymint-default 2>/dev/null || true
  setprop ctl.restart keystore2 2>/dev/null || true
  setprop ctl.restart vendor.camera-provider-2-7-google 2>/dev/null || true
  setprop ctl.restart cameraserver 2>/dev/null || true
}

write_status() {
  {
    echo "fake_camera=$(getprop vendor.qemu.sf.fake_camera)"
    dumpsys media.camera 2>/dev/null | sed -n 's/^Number of normal camera devices: /camera_count=/p; s/^    Device /camera_device /p' | head -8
    echo "kpms:"
    [ -x /data/adb/ksud ] && /data/adb/ksud kpm list 2>/dev/null || true
    echo "mounts:"
    echo "property_mount_count=$(mount | grep -c '/dev/__properties__/')"
    mount | grep -E ' /dev/__properties__ ' || true
    mount | grep -E '/proc/bootconfig|/vendor/lib64|/product/overlay|vendor_alias|product_overlay_alias|libpuresoftkeymasterdevice' || true
  } >"$LOG_DIR/status.log" 2>&1
}

main_post_fs_data() {
  mkdir -p "$WORK_DIR" "$LOG_DIR"
  log "post-fs-data start"
  ensure_module_permissions
  load_kpms
  setup_vendor_aliases
  setup_non_so_aliases
  setup_bootconfig
  setup_keymint
  setup_sensor
  log "post-fs-data done"
}

main_service() {
  mkdir -p "$WORK_DIR" "$LOG_DIR"
  log "service start"
  ensure_module_permissions
  load_kpms
  setup_bootconfig
  setup_keymint
  setup_sensor
  restart_runtime_services
  start_runtime_profile_worker
  log "service done"
}

main_restore_runtime() {
  mkdir -p "$WORK_DIR" "$LOG_DIR"
  log "restore runtime"
  if [ -f "$SERIAL_SYNC_PID_FILE" ]; then
    old=$(cat "$SERIAL_SYNC_PID_FILE" 2>/dev/null)
    [ -n "$old" ] && kill "$old" 2>/dev/null || true
    rm -f "$SERIAL_SYNC_PID_FILE"
  fi
  if [ -f "$PROFILE_WORKER_PID_FILE" ]; then
    old=$(cat "$PROFILE_WORKER_PID_FILE" 2>/dev/null)
    [ -n "$old" ] && kill "$old" 2>/dev/null || true
    rm -f "$PROFILE_WORKER_PID_FILE"
  fi
  restore_runtime_mounts
  rm -rf "/dev/__properties__/.profiles/$PROFILE" 2>/dev/null || true
  restore_non_so_aliases
  unload_kpms
  rm -rf "$WORK_DIR"
}
