use std::path::{Component, Path};

pub fn is_path_under_agent_data_dir(path: &Path, data_dir: &Path) -> bool {
    let Ok(path) = path.canonicalize() else {
        return false;
    };
    let Ok(data_dir) = data_dir.canonicalize() else {
        return false;
    };

    path.starts_with(data_dir)
}

pub fn validate_safe_file_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 96
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.')
        && !name.split('.').any(|part| part == ".." || part.is_empty())
}

pub fn reject_path_traversal(path: &Path) -> bool {
    path.components()
        .all(|component| !matches!(component, Component::ParentDir))
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use super::{reject_path_traversal, validate_safe_file_name};

    #[test]
    fn safe_file_name_rejects_path_like_values() {
        assert!(validate_safe_file_name("debian-12.qcow2"));
        assert!(!validate_safe_file_name("../debian.qcow2"));
        assert!(!validate_safe_file_name("bad/name"));
        assert!(!validate_safe_file_name("bad..name"));
        assert!(!validate_safe_file_name(""));
    }

    #[test]
    fn traversal_detector_rejects_parent_components() {
        assert!(reject_path_traversal(Path::new("vm/demo/disk.qcow2")));
        assert!(!reject_path_traversal(Path::new("vm/../host")));
    }
}
