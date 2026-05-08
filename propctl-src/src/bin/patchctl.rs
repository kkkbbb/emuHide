use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process;

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

const KEYMINT_LOCK_ORIG: &[u8] = &[
    0x4a, 0x00, 0x80, 0x52, 0x1f, 0x90, 0x00, 0x39, 0x0a, 0x20, 0x00, 0xb9,
];
const KEYMINT_LOCK_PATCH: &[u8] = &[
    0x2a, 0x00, 0x80, 0x52, 0x0a, 0x90, 0x00, 0x39, 0x1f, 0x20, 0x00, 0xb9,
];
const KEYMINT_LOCK_OFFSETS: &[usize] = &[0xe5b8, 0x116a8];
const KEYMINT_ZERO_ROOT_HEX: &[u8] =
    b"0000000000000000000000000000000000000000000000000000000000000000";
const KEYMINT_ROOT_HEX: &[u8] =
    b"60c39051c6cfdb18db2fd0ad8068b41e55a0a96e16bffe5156c0ee61a22b00bf";

const SENSOR_REPLACEMENTS: &[(&[u8], &[u8])] = &[
    (
        b"Goldfish 3-axis Magnetic field sensor (uncalibrated)",
        b"AK09918 Magnetometer Uncalibrated",
    ),
    (
        b"Goldfish 3-axis Accelerometer Uncalibrated",
        b"LSM6DSO Accelerometer Uncalibrated",
    ),
    (
        b"Goldfish 3-axis Gyroscope (uncalibrated)",
        b"LSM6DSO Gyroscope Uncalibrated",
    ),
    (b"Goldfish Ambient Temperature sensor", b"BMP380 Ambient Temperature"),
    (b"Goldfish 3-axis Magnetic field sensor", b"AK09918 Magnetometer"),
    (b"Goldfish 3-axis Accelerometer", b"LSM6DSO Accelerometer"),
    (b"Goldfish 3-axis Gyroscope", b"LSM6DSO Gyroscope"),
    (b"Goldfish wrist tilt gesture sensor", b"Wrist Tilt Gesture Sensor"),
    (b"The Android Open Source Project", b"Google LLC"),
    (b"Goldfish Heart rate sensor", b"MAX86176 Heart Rate Sensor"),
    (b"Goldfish hinge sensor1 (in degrees)", b"Fold Angle Sensor1 (degrees)"),
    (b"Goldfish Orientation sensor", b"Orientation Sensor"),
    (b"Goldfish Proximity sensor", b"TMD3719 Proximity Sensor"),
    (b"Goldfish Humidity sensor", b"SHTC3 Humidity Sensor"),
    (b"Goldfish hinge sensor0 (in degrees)", b"Fold Angle Sensor0 (degrees)"),
    (b"Goldfish hinge sensor2 (in degrees)", b"Fold Angle Sensor2 (degrees)"),
    (b"Goldfish Pressure sensor", b"BMP380 Pressure Sensor"),
    (b"Goldfish Light sensor", b"TMD3719 Light Sensor"),
];

fn usage() -> ! {
    eprintln!("usage: patchctl <keymint|sensor> <source> <dest>");
    process::exit(2);
}

fn replace_all(data: &mut [u8], from: &[u8], to: &[u8]) -> Result<usize> {
    if to.len() > from.len() {
        return Err(format!(
            "replacement is longer than source: {} > {}",
            to.len(),
            from.len()
        )
        .into());
    }
    if from.is_empty() {
        return Ok(0);
    }

    let mut count = 0;
    let mut i = 0;
    while i + from.len() <= data.len() {
        if &data[i..i + from.len()] == from {
            data[i..i + to.len()].copy_from_slice(to);
            for b in &mut data[i + to.len()..i + from.len()] {
                *b = 0;
            }
            count += 1;
            i += from.len();
        } else {
            i += 1;
        }
    }
    Ok(count)
}

fn contains(data: &[u8], needle: &[u8]) -> bool {
    needle.len() <= data.len() && data.windows(needle.len()).any(|window| window == needle)
}

fn write_output(dst: &Path, data: &[u8]) -> Result<()> {
    if let Some(parent) = dst.parent() {
        fs::create_dir_all(parent)?;
    }
    let tmp = tmp_path(dst);
    fs::write(&tmp, data)?;
    fs::rename(&tmp, dst)?;
    Ok(())
}

fn tmp_path(dst: &Path) -> PathBuf {
    let mut name = dst
        .file_name()
        .map(|n| n.to_os_string())
        .unwrap_or_else(|| "patchctl.out".into());
    name.push(format!(".tmp.{}", process::id()));
    dst.with_file_name(name)
}

fn patch_keymint(src: &Path, dst: &Path) -> Result<()> {
    let mut data = fs::read(src)?;
    let mut lock_patches = 0;
    let mut known_layout = true;

    for offset in KEYMINT_LOCK_OFFSETS {
        let end = offset + KEYMINT_LOCK_ORIG.len();
        if end > data.len() {
            known_layout = false;
            continue;
        }
        let slot = &mut data[*offset..end];
        if slot == KEYMINT_LOCK_ORIG {
            slot.copy_from_slice(KEYMINT_LOCK_PATCH);
            lock_patches += 1;
        } else if slot != KEYMINT_LOCK_PATCH {
            known_layout = false;
        }
    }

    if !known_layout {
        lock_patches += replace_all(&mut data, KEYMINT_LOCK_ORIG, KEYMINT_LOCK_PATCH)?;
    }

    let root_patches = replace_all(&mut data, KEYMINT_ZERO_ROOT_HEX, KEYMINT_ROOT_HEX)?;
    if root_patches == 0 && !contains(&data, KEYMINT_ROOT_HEX) {
        return Err("unsupported KeyMint RootOfTrust hash layout".into());
    }
    if lock_patches == 0 && !contains(&data, KEYMINT_LOCK_PATCH) {
        return Err("unsupported KeyMint lock-state layout".into());
    }

    write_output(dst, &data)?;
    println!(
        "keymint patched: lock_patches={} root_patches={}",
        lock_patches, root_patches
    );
    Ok(())
}

fn patch_sensor(src: &Path, dst: &Path) -> Result<()> {
    let mut data = fs::read(src)?;
    let mut total = 0;

    for (from, to) in SENSOR_REPLACEMENTS {
        total += replace_all(&mut data, from, to)?;
    }

    let already_patched = SENSOR_REPLACEMENTS
        .iter()
        .any(|(_, to)| contains(&data, to));
    if total == 0 && !already_patched {
        return Err("no known Goldfish sensor strings were found".into());
    }

    write_output(dst, &data)?;
    println!("sensor patched: replacements={}", total);
    Ok(())
}

fn main() -> Result<()> {
    let mut args = env::args_os();
    let _program = args.next();
    let mode = args.next().unwrap_or_else(|| usage());
    let src = args.next().unwrap_or_else(|| usage());
    let dst = args.next().unwrap_or_else(|| usage());
    if args.next().is_some() {
        usage();
    }

    match mode.to_string_lossy().as_ref() {
        "keymint" => patch_keymint(Path::new(&src), Path::new(&dst)),
        "sensor" => patch_sensor(Path::new(&src), Path::new(&dst)),
        _ => usage(),
    }
}
