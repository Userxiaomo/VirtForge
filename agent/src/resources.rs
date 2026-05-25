use std::{
    fs,
    path::Path,
    process::{Command, Stdio},
};

use anyhow::Context;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ResourceSnapshot {
    pub cpu_total: u64,
    pub cpu_used: u64,
    pub memory_total: u64,
    pub memory_used: u64,
    pub disk_total: u64,
    pub disk_used: u64,
    pub vm_count: u32,
}

pub fn collect(data_dir: &Path) -> ResourceSnapshot {
    let (memory_total, memory_used) = memory_snapshot()
        .map(|memory| (memory.total_bytes, memory.used_bytes))
        .unwrap_or((0, 0));
    let (disk_total, disk_used) = disk_snapshot(data_dir)
        .map(|disk| (disk.total_bytes, disk.used_bytes))
        .unwrap_or((0, 0));

    ResourceSnapshot {
        cpu_total: cpu_total(),
        // CPU usage needs a time window. Keep it explicit instead of reporting a fake instant value.
        cpu_used: 0,
        memory_total,
        memory_used,
        disk_total,
        disk_used,
        vm_count: count_managed_vms(data_dir),
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct MemorySnapshot {
    total_bytes: u64,
    used_bytes: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct DiskSnapshot {
    total_bytes: u64,
    used_bytes: u64,
}

fn cpu_total() -> u64 {
    std::thread::available_parallelism()
        .map(|count| count.get() as u64)
        .unwrap_or(0)
}

fn memory_snapshot() -> anyhow::Result<MemorySnapshot> {
    let contents = fs::read_to_string("/proc/meminfo").context("unable to read /proc/meminfo")?;
    parse_meminfo(&contents).context("unable to parse /proc/meminfo")
}

fn parse_meminfo(contents: &str) -> anyhow::Result<MemorySnapshot> {
    let mut total_kib = None;
    let mut available_kib = None;

    for line in contents.lines() {
        if let Some(value) = line.strip_prefix("MemTotal:") {
            total_kib = Some(parse_meminfo_kib(value)?);
        } else if let Some(value) = line.strip_prefix("MemAvailable:") {
            available_kib = Some(parse_meminfo_kib(value)?);
        }
    }

    let total_bytes = total_kib.context("MemTotal missing")?.saturating_mul(1024);
    let available_bytes = available_kib
        .context("MemAvailable missing")?
        .saturating_mul(1024);
    Ok(MemorySnapshot {
        total_bytes,
        used_bytes: total_bytes.saturating_sub(available_bytes),
    })
}

fn parse_meminfo_kib(value: &str) -> anyhow::Result<u64> {
    value
        .split_whitespace()
        .next()
        .context("meminfo value missing")?
        .parse::<u64>()
        .context("meminfo value is not a number")
}

fn disk_snapshot(data_dir: &Path) -> anyhow::Result<DiskSnapshot> {
    ensure_real_directory("data_dir", data_dir)?;
    let output = Command::new("df")
        .args(["-B1", "--output=size,used"])
        .arg(data_dir)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .context("unable to run df")?;

    if !output.status.success() {
        anyhow::bail!("df failed with status {}", output.status);
    }

    let stdout = String::from_utf8(output.stdout).context("df output was not UTF-8")?;
    parse_df_output(&stdout).context("unable to parse df output")
}

fn parse_df_output(output: &str) -> anyhow::Result<DiskSnapshot> {
    for line in output.lines() {
        let mut columns = line.split_whitespace();
        let Some(size) = columns.next() else {
            continue;
        };
        let Some(used) = columns.next() else {
            continue;
        };
        if !size.chars().all(|c| c.is_ascii_digit()) {
            continue;
        }

        return Ok(DiskSnapshot {
            total_bytes: size.parse().context("df size is not a number")?,
            used_bytes: used.parse().context("df used is not a number")?,
        });
    }

    anyhow::bail!("df data row missing")
}

fn ensure_real_directory(name: &str, path: &Path) -> anyhow::Result<()> {
    let metadata = fs::symlink_metadata(path)
        .with_context(|| format!("unable to read {name} metadata: {}", path.display()))?;
    if metadata.file_type().is_symlink() {
        anyhow::bail!("{name} must not be a symlink: {}", path.display());
    }
    if !metadata.is_dir() {
        anyhow::bail!("{name} must be a directory: {}", path.display());
    }
    Ok(())
}

fn count_managed_vms(data_dir: &Path) -> u32 {
    if ensure_real_directory("data_dir", data_dir).is_err() {
        return 0;
    }
    let vm_dir = data_dir.join("vms");
    if ensure_real_directory("vm_dir", &vm_dir).is_err() {
        return 0;
    }
    let Ok(entries) = fs::read_dir(vm_dir) else {
        return 0;
    };

    entries
        .filter_map(Result::ok)
        .filter(|entry| entry.file_type().map(|ty| ty.is_dir()).unwrap_or(false))
        .count()
        .try_into()
        .unwrap_or(u32::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_meminfo_bytes() {
        let parsed = parse_meminfo(
            r#"
MemTotal:        2048 kB
MemFree:          512 kB
MemAvailable:    1024 kB
"#,
        )
        .expect("parse meminfo");

        assert_eq!(parsed.total_bytes, 2_097_152);
        assert_eq!(parsed.used_bytes, 1_048_576);
    }

    #[test]
    fn parses_df_output_bytes() {
        let parsed = parse_df_output(
            r#"
   1B-blocks    Used
  104857600 4096
"#,
        )
        .expect("parse df");

        assert_eq!(parsed.total_bytes, 104_857_600);
        assert_eq!(parsed.used_bytes, 4_096);
    }

    #[test]
    fn resource_collection_does_not_create_missing_data_dir() {
        let data_dir =
            std::env::temp_dir().join(format!("vps-agent-resource-{}", uuid::Uuid::new_v4()));

        let snapshot = collect(&data_dir);

        assert_eq!(snapshot.disk_total, 0);
        assert_eq!(snapshot.disk_used, 0);
        assert_eq!(snapshot.vm_count, 0);
        assert!(
            !data_dir.exists(),
            "resource collection must not create {}",
            data_dir.display()
        );
    }

    #[cfg(unix)]
    #[test]
    fn disk_snapshot_rejects_symlinked_data_dir() {
        let temp_root =
            std::env::temp_dir().join(format!("vps-agent-resource-{}", uuid::Uuid::new_v4()));
        let real_data_dir = temp_root.join("real-data");
        let data_dir = temp_root.join("data-link");
        fs::create_dir_all(&real_data_dir).unwrap();
        std::os::unix::fs::symlink(&real_data_dir, &data_dir).unwrap();

        let error = disk_snapshot(&data_dir).expect_err("symlinked data_dir must not be measured");

        assert!(
            error.to_string().contains("data_dir") && error.to_string().contains("symlink"),
            "unexpected error: {error}"
        );
    }

    #[cfg(unix)]
    #[test]
    fn count_managed_vms_does_not_follow_symlinked_data_dir() {
        let temp_root =
            std::env::temp_dir().join(format!("vps-agent-resource-{}", uuid::Uuid::new_v4()));
        let real_data_dir = temp_root.join("real-data");
        let data_dir = temp_root.join("data-link");
        fs::create_dir_all(
            real_data_dir
                .join("vms")
                .join(uuid::Uuid::new_v4().to_string()),
        )
        .unwrap();
        std::os::unix::fs::symlink(&real_data_dir, &data_dir).unwrap();

        let vm_count = count_managed_vms(&data_dir);

        assert_eq!(vm_count, 0);
    }

    #[cfg(unix)]
    #[test]
    fn count_managed_vms_does_not_follow_symlinked_vm_parent() {
        let data_dir =
            std::env::temp_dir().join(format!("vps-agent-resource-{}", uuid::Uuid::new_v4()));
        let real_vm_dir = data_dir.join("real-vms");
        let vm_dir = data_dir.join("vms");
        fs::create_dir_all(real_vm_dir.join(uuid::Uuid::new_v4().to_string())).unwrap();
        std::os::unix::fs::symlink(&real_vm_dir, &vm_dir).unwrap();

        let vm_count = count_managed_vms(&data_dir);

        assert_eq!(vm_count, 0);
    }
}
