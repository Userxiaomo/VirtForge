pub fn validate_libvirt_network_config(
    network_name: &str,
    bridge_name: &str,
) -> anyhow::Result<()> {
    validate_libvirt_identifier("network_name", network_name)?;
    validate_libvirt_identifier("bridge_name", bridge_name)?;
    Ok(())
}

pub fn validate_libvirt_identifier(field: &str, value: &str) -> anyhow::Result<()> {
    if value.is_empty()
        || value.len() > 64
        || !value
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.')
    {
        anyhow::bail!("{field} must be 1-64 ASCII letters, numbers, dots, dashes or underscores");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::validate_libvirt_network_config;

    #[test]
    fn libvirt_network_config_accepts_default_names() {
        validate_libvirt_network_config("default", "virbr0").expect("default network config");
    }

    #[test]
    fn libvirt_network_config_rejects_shell_like_values() {
        let error = validate_libvirt_network_config("default;reboot", "virbr0")
            .expect_err("unsafe network name");
        assert!(error.to_string().contains("network_name"));

        let error = validate_libvirt_network_config("default", "../virbr0")
            .expect_err("unsafe bridge name");
        assert!(error.to_string().contains("bridge_name"));
    }
}
