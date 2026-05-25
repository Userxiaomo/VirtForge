use std::{
    fs::{self, OpenOptions},
    future::Future,
    io::Write,
    path::{Path, PathBuf},
    pin::Pin,
    process::Stdio,
    sync::Arc,
    time::Duration,
};

use anyhow::{bail, Context};
use tokio::process::Command;
use vps_shared::{CreateVmRequest, HostPreflightCheck, TaskKind, VmId};

use crate::{
    network, redaction,
    security::{is_path_under_agent_data_dir, reject_path_traversal, validate_safe_file_name},
};

const MAX_DOMAIN_XML_BYTES: u64 = 1024 * 1024;
const DOMAIN_STATE_POLL_ATTEMPTS: usize = 60;
const HOST_COMMAND_TIMEOUT: Duration = Duration::from_secs(300);

type CommandFuture<'a> = Pin<Box<dyn Future<Output = anyhow::Result<String>> + Send + 'a>>;

trait CommandRunner: std::fmt::Debug + Send + Sync {
    fn run<'a>(&'a self, program: &'a str, args: &'a [&'a str]) -> CommandFuture<'a>;
}

#[derive(Clone, Debug)]
struct SystemCommandRunner;

impl CommandRunner for SystemCommandRunner {
    fn run<'a>(&'a self, program: &'a str, args: &'a [&'a str]) -> CommandFuture<'a> {
        Box::pin(run_command(program, args))
    }
}

#[derive(Clone, Debug)]
pub enum LibvirtStatus {
    NotChecked,
    Available,
    Unavailable,
}

#[derive(Clone, Debug)]
pub struct LibvirtExecutor {
    data_dir: PathBuf,
    image_dir: PathBuf,
    network_name: String,
    bridge_name: String,
    command_runner: Arc<dyn CommandRunner>,
}

#[derive(Clone, Debug)]
pub struct VmPaths {
    pub vm_dir: PathBuf,
    pub disk_path: PathBuf,
    pub seed_iso_path: PathBuf,
    pub network_config_path: PathBuf,
    pub domain_xml_path: PathBuf,
}

#[derive(Clone, Debug)]
struct ReinstallTempPaths {
    disk_path: PathBuf,
    seed_iso_path: PathBuf,
    user_data_path: PathBuf,
    meta_data_path: PathBuf,
}

impl ReinstallTempPaths {
    fn for_vm(paths: &VmPaths) -> Self {
        Self {
            disk_path: paths.vm_dir.join("disk.qcow2.reinstalling"),
            seed_iso_path: paths.vm_dir.join("seed.iso.reinstalling"),
            user_data_path: paths.vm_dir.join("user-data.reinstalling"),
            meta_data_path: paths.vm_dir.join("meta-data.reinstalling"),
        }
    }

    fn paths(&self) -> [&Path; 4] {
        [
            self.disk_path.as_path(),
            self.seed_iso_path.as_path(),
            self.user_data_path.as_path(),
            self.meta_data_path.as_path(),
        ]
    }
}

struct ReinstallArtifactRequest<'a> {
    base_image: &'a Path,
    disk_gb: u32,
    name: &'a str,
    ssh_public_key: Option<&'a str>,
    vm_id: VmId,
    temp_paths: &'a ReinstallTempPaths,
    network_config_path: Option<&'a Path>,
}

impl LibvirtExecutor {
    pub fn new(
        data_dir: PathBuf,
        image_dir: PathBuf,
        network_name: String,
        bridge_name: String,
    ) -> Self {
        Self {
            data_dir,
            image_dir,
            network_name,
            bridge_name,
            command_runner: Arc::new(SystemCommandRunner),
        }
    }

    #[cfg(test)]
    fn with_command_runner(mut self, command_runner: Arc<dyn CommandRunner>) -> Self {
        self.command_runner = command_runner;
        self
    }

    async fn run_command(&self, program: &str, args: &[&str]) -> anyhow::Result<String> {
        self.command_runner.run(program, args).await
    }

    async fn run_virsh(&self, args: &[&str]) -> anyhow::Result<String> {
        self.run_command("virsh", args).await
    }

    pub async fn execute(&self, task: &TaskKind) -> anyhow::Result<Vec<String>> {
        let mut logs = self.check_host().await?;
        match task {
            TaskKind::CreateVm(request) => logs.extend(self.create_vm(request).await?),
            TaskKind::StartVm { vm_id } => {
                logs.extend(self.virsh_vm_command("start", *vm_id).await?)
            }
            TaskKind::StopVm { vm_id } => {
                logs.extend(self.virsh_vm_command("shutdown", *vm_id).await?)
            }
            TaskKind::RebootVm { vm_id } => {
                logs.extend(self.virsh_vm_command("reboot", *vm_id).await?)
            }
            TaskKind::ReinstallVm {
                vm_id,
                name,
                image,
                ssh_public_key,
                disk_gb,
            } => logs.extend(
                self.reinstall_vm(*vm_id, name, image, ssh_public_key.as_deref(), *disk_gb)
                    .await?,
            ),
            TaskKind::DeleteVm { vm_id } => logs.extend(self.delete_vm(*vm_id).await?),
        }
        Ok(logs)
    }

    pub async fn check_host(&self) -> anyhow::Result<Vec<String>> {
        let checks = self.check_host_report().await;
        if let Some(failed) = checks.iter().find(|check| check.status == "failed") {
            bail!("host preflight {} failed: {}", failed.name, failed.message);
        }

        let mut logs = vec![format!("host preflight: {}", self.preflight_context())];
        logs.extend(
            checks
                .into_iter()
                .map(|check| format!("host preflight: {}: {}", check.name, check.message)),
        );

        Ok(logs)
    }

    pub async fn check_host_report(&self) -> Vec<HostPreflightCheck> {
        let mut checks = Vec::new();
        checks.push(match self.check_storage_layout() {
            Ok(message) => passed_check("storage", &message),
            Err(error) => failed_check("storage", &error.to_string()),
        });
        checks.push(match require_kvm_character_device("/dev/kvm") {
            Ok(()) => passed_check("kvm", "/dev/kvm is available"),
            Err(error) => failed_check("kvm", &error.to_string()),
        });
        checks.push(
            match self
                .run_virsh(&["--connect", "qemu:///system", "version"])
                .await
            {
                Ok(_) => passed_check("libvirt", "qemu:///system is available"),
                Err(error) => failed_check("libvirt", &error.to_string()),
            },
        );
        checks.push(match self.check_network_config().await {
            Ok(message) => passed_check("libvirt-network", &message),
            Err(error) => failed_check("libvirt-network", &error.to_string()),
        });
        checks.push(match self.check_bridge() {
            Ok(message) => passed_check("bridge", &message),
            Err(error) => failed_check("bridge", &error.to_string()),
        });
        checks.push(match self.run_command("qemu-img", &["--version"]).await {
            Ok(_) => passed_check("qemu-img", "qemu-img is available"),
            Err(error) => failed_check("qemu-img", &error.to_string()),
        });
        checks.push(match self.detect_seed_iso_tool().await {
            Ok(tool) => passed_check("cloud-init-iso", &format!("{tool} is available")),
            Err(error) => failed_check("cloud-init-iso", &error.to_string()),
        });
        checks
    }

    pub async fn check_host_report_and_status(&self) -> (LibvirtStatus, Vec<HostPreflightCheck>) {
        let checks = self.check_host_report().await;
        let status = if checks.iter().all(|check| check.status == "passed") {
            LibvirtStatus::Available
        } else {
            LibvirtStatus::Unavailable
        };
        (status, checks)
    }

    pub fn status_label(status: &LibvirtStatus) -> &'static str {
        match status {
            LibvirtStatus::NotChecked => "not_checked",
            LibvirtStatus::Available => "available",
            LibvirtStatus::Unavailable => "unavailable",
        }
    }

    fn executor_label(&self) -> String {
        format!(
            "libvirt network={} bridge={}",
            self.network_name, self.bridge_name
        )
    }

    fn preflight_context(&self) -> String {
        format!(
            "data_dir={} image_dir={} {}",
            self.data_dir.display(),
            self.image_dir.display(),
            self.executor_label()
        )
    }

    async fn check_network_config(&self) -> anyhow::Result<String> {
        network::validate_libvirt_network_config(&self.network_name, &self.bridge_name)?;
        let output = self
            .run_virsh(&[
                "--connect",
                "qemu:///system",
                "net-info",
                &self.network_name,
            ])
            .await?;
        if !libvirt_network_is_active(&output) {
            bail!("libvirt network {} is not active", self.network_name);
        }
        if !libvirt_network_uses_bridge(&output, &self.bridge_name) {
            bail!(
                "libvirt network {} is not using bridge {}",
                self.network_name,
                self.bridge_name
            );
        }
        Ok(format!(
            "libvirt network {} is active on bridge {}",
            self.network_name, self.bridge_name
        ))
    }

    fn check_bridge(&self) -> anyhow::Result<String> {
        network::validate_libvirt_identifier("bridge_name", &self.bridge_name)?;
        let bridge_path = Path::new("/sys/class/net").join(&self.bridge_name);
        if !bridge_path.exists() {
            bail!("bridge interface {} does not exist", self.bridge_name);
        }
        Ok(format!("bridge interface {} exists", self.bridge_name))
    }

    fn check_storage_layout(&self) -> anyhow::Result<String> {
        self.ensure_data_dir()?;
        self.ensure_vm_parent_if_present()?;
        self.ensure_image_dir()?;
        if !is_path_under_agent_data_dir(&self.image_dir, &self.data_dir) {
            bail!(
                "image_dir is outside agent data dir: {}",
                self.image_dir.display()
            );
        }
        Ok(format!(
            "data_dir={} image_dir={} are controlled directories",
            self.data_dir.display(),
            self.image_dir.display()
        ))
    }

    fn ensure_vm_parent_if_present(&self) -> anyhow::Result<()> {
        let vm_parent = self.data_dir.join("vms");
        let metadata = match fs::symlink_metadata(&vm_parent) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
            Err(error) => {
                return Err(error).with_context(|| {
                    format!("failed to read vm parent metadata: {}", vm_parent.display())
                });
            }
        };
        if metadata.file_type().is_symlink() {
            bail!(
                "vm parent directory must not be a symlink: {}",
                vm_parent.display()
            );
        }
        if !metadata.is_dir() {
            bail!(
                "vm parent path must be a directory: {}",
                vm_parent.display()
            );
        }
        if !is_path_under_agent_data_dir(&vm_parent, &self.data_dir) {
            bail!(
                "vm parent directory is outside agent data dir: {}",
                vm_parent.display()
            );
        }
        Ok(())
    }

    async fn create_vm(&self, request: &CreateVmRequest) -> anyhow::Result<Vec<String>> {
        request.validate_for_mvp()?;

        if !validate_safe_file_name(&request.image) {
            bail!("invalid image file name");
        }

        let vm_id = request
            .vm_id
            .ok_or_else(|| anyhow::anyhow!("create_vm task is missing vm_id"))?;
        let paths = self.paths_for_vm(vm_id)?;
        self.prepare_vm_dir_for_create(&paths.vm_dir)?;
        let user_data_path = paths.vm_dir.join("user-data");
        let meta_data_path = paths.vm_dir.join("meta-data");
        self.ensure_create_output_paths_are_absent(&[
            &paths.disk_path,
            &paths.seed_iso_path,
            &paths.network_config_path,
            &paths.domain_xml_path,
            &user_data_path,
            &meta_data_path,
        ])?;

        let base_image = self.base_image_path(&request.image)?;
        self.ensure_base_image_is_qcow2(&base_image).await?;

        if let Err(error) = self
            .create_vm_artifacts(
                request,
                vm_id,
                &paths,
                &base_image,
                &user_data_path,
                &meta_data_path,
            )
            .await
        {
            if let Err(cleanup_error) = self.remove_managed_vm_directory(&paths) {
                bail!(
                    "create_vm failed before libvirt define: {error}; cleanup failed: {cleanup_error}"
                );
            }
            return Err(error);
        }

        let domain = domain_name(vm_id);
        if let Err(error) = self
            .run_virsh(&[
                "--connect",
                "qemu:///system",
                "define",
                path_arg(&paths.domain_xml_path)?,
            ])
            .await
        {
            if let Err(cleanup_error) = self.cleanup_failed_define(&domain, &paths).await {
                bail!(
                    "create_vm failed during libvirt define: {error}; cleanup failed: {cleanup_error}"
                );
            }
            return Err(error);
        }
        if let Err(error) = self
            .run_virsh(&["--connect", "qemu:///system", "start", &domain])
            .await
        {
            if let Err(cleanup_error) = self.cleanup_defined_create_failure(&domain, &paths).await {
                bail!(
                    "create_vm failed after libvirt define: {error}; cleanup failed: {cleanup_error}"
                );
            }
            return Err(error);
        }
        self.wait_for_domain_running_after_power_command("start", &domain)
            .await?;

        Ok(vec![
            format!("created qcow2 disk at {}", paths.disk_path.display()),
            format!("defined and started domain {domain}"),
        ])
    }

    async fn cleanup_failed_define(&self, domain: &str, paths: &VmPaths) -> anyhow::Result<()> {
        match self
            .run_virsh(&["--connect", "qemu:///system", "domstate", domain])
            .await
        {
            Ok(_) => bail!("domain {domain} exists after failed define; preserving managed files"),
            Err(error) if libvirt_domain_not_found(&error.to_string()) => {
                self.remove_managed_vm_directory(paths)
            }
            Err(error) => {
                bail!("unable to confirm domain {domain} is absent after failed define: {error}")
            }
        }
    }

    async fn create_vm_artifacts(
        &self,
        request: &CreateVmRequest,
        vm_id: VmId,
        paths: &VmPaths,
        base_image: &Path,
        user_data_path: &Path,
        meta_data_path: &Path,
    ) -> anyhow::Result<()> {
        self.run_command(
            "qemu-img",
            &[
                "create",
                "-f",
                "qcow2",
                "-F",
                "qcow2",
                "-b",
                path_arg(base_image)?,
                path_arg(&paths.disk_path)?,
                &format!("{}G", request.disk_gb),
            ],
        )
        .await?;

        write_new_managed_file(
            user_data_path,
            &cloud_init_user_data(request.ssh_public_key.as_deref()),
        )
        .with_context(|| format!("failed to write {}", user_data_path.display()))?;
        let meta_data = cloud_init_meta_data(&request.name, vm_id)?;
        write_new_managed_file(meta_data_path, &meta_data)
            .with_context(|| format!("failed to write {}", meta_data_path.display()))?;

        let network_config_path = match cloud_init_network_config(request) {
            Some(network_config) => {
                write_new_managed_file(&paths.network_config_path, &network_config).with_context(
                    || format!("failed to write {}", paths.network_config_path.display()),
                )?;
                Some(paths.network_config_path.as_path())
            }
            None => None,
        };

        self.create_seed_iso(
            &paths.seed_iso_path,
            user_data_path,
            meta_data_path,
            network_config_path,
        )
        .await?;

        let domain_xml = self.domain_xml(request, vm_id, paths)?;
        write_new_managed_file(&paths.domain_xml_path, &domain_xml)
            .with_context(|| format!("failed to write {}", paths.domain_xml_path.display()))?;

        Ok(())
    }

    async fn cleanup_defined_create_failure(
        &self,
        domain: &str,
        paths: &VmPaths,
    ) -> anyhow::Result<()> {
        self.ensure_domain_stopped_before_delete_cleanup(domain)
            .await?;
        self.run_virsh(&["--connect", "qemu:///system", "undefine", domain])
            .await?;
        self.remove_managed_vm_directory(paths)
    }

    async fn virsh_vm_command(
        &self,
        command: &'static str,
        vm_id: VmId,
    ) -> anyhow::Result<Vec<String>> {
        let paths = self.paths_for_vm(vm_id)?;
        self.ensure_managed_vm_dir(&paths.vm_dir)?;
        self.ensure_vm_domain_metadata(vm_id, &paths)?;

        self.run_virsh(&["--connect", "qemu:///system", command, &domain_name(vm_id)])
            .await?;
        match command {
            "shutdown" => {
                self.wait_for_domain_shut_off_after_shutdown(&domain_name(vm_id))
                    .await?;
            }
            "start" | "reboot" => {
                self.wait_for_domain_running_after_power_command(command, &domain_name(vm_id))
                    .await?;
            }
            _ => {}
        }
        Ok(vec![format!(
            "virsh {command} completed for {}",
            domain_name(vm_id)
        )])
    }

    async fn wait_for_domain_shut_off_after_shutdown(
        &self,
        domain_name: &str,
    ) -> anyhow::Result<()> {
        let mut last_state = String::new();
        for attempt in 0..DOMAIN_STATE_POLL_ATTEMPTS {
            let state = self
                .run_virsh(&["--connect", "qemu:///system", "domstate", domain_name])
                .await
                .with_context(|| {
                    format!("failed to read libvirt domain state for {domain_name} after shutdown")
                })?;
            if domain_state_allows_delete_cleanup(&state) {
                return Ok(());
            }
            last_state = state.trim().to_owned();
            if attempt + 1 < DOMAIN_STATE_POLL_ATTEMPTS {
                tokio::time::sleep(Duration::from_secs(1)).await;
            }
        }

        bail!("libvirt domain {domain_name} did not shut off after shutdown: {last_state}");
    }

    async fn wait_for_domain_running_after_power_command(
        &self,
        command: &str,
        domain_name: &str,
    ) -> anyhow::Result<()> {
        let mut last_state = String::new();
        for attempt in 0..DOMAIN_STATE_POLL_ATTEMPTS {
            let state = self
                .run_virsh(&["--connect", "qemu:///system", "domstate", domain_name])
                .await
                .with_context(|| {
                    format!("failed to read libvirt domain state for {domain_name} after {command}")
                })?;
            if domain_state_is_running(&state) {
                return Ok(());
            }
            last_state = state.trim().to_owned();
            if attempt + 1 < DOMAIN_STATE_POLL_ATTEMPTS {
                tokio::time::sleep(Duration::from_secs(1)).await;
            }
        }

        bail!("libvirt domain {domain_name} did not reach running after {command}: {last_state}");
    }

    async fn reinstall_vm(
        &self,
        vm_id: VmId,
        name: &str,
        image: &str,
        ssh_public_key: Option<&str>,
        disk_gb: u32,
    ) -> anyhow::Result<Vec<String>> {
        validate_cloud_init_hostname(name)?;
        if !validate_safe_file_name(image) {
            bail!("invalid image file name");
        }
        if disk_gb == 0 || disk_gb > 4096 {
            bail!("disk size must be between 1 GB and 4096 GB");
        }

        let paths = self.paths_for_vm(vm_id)?;
        self.ensure_managed_vm_dir(&paths.vm_dir)?;
        self.ensure_vm_domain_metadata(vm_id, &paths)?;

        let base_image = self.base_image_path(image)?;
        self.ensure_base_image_is_qcow2(&base_image).await?;

        let domain = domain_name(vm_id);
        let user_data_path = paths.vm_dir.join("user-data");
        let meta_data_path = paths.vm_dir.join("meta-data");
        ensure_managed_file_replacement_target(&user_data_path, &self.data_dir)?;
        ensure_managed_file_replacement_target(&meta_data_path, &self.data_dir)?;
        let temp_paths = ReinstallTempPaths::for_vm(&paths);
        self.ensure_reinstall_temp_artifacts_absent(&temp_paths)?;

        let _ = self
            .run_virsh(&["--connect", "qemu:///system", "destroy", &domain])
            .await;
        self.ensure_domain_stopped_before_delete_cleanup(&domain)
            .await?;

        if let Err(error) = self
            .create_reinstall_artifacts(ReinstallArtifactRequest {
                base_image: &base_image,
                disk_gb,
                name,
                ssh_public_key,
                vm_id,
                temp_paths: &temp_paths,
                network_config_path: if self
                    .ensure_optional_managed_file(&paths.network_config_path)?
                {
                    Some(paths.network_config_path.as_path())
                } else {
                    None
                },
            })
            .await
        {
            if let Err(cleanup_error) = self.remove_reinstall_temp_artifacts(&temp_paths) {
                bail!("reinstall artifact preparation failed: {error}; cleanup failed: {cleanup_error}");
            }
            return Err(error);
        }
        self.commit_reinstall_artifacts(&paths, &temp_paths, &user_data_path, &meta_data_path)?;

        self.run_virsh(&["--connect", "qemu:///system", "start", &domain])
            .await?;
        self.wait_for_domain_running_after_power_command("start", &domain)
            .await?;

        Ok(vec![
            format!("reinstalled disk at {}", paths.disk_path.display()),
            format!("restarted domain {domain}"),
        ])
    }

    async fn create_reinstall_artifacts(
        &self,
        request: ReinstallArtifactRequest<'_>,
    ) -> anyhow::Result<()> {
        self.run_command(
            "qemu-img",
            &[
                "create",
                "-f",
                "qcow2",
                "-F",
                "qcow2",
                "-b",
                path_arg(request.base_image)?,
                path_arg(&request.temp_paths.disk_path)?,
                &format!("{}G", request.disk_gb),
            ],
        )
        .await?;

        write_new_managed_file(
            &request.temp_paths.user_data_path,
            &cloud_init_user_data(request.ssh_public_key),
        )
        .with_context(|| {
            format!(
                "failed to write {}",
                request.temp_paths.user_data_path.display()
            )
        })?;
        let meta_data = cloud_init_meta_data(request.name, request.vm_id)?;
        write_new_managed_file(&request.temp_paths.meta_data_path, &meta_data).with_context(
            || {
                format!(
                    "failed to write {}",
                    request.temp_paths.meta_data_path.display()
                )
            },
        )?;
        self.create_seed_iso(
            &request.temp_paths.seed_iso_path,
            &request.temp_paths.user_data_path,
            &request.temp_paths.meta_data_path,
            request.network_config_path,
        )
        .await
    }

    fn ensure_reinstall_temp_artifacts_absent(
        &self,
        temp_paths: &ReinstallTempPaths,
    ) -> anyhow::Result<()> {
        for path in temp_paths.paths() {
            if ensure_managed_file_replacement_target(path, &self.data_dir)? {
                bail!("stale reinstall artifact exists: {}", path.display());
            }
        }
        Ok(())
    }

    fn remove_reinstall_temp_artifacts(
        &self,
        temp_paths: &ReinstallTempPaths,
    ) -> anyhow::Result<()> {
        for path in temp_paths.paths() {
            self.remove_managed_file_if_present(path)?;
        }
        Ok(())
    }

    fn commit_reinstall_artifacts(
        &self,
        paths: &VmPaths,
        temp_paths: &ReinstallTempPaths,
        user_data_path: &Path,
        meta_data_path: &Path,
    ) -> anyhow::Result<()> {
        let artifact_pairs = [
            (temp_paths.disk_path.as_path(), paths.disk_path.as_path()),
            (
                temp_paths.seed_iso_path.as_path(),
                paths.seed_iso_path.as_path(),
            ),
            (temp_paths.user_data_path.as_path(), user_data_path),
            (temp_paths.meta_data_path.as_path(), meta_data_path),
        ];
        for (source, target) in artifact_pairs {
            self.validate_prepared_reinstall_artifact(source, target)?;
        }
        for (source, target) in artifact_pairs {
            self.replace_with_prepared_reinstall_artifact(source, target)?;
        }
        Ok(())
    }

    fn validate_prepared_reinstall_artifact(
        &self,
        source: &Path,
        target: &Path,
    ) -> anyhow::Result<()> {
        if !self.ensure_optional_managed_file(source)? {
            bail!("missing prepared reinstall artifact: {}", source.display());
        }
        ensure_managed_file_replacement_target(target, &self.data_dir)?;
        Ok(())
    }

    fn replace_with_prepared_reinstall_artifact(
        &self,
        source: &Path,
        target: &Path,
    ) -> anyhow::Result<()> {
        if !self.ensure_optional_managed_file(source)? {
            bail!("missing prepared reinstall artifact: {}", source.display());
        }
        if ensure_managed_file_replacement_target(target, &self.data_dir)? {
            fs::remove_file(target)
                .with_context(|| format!("failed to remove managed file: {}", target.display()))?;
        }
        fs::rename(source, target).with_context(|| {
            format!(
                "failed to install prepared reinstall artifact {} -> {}",
                source.display(),
                target.display()
            )
        })
    }

    async fn delete_vm(&self, vm_id: VmId) -> anyhow::Result<Vec<String>> {
        let paths = self.paths_for_vm(vm_id)?;
        self.ensure_managed_vm_dir(&paths.vm_dir)?;
        self.ensure_vm_domain_metadata(vm_id, &paths)?;
        self.ensure_only_managed_vm_artifacts(&paths)?;

        let name = domain_name(vm_id);
        let _ = self
            .run_virsh(&["--connect", "qemu:///system", "destroy", &name])
            .await;
        self.ensure_domain_stopped_before_delete_cleanup(&name)
            .await?;
        self.run_virsh(&["--connect", "qemu:///system", "undefine", &name])
            .await?;
        self.remove_managed_vm_directory(&paths)?;

        Ok(vec![format!(
            "deleted managed vm directory {}",
            paths.vm_dir.display()
        )])
    }

    async fn ensure_domain_stopped_before_delete_cleanup(
        &self,
        domain_name: &str,
    ) -> anyhow::Result<()> {
        let state = self
            .run_virsh(&["--connect", "qemu:///system", "domstate", domain_name])
            .await
            .with_context(|| format!("failed to read libvirt domain state for {domain_name}"))?;
        if !domain_state_allows_delete_cleanup(&state) {
            bail!(
                "libvirt domain {domain_name} is still running or not shut off: {}",
                state.trim()
            );
        }
        Ok(())
    }

    async fn ensure_base_image_is_qcow2(&self, base_image: &Path) -> anyhow::Result<()> {
        let info = self
            .run_command(
                "qemu-img",
                &["info", "--output=json", path_arg(base_image)?],
            )
            .await?;
        qemu_img_info_format(&info)?;
        Ok(())
    }

    async fn create_seed_iso(
        &self,
        seed_iso_path: &Path,
        user_data_path: &Path,
        meta_data_path: &Path,
        network_config_path: Option<&Path>,
    ) -> anyhow::Result<()> {
        let seed_iso = path_arg(seed_iso_path)?;
        let user_data = path_arg(user_data_path)?;
        let meta_data = path_arg(meta_data_path)?;
        let mut cloud_localds_args = vec![seed_iso, user_data, meta_data];
        if let Some(network_config_path) = network_config_path {
            cloud_localds_args.push(path_arg(network_config_path)?);
        }
        if self
            .run_command("cloud-localds", &cloud_localds_args)
            .await
            .is_ok()
        {
            return Ok(());
        }

        let mut genisoimage_args = vec![
            "-output", seed_iso, "-volid", "cidata", "-joliet", "-rock", user_data, meta_data,
        ];
        if let Some(network_config_path) = network_config_path {
            genisoimage_args.push(path_arg(network_config_path)?);
        }
        self.run_command("genisoimage", &genisoimage_args).await?;
        Ok(())
    }

    async fn detect_seed_iso_tool(&self) -> anyhow::Result<&'static str> {
        if self.run_command("cloud-localds", &["--help"]).await.is_ok() {
            return Ok("cloud-localds");
        }
        if self
            .run_command("genisoimage", &["--version"])
            .await
            .is_ok()
        {
            return Ok("genisoimage");
        }
        bail!("missing cloud-init ISO tool: install cloud-localds or genisoimage")
    }

    fn paths_for_vm(&self, vm_id: VmId) -> anyhow::Result<VmPaths> {
        self.ensure_data_dir()?;
        let vm_dir = self.data_dir.join("vms").join(vm_id.to_string());
        if !reject_path_traversal(&vm_dir) {
            bail!("vm path contains parent traversal");
        }

        let paths = VmPaths {
            disk_path: vm_dir.join("disk.qcow2"),
            seed_iso_path: vm_dir.join("seed.iso"),
            network_config_path: vm_dir.join("network-config"),
            domain_xml_path: vm_dir.join("domain.xml"),
            vm_dir,
        };

        self.ensure_managed_path_allow_missing(&paths.vm_dir)?;
        Ok(paths)
    }

    fn prepare_vm_dir_for_create(&self, vm_dir: &Path) -> anyhow::Result<()> {
        self.ensure_data_dir()?;
        if !reject_path_traversal(vm_dir) {
            bail!("vm path contains parent traversal: {}", vm_dir.display());
        }

        let vm_parent = vm_dir
            .parent()
            .ok_or_else(|| anyhow::anyhow!("vm path has no parent: {}", vm_dir.display()))?;
        if !reject_path_traversal(vm_parent) {
            bail!(
                "vm parent path contains parent traversal: {}",
                vm_parent.display()
            );
        }

        match fs::symlink_metadata(vm_parent) {
            Ok(_) => self.ensure_vm_parent_if_present()?,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                let parent = vm_parent.parent().ok_or_else(|| {
                    anyhow::anyhow!("vm parent path has no parent: {}", vm_parent.display())
                })?;
                if !is_path_under_agent_data_dir(parent, &self.data_dir) {
                    bail!(
                        "vm parent directory is outside agent data dir: {}",
                        vm_parent.display()
                    );
                }
                match fs::create_dir(vm_parent) {
                    Ok(()) => {}
                    Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
                    Err(error) => {
                        return Err(error).with_context(|| {
                            format!("failed to create vm parent {}", vm_parent.display())
                        });
                    }
                }
                self.ensure_vm_parent_if_present()?;
            }
            Err(error) => {
                return Err(error).with_context(|| {
                    format!("failed to read vm parent metadata: {}", vm_parent.display())
                });
            }
        }

        match fs::symlink_metadata(vm_dir) {
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                match fs::create_dir(vm_dir) {
                    Ok(()) => {}
                    Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
                    Err(error) => {
                        return Err(error).with_context(|| {
                            format!("failed to create vm directory {}", vm_dir.display())
                        });
                    }
                }
            }
            Err(error) => {
                return Err(error).with_context(|| {
                    format!("failed to read vm directory metadata: {}", vm_dir.display())
                });
            }
        }

        self.ensure_managed_vm_dir(vm_dir)
    }

    fn ensure_create_output_paths_are_absent(&self, paths: &[&Path]) -> anyhow::Result<()> {
        for path in paths {
            if !reject_path_traversal(path) {
                bail!(
                    "create output path contains parent traversal: {}",
                    path.display()
                );
            }
            match fs::symlink_metadata(path) {
                Ok(metadata) if metadata.file_type().is_symlink() => {
                    bail!(
                        "create output path must not be a symlink: {}",
                        path.display()
                    )
                }
                Ok(_) => bail!(
                    "create output path already exists and will not be overwritten: {}",
                    path.display()
                ),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    let parent = path.parent().unwrap_or(path);
                    if !is_path_under_agent_data_dir(parent, &self.data_dir) {
                        bail!(
                            "create output path is outside agent data dir: {}",
                            path.display()
                        );
                    }
                }
                Err(error) => {
                    return Err(error).with_context(|| {
                        format!("failed to read create output metadata: {}", path.display())
                    });
                }
            }
        }
        Ok(())
    }

    fn managed_vm_artifact_paths(&self, paths: &VmPaths) -> Vec<PathBuf> {
        vec![
            paths.disk_path.clone(),
            paths.seed_iso_path.clone(),
            paths.network_config_path.clone(),
            paths.domain_xml_path.clone(),
            paths.vm_dir.join("user-data"),
            paths.vm_dir.join("meta-data"),
        ]
    }

    fn ensure_optional_managed_file(&self, path: &Path) -> anyhow::Result<bool> {
        if !reject_path_traversal(path) {
            bail!(
                "managed file path contains parent traversal: {}",
                path.display()
            );
        }
        let metadata = match fs::symlink_metadata(path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
            Err(error) => {
                return Err(error)
                    .with_context(|| format!("failed to read managed file: {}", path.display()));
            }
        };
        if metadata.file_type().is_symlink() {
            bail!("managed file must not be a symlink: {}", path.display());
        }
        if !metadata.is_file() {
            bail!("managed file must be a regular file: {}", path.display());
        }
        if !is_path_under_agent_data_dir(path, &self.data_dir) {
            bail!("managed file is outside agent data dir: {}", path.display());
        }
        Ok(true)
    }

    fn ensure_only_managed_vm_artifacts(&self, paths: &VmPaths) -> anyhow::Result<()> {
        self.ensure_managed_vm_dir(&paths.vm_dir)?;
        for entry in fs::read_dir(&paths.vm_dir)
            .with_context(|| format!("failed to list {}", paths.vm_dir.display()))?
        {
            let entry = entry.with_context(|| {
                format!(
                    "failed to read directory entry in {}",
                    paths.vm_dir.display()
                )
            })?;
            let file_name = entry.file_name();
            let Some(file_name) = file_name.to_str() else {
                bail!(
                    "unexpected non-utf8 managed VM directory entry: {}",
                    entry.path().display()
                );
            };
            match file_name {
                "disk.qcow2" | "seed.iso" | "network-config" | "domain.xml" | "user-data"
                | "meta-data" => {
                    self.ensure_optional_managed_file(&entry.path())?;
                }
                _ => bail!(
                    "unexpected managed VM directory entry: {}",
                    entry.path().display()
                ),
            }
        }
        Ok(())
    }

    fn remove_managed_file_if_present(&self, path: &Path) -> anyhow::Result<()> {
        if self.ensure_optional_managed_file(path)? {
            fs::remove_file(path)
                .with_context(|| format!("failed to remove managed file: {}", path.display()))?;
        }
        Ok(())
    }

    #[cfg(test)]
    fn remove_required_managed_file(&self, path: &Path) -> anyhow::Result<()> {
        if !self.ensure_optional_managed_file(path)? {
            bail!("missing managed file: {}", path.display());
        }
        fs::remove_file(path)
            .with_context(|| format!("failed to remove managed file: {}", path.display()))
    }

    fn remove_managed_vm_directory(&self, paths: &VmPaths) -> anyhow::Result<()> {
        self.ensure_only_managed_vm_artifacts(paths)?;
        for artifact_path in self.managed_vm_artifact_paths(paths) {
            self.remove_managed_file_if_present(&artifact_path)?;
        }
        self.ensure_only_managed_vm_artifacts(paths)?;
        fs::remove_dir(&paths.vm_dir)
            .with_context(|| format!("failed to remove {}", paths.vm_dir.display()))
    }

    fn domain_xml(
        &self,
        request: &CreateVmRequest,
        vm_id: VmId,
        paths: &VmPaths,
    ) -> anyhow::Result<String> {
        let memory_kib = u64::from(request.memory_mb) * 1024;
        Ok(format!(
            r#"<domain type="kvm">
  <name>{name}</name>
  <uuid>{uuid}</uuid>
  <memory unit="KiB">{memory_kib}</memory>
  <currentMemory unit="KiB">{memory_kib}</currentMemory>
  <vcpu placement="static">{vcpu}</vcpu>
  <os>
    <type arch="x86_64" machine="pc">hvm</type>
    <boot dev="hd"/>
  </os>
  <features>
    <acpi/>
    <apic/>
  </features>
  <cpu mode="host-passthrough" check="none"/>
  <clock offset="utc"/>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type="file" device="disk">
      <driver name="qemu" type="qcow2"/>
      <source file="{disk}"/>
      <target dev="vda" bus="virtio"/>
    </disk>
    <disk type="file" device="cdrom">
      <driver name="qemu" type="raw"/>
      <source file="{seed}"/>
      <target dev="sda" bus="sata"/>
      <readonly/>
    </disk>
    <interface type="network">
      <source network="{network}"/>
      <model type="virtio"/>
    </interface>
    <console type="pty"/>
    <graphics type="vnc" port="-1" autoport="yes" listen="127.0.0.1"/>
  </devices>
</domain>
"#,
            name = domain_name(vm_id),
            uuid = vm_id,
            memory_kib = memory_kib,
            vcpu = request.cpu_cores,
            disk = xml_escape(path_str(&paths.disk_path)?),
            seed = xml_escape(path_str(&paths.seed_iso_path)?),
            network = xml_escape(&self.network_name),
        ))
    }

    fn ensure_data_dir(&self) -> anyhow::Result<()> {
        let metadata = fs::symlink_metadata(&self.data_dir).with_context(|| {
            format!(
                "failed to read data_dir metadata: {}",
                self.data_dir.display()
            )
        })?;
        if metadata.file_type().is_symlink() {
            bail!(
                "data_dir must not be a symlink: {}",
                self.data_dir.display()
            );
        }
        if !metadata.is_dir() {
            bail!("data_dir must be a directory: {}", self.data_dir.display());
        }
        Ok(())
    }

    fn ensure_image_dir(&self) -> anyhow::Result<()> {
        let metadata = fs::symlink_metadata(&self.image_dir).with_context(|| {
            format!(
                "failed to read image_dir metadata: {}",
                self.image_dir.display()
            )
        })?;
        if metadata.file_type().is_symlink() {
            bail!(
                "image_dir must not be a symlink: {}",
                self.image_dir.display()
            );
        }
        if !metadata.is_dir() {
            bail!(
                "image_dir must be a directory: {}",
                self.image_dir.display()
            );
        }
        Ok(())
    }

    fn ensure_managed_path(&self, path: &Path) -> anyhow::Result<()> {
        if !path.exists() {
            bail!("managed path does not exist: {}", path.display());
        }
        if !is_path_under_agent_data_dir(path, &self.data_dir) {
            bail!("path is outside agent data dir: {}", path.display());
        }
        let metadata = fs::symlink_metadata(path)
            .with_context(|| format!("failed to read managed path metadata: {}", path.display()))?;
        if metadata.file_type().is_symlink() {
            bail!("managed path must not be a symlink: {}", path.display());
        }
        if !metadata.is_file() {
            bail!("managed path must be a regular file: {}", path.display());
        }
        Ok(())
    }

    fn ensure_managed_path_allow_missing(&self, path: &Path) -> anyhow::Result<()> {
        let parent = path.parent().unwrap_or(path);
        if parent.exists() {
            let parent_metadata = fs::symlink_metadata(parent).with_context(|| {
                format!("failed to read vm parent metadata: {}", parent.display())
            })?;
            if parent_metadata.file_type().is_symlink() {
                bail!(
                    "vm parent directory must not be a symlink: {}",
                    parent.display()
                );
            }
            if !parent_metadata.is_dir() {
                bail!("vm parent path must be a directory: {}", parent.display());
            }
            if !is_path_under_agent_data_dir(parent, &self.data_dir) {
                bail!("path is outside agent data dir: {}", path.display());
            }
        }
        let metadata = match fs::symlink_metadata(path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
            Err(error) => {
                return Err(error).with_context(|| {
                    format!("failed to read vm directory metadata: {}", path.display())
                })
            }
        };
        if metadata.file_type().is_symlink() {
            bail!("vm directory must not be a symlink: {}", path.display());
        }
        if !metadata.is_dir() {
            bail!("vm directory must be a directory: {}", path.display());
        }
        if !is_path_under_agent_data_dir(path, &self.data_dir) {
            bail!("path is outside agent data dir: {}", path.display());
        }
        Ok(())
    }

    fn ensure_managed_vm_dir(&self, path: &Path) -> anyhow::Result<()> {
        if !path.exists() {
            bail!("vm is not managed by this agent");
        }
        if !is_path_under_agent_data_dir(path, &self.data_dir) {
            bail!("vm directory is outside agent data dir: {}", path.display());
        }
        let metadata = fs::symlink_metadata(path)
            .with_context(|| format!("failed to read vm directory metadata: {}", path.display()))?;
        if metadata.file_type().is_symlink() {
            bail!("vm directory must not be a symlink: {}", path.display());
        }
        if !metadata.is_dir() {
            bail!("vm directory must be a directory: {}", path.display());
        }
        Ok(())
    }

    fn ensure_vm_domain_metadata(&self, vm_id: VmId, paths: &VmPaths) -> anyhow::Result<()> {
        self.ensure_managed_path(&paths.disk_path)?;
        self.ensure_managed_path(&paths.seed_iso_path)?;
        self.ensure_managed_path(&paths.domain_xml_path)?;

        let metadata = fs::metadata(&paths.domain_xml_path).with_context(|| {
            format!(
                "failed to read domain metadata: {}",
                paths.domain_xml_path.display()
            )
        })?;
        if metadata.len() > MAX_DOMAIN_XML_BYTES {
            bail!(
                "domain metadata is too large: {}",
                paths.domain_xml_path.display()
            );
        }

        let domain_xml = fs::read_to_string(&paths.domain_xml_path).with_context(|| {
            format!(
                "failed to read domain metadata: {}",
                paths.domain_xml_path.display()
            )
        })?;
        validate_domain_metadata_xml(&domain_xml, vm_id, paths)?;

        Ok(())
    }

    fn base_image_path(&self, image: &str) -> anyhow::Result<PathBuf> {
        if !validate_safe_file_name(image) {
            bail!("invalid image file name");
        }
        self.ensure_data_dir()?;
        self.ensure_image_dir()?;

        let base_image = self.image_dir.join(image);
        if !base_image.exists() {
            bail!("base image does not exist: {}", base_image.display());
        }
        let metadata = fs::symlink_metadata(&base_image).with_context(|| {
            format!(
                "failed to read base image metadata: {}",
                base_image.display()
            )
        })?;
        if metadata.file_type().is_symlink() {
            bail!("base image must not be a symlink: {}", base_image.display());
        }
        if !metadata.is_file() {
            bail!(
                "base image must be a regular file: {}",
                base_image.display()
            );
        }
        if !is_path_under_agent_data_dir(&self.image_dir, &self.data_dir) {
            bail!(
                "image_dir is outside agent data dir: {}",
                self.image_dir.display()
            );
        }
        if !is_path_under_agent_data_dir(&base_image, &self.image_dir) {
            bail!("base image is outside image_dir: {}", base_image.display());
        }
        if !is_path_under_agent_data_dir(&base_image, &self.data_dir) {
            bail!(
                "base image is outside agent data dir: {}",
                base_image.display()
            );
        }

        Ok(base_image)
    }
}

fn validate_domain_metadata_xml(
    domain_xml: &str,
    vm_id: VmId,
    paths: &VmPaths,
) -> anyhow::Result<()> {
    let document =
        roxmltree::Document::parse(domain_xml).context("failed to parse domain metadata XML")?;
    let domain = document.root_element();
    if !domain.has_tag_name("domain") {
        bail!("domain metadata root is not a libvirt domain");
    }

    let actual_name = direct_child_text(domain, "name");
    let expected_domain_name = domain_name(vm_id);
    if actual_name != Some(expected_domain_name.as_str()) {
        bail!("domain metadata does not match managed VM {vm_id}");
    }

    let actual_uuid = direct_child_text(domain, "uuid");
    let expected_uuid = vm_id.to_string();
    if actual_uuid != Some(expected_uuid.as_str()) {
        bail!("domain metadata does not match managed VM {vm_id}");
    }

    let disk_sources = disk_source_files(domain, "disk");
    let seed_sources = disk_source_files(domain, "cdrom");
    if disk_sources.as_slice() != [path_str(&paths.disk_path)?]
        || seed_sources.as_slice() != [path_str(&paths.seed_iso_path)?]
    {
        bail!("domain metadata does not match managed VM {vm_id}");
    }

    Ok(())
}

fn direct_child_text<'a>(node: roxmltree::Node<'a, 'a>, tag_name: &str) -> Option<&'a str> {
    node.children()
        .find(|child| child.is_element() && child.has_tag_name(tag_name))
        .and_then(|child| child.text())
        .map(str::trim)
}

fn disk_source_files<'a>(domain: roxmltree::Node<'a, 'a>, device: &str) -> Vec<&'a str> {
    let Some(devices) = domain
        .children()
        .find(|child| child.is_element() && child.has_tag_name("devices"))
    else {
        return Vec::new();
    };

    devices
        .children()
        .filter(|child| {
            child.is_element()
                && child.has_tag_name("disk")
                && child.attribute("device") == Some(device)
        })
        .filter_map(|disk| {
            disk.children()
                .find(|child| child.is_element() && child.has_tag_name("source"))
                .and_then(|source| source.attribute("file"))
        })
        .collect()
}

async fn run_command(program: &str, args: &[&str]) -> anyhow::Result<String> {
    run_command_with_timeout(program, args, HOST_COMMAND_TIMEOUT).await
}

async fn run_command_with_timeout(
    program: &str,
    args: &[&str],
    timeout: Duration,
) -> anyhow::Result<String> {
    let child = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .with_context(|| format!("failed to start {program}"))?;

    let output = match tokio::time::timeout(timeout, child.wait_with_output()).await {
        Ok(output) => output,
        Err(_) => bail!("{program} timed out after {timeout:?}"),
    }
    .with_context(|| format!("failed to run {program}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let stderr = redaction::redact_text(stderr.trim());
        bail!("{program} failed: {stderr}");
    }

    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

fn qemu_img_info_format(info_json: &str) -> anyhow::Result<String> {
    let value: serde_json::Value =
        serde_json::from_str(info_json).context("qemu-img returned invalid JSON")?;
    let format = value
        .get("format")
        .and_then(serde_json::Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| anyhow::anyhow!("qemu-img output did not include image format"))?;
    if format != "qcow2" {
        bail!("base image must be qcow2, got {format}");
    }

    Ok(format.to_owned())
}

fn libvirt_domain_not_found(message: &str) -> bool {
    let normalized = message.to_ascii_lowercase();
    normalized.contains("domain not found")
        || normalized.contains("failed to get domain")
        || normalized.contains("no domain with matching")
}

fn require_kvm_character_device(path: impl AsRef<Path>) -> anyhow::Result<()> {
    let path = path.as_ref();
    if !path.exists() {
        bail!("missing KVM character device: {}", path.display())
    }
    let metadata = fs::metadata(path)
        .with_context(|| format!("failed to read host path metadata: {}", path.display()))?;
    if !is_character_device(&metadata) {
        bail!("{} must be a KVM character device", path.display());
    }
    Ok(())
}

#[cfg(unix)]
fn is_character_device(metadata: &fs::Metadata) -> bool {
    use std::os::unix::fs::FileTypeExt;

    metadata.file_type().is_char_device()
}

#[cfg(not(unix))]
fn is_character_device(_metadata: &fs::Metadata) -> bool {
    false
}

fn passed_check(name: &str, message: &str) -> HostPreflightCheck {
    HostPreflightCheck {
        name: name.into(),
        status: "passed".into(),
        message: truncate_check_message(message),
    }
}

fn failed_check(name: &str, message: &str) -> HostPreflightCheck {
    HostPreflightCheck {
        name: name.into(),
        status: "failed".into(),
        message: truncate_check_message(&redaction::redact_text(message)),
    }
}

fn truncate_check_message(message: &str) -> String {
    let single_line = message.replace(['\r', '\n'], " ");
    let escaped = escape_ascii_controls(&single_line);
    escaped.chars().take(240).collect()
}

fn escape_ascii_controls(input: &str) -> String {
    let mut output = String::with_capacity(input.len());
    for character in input.chars() {
        if character.is_ascii_control() {
            output.push_str(&format!("\\x{:02X}", character as u32));
        } else {
            output.push(character);
        }
    }
    output
}

fn libvirt_network_is_active(output: &str) -> bool {
    output.lines().any(|line| {
        let Some((key, value)) = line.split_once(':') else {
            return false;
        };
        key.trim().eq_ignore_ascii_case("Active") && value.trim().eq_ignore_ascii_case("yes")
    })
}

fn libvirt_network_uses_bridge(output: &str, expected_bridge: &str) -> bool {
    output.lines().any(|line| {
        let Some((key, value)) = line.split_once(':') else {
            return false;
        };
        key.trim().eq_ignore_ascii_case("Bridge") && value.trim() == expected_bridge
    })
}

fn domain_state_allows_delete_cleanup(output: &str) -> bool {
    output.trim().eq_ignore_ascii_case("shut off")
}

fn domain_state_is_running(output: &str) -> bool {
    output.trim().eq_ignore_ascii_case("running")
}

fn path_arg(path: &Path) -> anyhow::Result<&str> {
    path.to_str()
        .ok_or_else(|| anyhow::anyhow!("path is not valid UTF-8: {}", path.display()))
}

fn path_str(path: &Path) -> anyhow::Result<&str> {
    path_arg(path)
}

fn write_new_managed_file(path: &Path, contents: &str) -> anyhow::Result<()> {
    let mut file = OpenOptions::new().write(true).create_new(true).open(path)?;
    file.write_all(contents.as_bytes())?;
    Ok(())
}

fn ensure_managed_file_replacement_target(path: &Path, data_dir: &Path) -> anyhow::Result<bool> {
    if !reject_path_traversal(path) {
        bail!(
            "managed replacement path contains parent traversal: {}",
            path.display()
        );
    }

    let parent = path
        .parent()
        .ok_or_else(|| anyhow::anyhow!("managed replacement path has no parent"))?;
    let parent_metadata = fs::symlink_metadata(parent).with_context(|| {
        format!(
            "failed to read managed replacement parent metadata: {}",
            parent.display()
        )
    })?;
    if parent_metadata.file_type().is_symlink() {
        bail!(
            "managed replacement parent must not be a symlink: {}",
            parent.display()
        );
    }
    if !parent_metadata.is_dir() {
        bail!(
            "managed replacement parent must be a directory: {}",
            parent.display()
        );
    }
    if !is_path_under_agent_data_dir(parent, data_dir) {
        bail!(
            "managed replacement path is outside agent data dir: {}",
            path.display()
        );
    }

    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => {
            bail!(
                "managed replacement file must not be a symlink: {}",
                path.display()
            )
        }
        Ok(metadata) if !metadata.is_file() => {
            bail!(
                "managed replacement file must be a regular file: {}",
                path.display()
            )
        }
        Ok(_) => Ok(true),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error).with_context(|| {
            format!(
                "failed to read managed replacement metadata: {}",
                path.display()
            )
        }),
    }
}

#[cfg(test)]
fn replace_managed_file(path: &Path, data_dir: &Path, contents: &str) -> anyhow::Result<()> {
    if ensure_managed_file_replacement_target(path, data_dir)? {
        fs::remove_file(path)
            .with_context(|| format!("failed to remove managed file: {}", path.display()))?;
    }
    write_new_managed_file(path, contents)
}

fn domain_name(vm_id: VmId) -> String {
    format!("vps-{vm_id}")
}

fn cloud_init_user_data(ssh_public_key: Option<&str>) -> String {
    let Some(key) = ssh_public_key else {
        return "#cloud-config\nssh_pwauth: false\ndisable_root: true\n".into();
    };

    format!(
        "#cloud-config\nssh_pwauth: false\ndisable_root: true\nusers:\n  - default\n  - name: vps\n    groups: sudo\n    shell: /bin/bash\n    sudo: ALL=(ALL) NOPASSWD:ALL\n    ssh_authorized_keys:\n      - {}\n",
        yaml_single_quote(key)
    )
}

fn cloud_init_meta_data(name: &str, vm_id: VmId) -> anyhow::Result<String> {
    validate_cloud_init_hostname(name)?;
    Ok(format!("instance-id: {vm_id}\nlocal-hostname: {name}\n"))
}

fn validate_cloud_init_hostname(name: &str) -> anyhow::Result<()> {
    if name.is_empty()
        || name.len() > 64
        || !name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        bail!("invalid cloud-init metadata hostname");
    }
    Ok(())
}

fn cloud_init_network_config(request: &CreateVmRequest) -> Option<String> {
    Some(format!(
        "version: 2\nethernets:\n  all:\n    match:\n      name: 'e*'\n    dhcp4: false\n    addresses:\n      - {}/{}\n    routes:\n      - to: default\n        via: {}\n",
        request.assigned_ip.as_deref()?,
        request.assigned_ip_prefix?,
        request.assigned_gateway_ip.as_deref()?
    ))
}

fn xml_escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

fn yaml_single_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

#[cfg(test)]
mod tests {
    use std::{
        collections::VecDeque,
        fs,
        path::PathBuf,
        sync::{Arc, Mutex},
        time::{Duration, Instant},
    };

    use uuid::Uuid;
    use vps_shared::{CreateVmRequest, NodeId, VmId};

    use super::LibvirtExecutor;

    #[tokio::test]
    async fn host_command_timeout_fails_quickly() {
        let started = Instant::now();

        #[cfg(windows)]
        let result = super::run_command_with_timeout(
            "powershell",
            &[
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                "Start-Sleep -Seconds 5",
            ],
            Duration::from_millis(50),
        )
        .await;

        #[cfg(unix)]
        let result =
            super::run_command_with_timeout("sleep", &["5"], Duration::from_millis(50)).await;

        let error = result.expect_err("slow host command should time out");

        assert!(
            error.to_string().contains("timed out"),
            "unexpected error: {error:#}"
        );
        assert!(
            started.elapsed() < Duration::from_secs(2),
            "timeout should not wait for the slow child process"
        );
    }

    #[tokio::test]
    async fn host_command_failure_redacts_stderr_before_returning_error() {
        #[cfg(windows)]
        let result = super::run_command_with_timeout(
            "powershell",
            &[
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                "[Console]::Error.Write('password=hunter2 credential=ag_plaintext'); exit 7",
            ],
            Duration::from_secs(5),
        )
        .await;

        #[cfg(unix)]
        let result = super::run_command_with_timeout(
            "sh",
            &[
                "-c",
                "printf 'password=hunter2 credential=ag_plaintext' >&2; exit 7",
            ],
            Duration::from_secs(5),
        )
        .await;

        let error = result.expect_err("failing host command should return stderr context");
        let message = error.to_string();

        assert!(!message.contains("hunter2"));
        assert!(!message.contains("ag_plaintext"));
        assert!(message.contains("password=[REDACTED]"));
        assert!(message.contains("credential=[REDACTED]"));
    }

    #[derive(Clone, Debug)]
    struct FakeCommandRunner {
        calls: Arc<Mutex<Vec<Vec<String>>>>,
        domstate: String,
        domstate_sequence: Option<Arc<Mutex<VecDeque<String>>>>,
        domstate_error: Option<String>,
        virsh_version_error: Option<String>,
        seed_iso_error: Option<String>,
        define_error: Option<String>,
        undefine_error: Option<String>,
        start_error: Option<String>,
        qemu_img_info: String,
    }

    impl FakeCommandRunner {
        fn running_after_destroy() -> Self {
            Self {
                calls: Arc::new(Mutex::new(Vec::new())),
                domstate: "running\n".to_owned(),
                domstate_sequence: None,
                domstate_error: None,
                virsh_version_error: None,
                seed_iso_error: None,
                define_error: None,
                undefine_error: None,
                start_error: None,
                qemu_img_info: r#"{"format":"qcow2"}"#.to_owned(),
            }
        }

        fn stopped_with_undefine_failure() -> Self {
            Self {
                calls: Arc::new(Mutex::new(Vec::new())),
                domstate: "shut off\n".to_owned(),
                domstate_sequence: None,
                domstate_error: None,
                virsh_version_error: None,
                seed_iso_error: None,
                define_error: None,
                undefine_error: Some("simulated undefine failure".to_owned()),
                start_error: None,
                qemu_img_info: r#"{"format":"qcow2"}"#.to_owned(),
            }
        }

        fn stopped_after_shutdown() -> Self {
            Self {
                calls: Arc::new(Mutex::new(Vec::new())),
                domstate: "shut off\n".to_owned(),
                domstate_sequence: None,
                domstate_error: None,
                virsh_version_error: None,
                seed_iso_error: None,
                define_error: None,
                undefine_error: None,
                start_error: None,
                qemu_img_info: r#"{"format":"qcow2"}"#.to_owned(),
            }
        }

        fn running_after_power_action() -> Self {
            Self {
                calls: Arc::new(Mutex::new(Vec::new())),
                domstate: "running\n".to_owned(),
                domstate_sequence: None,
                domstate_error: None,
                virsh_version_error: None,
                seed_iso_error: None,
                define_error: None,
                undefine_error: None,
                start_error: None,
                qemu_img_info: r#"{"format":"qcow2"}"#.to_owned(),
            }
        }

        fn stopped_then_running_after_start() -> Self {
            Self {
                calls: Arc::new(Mutex::new(Vec::new())),
                domstate: "running\n".to_owned(),
                domstate_sequence: Some(Self::domstate_sequence(&["shut off\n", "running\n"])),
                domstate_error: None,
                virsh_version_error: None,
                seed_iso_error: None,
                define_error: None,
                undefine_error: None,
                start_error: None,
                qemu_img_info: r#"{"format":"qcow2"}"#.to_owned(),
            }
        }

        fn virsh_version_failure(error: &str) -> Self {
            Self {
                calls: Arc::new(Mutex::new(Vec::new())),
                domstate: "shut off\n".to_owned(),
                domstate_sequence: None,
                domstate_error: None,
                virsh_version_error: Some(error.to_owned()),
                seed_iso_error: None,
                define_error: None,
                undefine_error: None,
                start_error: None,
                qemu_img_info: r#"{"format":"qcow2"}"#.to_owned(),
            }
        }

        fn seed_iso_failure(error: &str) -> Self {
            Self {
                calls: Arc::new(Mutex::new(Vec::new())),
                domstate: "shut off\n".to_owned(),
                domstate_sequence: None,
                domstate_error: None,
                virsh_version_error: None,
                seed_iso_error: Some(error.to_owned()),
                define_error: None,
                undefine_error: None,
                start_error: None,
                qemu_img_info: r#"{"format":"qcow2"}"#.to_owned(),
            }
        }

        fn define_failure_without_domain(error: &str) -> Self {
            Self {
                calls: Arc::new(Mutex::new(Vec::new())),
                domstate: String::new(),
                domstate_sequence: None,
                domstate_error: Some("domain not found".to_owned()),
                virsh_version_error: None,
                seed_iso_error: None,
                define_error: Some(error.to_owned()),
                undefine_error: None,
                start_error: None,
                qemu_img_info: r#"{"format":"qcow2"}"#.to_owned(),
            }
        }

        fn define_failure_with_ambiguous_domstate(error: &str) -> Self {
            Self {
                calls: Arc::new(Mutex::new(Vec::new())),
                domstate: String::new(),
                domstate_sequence: None,
                domstate_error: Some("failed to connect to libvirt".to_owned()),
                virsh_version_error: None,
                seed_iso_error: None,
                define_error: Some(error.to_owned()),
                undefine_error: None,
                start_error: None,
                qemu_img_info: r#"{"format":"qcow2"}"#.to_owned(),
            }
        }

        fn stopped_after_start_failure(error: &str) -> Self {
            Self {
                calls: Arc::new(Mutex::new(Vec::new())),
                domstate: "shut off\n".to_owned(),
                domstate_sequence: None,
                domstate_error: None,
                virsh_version_error: None,
                seed_iso_error: None,
                define_error: None,
                undefine_error: None,
                start_error: Some(error.to_owned()),
                qemu_img_info: r#"{"format":"qcow2"}"#.to_owned(),
            }
        }

        fn calls(&self) -> Vec<Vec<String>> {
            self.calls.lock().unwrap().clone()
        }

        fn domstate_sequence(states: &[&str]) -> Arc<Mutex<VecDeque<String>>> {
            Arc::new(Mutex::new(
                states.iter().map(|state| (*state).to_owned()).collect(),
            ))
        }
    }

    impl super::CommandRunner for FakeCommandRunner {
        fn run<'a>(&'a self, program: &'a str, args: &'a [&'a str]) -> super::CommandFuture<'a> {
            let call = std::iter::once(program.to_owned())
                .chain(args.iter().map(|arg| (*arg).to_owned()))
                .collect::<Vec<_>>();
            self.calls.lock().unwrap().push(call);

            let domstate = self.domstate.clone();
            let domstate_sequence = self.domstate_sequence.clone();
            let domstate_error = self.domstate_error.clone();
            let virsh_version_error = self.virsh_version_error.clone();
            let seed_iso_error = self.seed_iso_error.clone();
            let define_error = self.define_error.clone();
            let undefine_error = self.undefine_error.clone();
            let start_error = self.start_error.clone();
            let qemu_img_info = self.qemu_img_info.clone();
            Box::pin(async move {
                match (program, args) {
                    ("qemu-img", ["info", "--output=json", _]) => Ok(qemu_img_info),
                    ("qemu-img", ["create", ..]) => {
                        fs::write(args[7], "disk").map_err(anyhow::Error::from)?;
                        Ok(String::new())
                    }
                    ("cloud-localds", ["--help"]) => Ok(String::new()),
                    ("genisoimage", ["--version"]) => Ok(String::new()),
                    ("cloud-localds", [seed_iso_path, ..]) => match seed_iso_error.clone() {
                        Some(error) => Err(anyhow::anyhow!(error)),
                        None => {
                            fs::write(seed_iso_path, "seed").map_err(anyhow::Error::from)?;
                            Ok(String::new())
                        }
                    },
                    ("genisoimage", ["-output", seed_iso_path, ..]) => match seed_iso_error.clone()
                    {
                        Some(error) => Err(anyhow::anyhow!(error)),
                        None => {
                            fs::write(seed_iso_path, "seed").map_err(anyhow::Error::from)?;
                            Ok(String::new())
                        }
                    },
                    ("virsh", ["--connect", "qemu:///system", "version"]) => {
                        match virsh_version_error {
                            Some(error) => Err(anyhow::anyhow!(error)),
                            None => Ok(String::new()),
                        }
                    }
                    ("virsh", ["--connect", "qemu:///system", "destroy", _]) => {
                        Err(anyhow::anyhow!("simulated destroy failure"))
                    }
                    ("virsh", ["--connect", "qemu:///system", "domstate", _]) => {
                        match domstate_error {
                            Some(error) => Err(anyhow::anyhow!(error)),
                            None => {
                                if let Some(sequence) = domstate_sequence {
                                    if let Some(state) = sequence.lock().unwrap().pop_front() {
                                        return Ok(state);
                                    }
                                }
                                Ok(domstate)
                            }
                        }
                    }
                    ("virsh", ["--connect", "qemu:///system", "define", _]) => match define_error {
                        Some(error) => Err(anyhow::anyhow!(error)),
                        None => Ok(String::new()),
                    },
                    ("virsh", ["--connect", "qemu:///system", "undefine", _]) => {
                        match undefine_error {
                            Some(error) => Err(anyhow::anyhow!(error)),
                            None => Ok(String::new()),
                        }
                    }
                    ("virsh", ["--connect", "qemu:///system", "start", _]) => match start_error {
                        Some(error) => Err(anyhow::anyhow!(error)),
                        None => Ok(String::new()),
                    },
                    ("virsh", ["--connect", "qemu:///system", "shutdown", _])
                    | ("virsh", ["--connect", "qemu:///system", "reboot", _]) => Ok(String::new()),
                    _ => Err(anyhow::anyhow!("unexpected command: {program} {args:?}")),
                }
            })
        }
    }

    #[test]
    fn paths_are_inside_data_dir() {
        let data_dir = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        fs::create_dir_all(data_dir.join("vms")).unwrap();
        let executor = LibvirtExecutor::new(
            data_dir.clone(),
            PathBuf::from("/images"),
            "default".into(),
            "virbr0".into(),
        );

        let paths = executor.paths_for_vm(VmId::new()).unwrap();
        assert!(paths.vm_dir.starts_with(data_dir));
    }

    #[test]
    fn domain_xml_escapes_untrusted_fields() {
        let data_dir = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        fs::create_dir_all(data_dir.join("vms")).unwrap();
        let executor = LibvirtExecutor::new(
            data_dir,
            PathBuf::from("/images"),
            "default\"bad".into(),
            "virbr0".into(),
        );
        let vm_id = VmId::new();
        let paths = executor.paths_for_vm(vm_id).unwrap();
        let xml = executor
            .domain_xml(
                &CreateVmRequest {
                    node_id: NodeId::new(),
                    vm_id: Some(vm_id),
                    ip_pool_id: None,
                    plan_id: None,
                    assigned_ip: None,
                    assigned_ip_prefix: None,
                    assigned_gateway_ip: None,
                    name: "demo".into(),
                    image: "debian.qcow2".into(),
                    ssh_public_key: None,
                    cpu_cores: 1,
                    memory_mb: 512,
                    disk_gb: 10,
                },
                vm_id,
                &paths,
            )
            .unwrap();

        assert!(xml.contains("default&quot;bad"));
    }

    #[test]
    fn generated_domain_xml_passes_metadata_validation() {
        let data_dir = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        fs::create_dir_all(data_dir.join("vms")).unwrap();
        let executor = LibvirtExecutor::new(
            data_dir,
            PathBuf::from("/images"),
            "default".into(),
            "virbr0".into(),
        );
        let vm_id = VmId::new();
        let paths = executor.paths_for_vm(vm_id).unwrap();
        let xml = executor
            .domain_xml(
                &CreateVmRequest {
                    node_id: NodeId::new(),
                    vm_id: Some(vm_id),
                    ip_pool_id: None,
                    plan_id: None,
                    assigned_ip: None,
                    assigned_ip_prefix: None,
                    assigned_gateway_ip: None,
                    name: "demo".into(),
                    image: "debian.qcow2".into(),
                    ssh_public_key: None,
                    cpu_cores: 1,
                    memory_mb: 512,
                    disk_gb: 10,
                },
                vm_id,
                &paths,
            )
            .unwrap();

        super::validate_domain_metadata_xml(&xml, vm_id, &paths)
            .expect("agent-generated domain XML should match metadata guard");
    }

    #[test]
    fn cloud_init_injects_ssh_public_key_for_vps_user() {
        let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb user@example";
        let user_data = super::cloud_init_user_data(Some(key));

        assert!(user_data.contains("name: vps"));
        assert!(user_data.contains("ssh_authorized_keys"));
        assert!(user_data.contains(key));
    }

    #[tokio::test]
    async fn create_vm_writes_cloud_init_network_config_when_ipam_metadata_is_present() {
        let data_dir =
            std::env::temp_dir().join(format!("vps-agent-network-config-{}", Uuid::new_v4()));
        let image_dir = data_dir.join("images");
        fs::create_dir_all(&image_dir).unwrap();
        fs::write(image_dir.join("debian.qcow2"), "base image").unwrap();
        let runner = Arc::new(FakeCommandRunner::running_after_power_action());
        let executor = LibvirtExecutor::new(
            data_dir.clone(),
            image_dir,
            "default".into(),
            "virbr0".into(),
        )
        .with_command_runner(runner.clone());
        let vm_id = VmId::new();
        let request: CreateVmRequest = serde_json::from_value(serde_json::json!({
            "node_id": NodeId::new(),
            "vm_id": vm_id,
            "ip_pool_id": null,
            "plan_id": null,
            "assigned_ip": "192.0.2.2",
            "assigned_ip_prefix": 29,
            "assigned_gateway_ip": "192.0.2.1",
            "name": "demo",
            "image": "debian.qcow2",
            "ssh_public_key": null,
            "cpu_cores": 1,
            "memory_mb": 512,
            "disk_gb": 10
        }))
        .expect("request should deserialize");

        executor
            .create_vm(&request)
            .await
            .expect("create_vm should succeed");

        let paths = executor.paths_for_vm(vm_id).unwrap();
        let network_config = fs::read_to_string(paths.vm_dir.join("network-config"))
            .expect("network-config should be written");
        assert!(network_config.contains("192.0.2.2/29"));
        assert!(network_config.contains("via: 192.0.2.1"));
        assert!(
            runner
                .calls()
                .iter()
                .any(|call| call.iter().any(|arg| arg.ends_with("network-config"))),
            "seed ISO command should include network-config"
        );

        fs::remove_dir_all(data_dir).unwrap();
    }

    #[tokio::test]
    async fn create_vm_waits_for_domain_running_after_start() {
        let data_dir = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        let image_dir = data_dir.join("images");
        fs::create_dir_all(&image_dir).unwrap();
        fs::write(image_dir.join("debian.qcow2"), "base image").unwrap();
        let runner = Arc::new(FakeCommandRunner::running_after_power_action());
        let executor = LibvirtExecutor::new(data_dir, image_dir, "default".into(), "virbr0".into())
            .with_command_runner(runner.clone());
        let request = CreateVmRequest {
            node_id: NodeId::new(),
            vm_id: Some(VmId::new()),
            ip_pool_id: None,
            plan_id: None,
            assigned_ip: None,
            assigned_ip_prefix: None,
            assigned_gateway_ip: None,
            name: "demo".into(),
            image: "debian.qcow2".into(),
            ssh_public_key: None,
            cpu_cores: 1,
            memory_mb: 512,
            disk_gb: 10,
        };

        executor
            .create_vm(&request)
            .await
            .expect("create should succeed when the started domain reaches running");

        let calls = runner.calls();
        let start_index = calls
            .iter()
            .position(|call| call.iter().any(|arg| arg == "start"))
            .expect("create must start the domain");
        assert!(
            calls
                .iter()
                .skip(start_index + 1)
                .any(|call| call.iter().any(|arg| arg == "domstate")),
            "create must verify the domain state after virsh start"
        );
    }

    #[test]
    fn libvirt_network_active_parser_requires_active_yes() {
        assert!(super::libvirt_network_is_active(
            "Name: default\nUUID: 0000\nActive: yes\nPersistent: yes\n"
        ));
        assert!(!super::libvirt_network_is_active(
            "Name: default\nActive: no\nPersistent: yes\n"
        ));
    }

    #[test]
    fn libvirt_network_bridge_parser_requires_expected_bridge() {
        let output = "Name: default\nActive: yes\nBridge: virbr0\n";

        assert!(super::libvirt_network_uses_bridge(output, "virbr0"));
        assert!(!super::libvirt_network_uses_bridge(output, "virbr1"));
        assert!(!super::libvirt_network_uses_bridge(
            "Name: default\nActive: yes\n",
            "virbr0"
        ));
    }

    #[test]
    fn kvm_preflight_rejects_regular_files() {
        let path = std::env::temp_dir().join(format!("vps-agent-kvm-test-{}", Uuid::new_v4()));
        fs::write(&path, "not a device").unwrap();

        let error = super::require_kvm_character_device(&path)
            .expect_err("regular file should not pass KVM device preflight");

        assert!(
            error.to_string().contains("character device"),
            "unexpected error: {error}"
        );

        let _ = fs::remove_file(path);
    }

    #[test]
    fn kvm_preflight_reports_missing_device_path() {
        let path = std::env::temp_dir().join(format!("vps-agent-kvm-missing-{}", Uuid::new_v4()));

        let error = super::require_kvm_character_device(&path)
            .expect_err("missing KVM device should fail host preflight");

        assert!(
            error.to_string().contains("missing KVM character device"),
            "unexpected error: {error}"
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn host_preflight_reports_symlinked_data_dir() {
        let temp_root = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        let real_data_dir = temp_root.join("real-data");
        let data_dir = temp_root.join("data-link");
        fs::create_dir_all(&real_data_dir).unwrap();
        std::os::unix::fs::symlink(&real_data_dir, &data_dir).unwrap();
        let image_dir = data_dir.join("images");
        let executor = LibvirtExecutor::new(data_dir, image_dir, "default".into(), "virbr0".into());

        let checks = executor.check_host_report().await;
        let storage = checks
            .iter()
            .find(|check| check.name == "storage")
            .expect("storage preflight check should be reported");

        assert_eq!(storage.status, "failed");
        assert!(
            storage.message.contains("data_dir") && storage.message.contains("symlink"),
            "unexpected storage check message: {}",
            storage.message
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn host_preflight_reports_symlinked_image_dir() {
        let data_dir = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        let real_image_dir = data_dir.join("real-images");
        let image_dir = data_dir.join("images");
        fs::create_dir_all(&real_image_dir).unwrap();
        std::os::unix::fs::symlink(&real_image_dir, &image_dir).unwrap();
        let executor = LibvirtExecutor::new(data_dir, image_dir, "default".into(), "virbr0".into());

        let checks = executor.check_host_report().await;
        let storage = checks
            .iter()
            .find(|check| check.name == "storage")
            .expect("storage preflight check should be reported");

        assert_eq!(storage.status, "failed");
        assert!(
            storage.message.contains("image_dir") && storage.message.contains("symlink"),
            "unexpected storage check message: {}",
            storage.message
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn host_preflight_reports_symlinked_vm_parent() {
        let data_dir = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        let image_dir = data_dir.join("images");
        let real_vm_parent = data_dir.join("real-vms");
        fs::create_dir_all(&image_dir).unwrap();
        fs::create_dir_all(&real_vm_parent).unwrap();
        std::os::unix::fs::symlink(&real_vm_parent, data_dir.join("vms")).unwrap();
        let executor = LibvirtExecutor::new(data_dir, image_dir, "default".into(), "virbr0".into());

        let checks = executor.check_host_report().await;
        let storage = checks
            .iter()
            .find(|check| check.name == "storage")
            .expect("storage preflight check should be reported");

        assert_eq!(storage.status, "failed");
        assert!(
            storage.message.contains("vm parent") && storage.message.contains("symlink"),
            "unexpected storage check message: {}",
            storage.message
        );
    }

    #[tokio::test]
    async fn host_preflight_reports_non_directory_vm_parent() {
        let data_dir = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        let image_dir = data_dir.join("images");
        fs::create_dir_all(&image_dir).unwrap();
        fs::write(data_dir.join("vms"), "not a directory").unwrap();
        let executor = LibvirtExecutor::new(data_dir, image_dir, "default".into(), "virbr0".into());

        let checks = executor.check_host_report().await;
        let storage = checks
            .iter()
            .find(|check| check.name == "storage")
            .expect("storage preflight check should be reported");

        assert_eq!(storage.status, "failed");
        assert!(
            storage.message.contains("vm parent") && storage.message.contains("directory"),
            "unexpected storage check message: {}",
            storage.message
        );
    }

    #[tokio::test]
    async fn host_preflight_redacts_failed_command_diagnostics() {
        let data_dir = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        let image_dir = data_dir.join("images");
        fs::create_dir_all(&image_dir).unwrap();
        let runner = FakeCommandRunner::virsh_version_failure(
            "virsh stderr: password=hunter2 credential=ag_plaintext",
        );
        let executor = LibvirtExecutor::new(data_dir, image_dir, "default".into(), "virbr0".into())
            .with_command_runner(Arc::new(runner));

        let checks = executor.check_host_report().await;
        let libvirt = checks
            .iter()
            .find(|check| check.name == "libvirt")
            .expect("libvirt preflight check should be reported");

        assert_eq!(libvirt.status, "failed");
        assert!(!libvirt.message.contains("hunter2"));
        assert!(!libvirt.message.contains("ag_plaintext"));
        assert!(libvirt.message.contains("password=[REDACTED]"));
        assert!(libvirt.message.contains("credential=[REDACTED]"));
    }

    #[test]
    fn host_preflight_message_escapes_non_line_ascii_controls() {
        let message = super::truncate_check_message("line 1\nline 2\t\x1b[31m");

        assert!(message.contains("line 1 line 2"));
        assert!(message.contains("\\x09"));
        assert!(message.contains("\\x1B"));
        assert!(!message.contains('\t'));
        assert!(!message.contains('\x1b'));
    }

    #[tokio::test]
    async fn create_vm_cleans_managed_artifacts_when_seed_iso_creation_fails_before_define() {
        let data_dir = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        let image_dir = data_dir.join("images");
        fs::create_dir_all(&image_dir).unwrap();
        fs::write(image_dir.join("debian.qcow2"), "base image").unwrap();
        let runner = FakeCommandRunner::seed_iso_failure("simulated seed iso failure");
        let executor = LibvirtExecutor::new(data_dir, image_dir, "default".into(), "virbr0".into())
            .with_command_runner(Arc::new(runner.clone()));
        let vm_id = VmId::new();
        let paths = executor.paths_for_vm(vm_id).unwrap();

        let error = executor
            .create_vm(&CreateVmRequest {
                node_id: NodeId::new(),
                vm_id: Some(vm_id),
                ip_pool_id: None,
                plan_id: None,
                assigned_ip: None,
                assigned_ip_prefix: None,
                assigned_gateway_ip: None,
                name: "demo".into(),
                image: "debian.qcow2".into(),
                ssh_public_key: None,
                cpu_cores: 1,
                memory_mb: 512,
                disk_gb: 10,
            })
            .await
            .expect_err("seed ISO failure should fail create_vm");

        assert!(
            error.to_string().contains("simulated seed iso failure"),
            "unexpected error: {error}"
        );
        assert!(
            !runner
                .calls()
                .iter()
                .any(|call| call.iter().any(|arg| arg == "define")),
            "libvirt define must not be reached after seed ISO failure"
        );
        assert!(
            !paths.vm_dir.exists(),
            "pre-define create failure should remove the managed VM directory"
        );
    }

    #[tokio::test]
    async fn create_vm_cleans_managed_artifacts_when_define_fails_without_domain() {
        let data_dir = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        let image_dir = data_dir.join("images");
        fs::create_dir_all(&image_dir).unwrap();
        fs::write(image_dir.join("debian.qcow2"), "base image").unwrap();
        let runner = FakeCommandRunner::define_failure_without_domain("simulated define failure");
        let executor = LibvirtExecutor::new(data_dir, image_dir, "default".into(), "virbr0".into())
            .with_command_runner(Arc::new(runner.clone()));
        let vm_id = VmId::new();
        let paths = executor.paths_for_vm(vm_id).unwrap();

        let error = executor
            .create_vm(&CreateVmRequest {
                node_id: NodeId::new(),
                vm_id: Some(vm_id),
                ip_pool_id: None,
                plan_id: None,
                assigned_ip: None,
                assigned_ip_prefix: None,
                assigned_gateway_ip: None,
                name: "demo".into(),
                image: "debian.qcow2".into(),
                ssh_public_key: None,
                cpu_cores: 1,
                memory_mb: 512,
                disk_gb: 10,
            })
            .await
            .expect_err("define failure should fail create_vm");

        assert!(
            error.to_string().contains("simulated define failure"),
            "unexpected error: {error}"
        );
        assert!(
            !runner
                .calls()
                .iter()
                .any(|call| call.iter().any(|arg| arg == "start")),
            "start must not run after define failure"
        );
        assert!(
            !paths.vm_dir.exists(),
            "define failure without a libvirt domain should remove the managed VM directory"
        );
    }

    #[tokio::test]
    async fn create_vm_preserves_managed_artifacts_when_define_fails_and_domstate_is_ambiguous() {
        let data_dir = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        let image_dir = data_dir.join("images");
        fs::create_dir_all(&image_dir).unwrap();
        fs::write(image_dir.join("debian.qcow2"), "base image").unwrap();
        let runner =
            FakeCommandRunner::define_failure_with_ambiguous_domstate("simulated define failure");
        let executor = LibvirtExecutor::new(data_dir, image_dir, "default".into(), "virbr0".into())
            .with_command_runner(Arc::new(runner.clone()));
        let vm_id = VmId::new();
        let paths = executor.paths_for_vm(vm_id).unwrap();

        let error = executor
            .create_vm(&CreateVmRequest {
                node_id: NodeId::new(),
                vm_id: Some(vm_id),
                ip_pool_id: None,
                plan_id: None,
                assigned_ip: None,
                assigned_ip_prefix: None,
                assigned_gateway_ip: None,
                name: "demo".into(),
                image: "debian.qcow2".into(),
                ssh_public_key: None,
                cpu_cores: 1,
                memory_mb: 512,
                disk_gb: 10,
            })
            .await
            .expect_err("ambiguous domstate after define failure should fail create_vm");

        assert!(
            error.to_string().contains("cleanup failed"),
            "unexpected error: {error}"
        );
        assert!(
            paths.vm_dir.exists(),
            "ambiguous libvirt ownership must preserve managed artifacts for inspection"
        );
    }

    #[tokio::test]
    async fn create_vm_undefines_and_cleans_managed_artifacts_when_start_fails_after_define() {
        let data_dir = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        let image_dir = data_dir.join("images");
        fs::create_dir_all(&image_dir).unwrap();
        fs::write(image_dir.join("debian.qcow2"), "base image").unwrap();
        let runner = FakeCommandRunner::stopped_after_start_failure("simulated start failure");
        let executor = LibvirtExecutor::new(data_dir, image_dir, "default".into(), "virbr0".into())
            .with_command_runner(Arc::new(runner.clone()));
        let vm_id = VmId::new();
        let paths = executor.paths_for_vm(vm_id).unwrap();

        let error = executor
            .create_vm(&CreateVmRequest {
                node_id: NodeId::new(),
                vm_id: Some(vm_id),
                ip_pool_id: None,
                plan_id: None,
                assigned_ip: None,
                assigned_ip_prefix: None,
                assigned_gateway_ip: None,
                name: "demo".into(),
                image: "debian.qcow2".into(),
                ssh_public_key: None,
                cpu_cores: 1,
                memory_mb: 512,
                disk_gb: 10,
            })
            .await
            .expect_err("start failure should fail create_vm");

        assert!(
            error.to_string().contains("simulated start failure"),
            "unexpected error: {error}"
        );
        assert!(
            runner
                .calls()
                .iter()
                .any(|call| call.iter().any(|arg| arg == "undefine")),
            "a stopped domain must be undefined after start failure"
        );
        assert!(
            !paths.vm_dir.exists(),
            "post-define start failure should remove the managed VM directory when the domain is stopped"
        );
    }

    #[tokio::test]
    async fn delete_vm_rejects_domain_metadata_for_different_vm_before_virsh() {
        let data_dir = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        let image_dir = data_dir.join("images");
        fs::create_dir_all(&image_dir).unwrap();
        let executor = LibvirtExecutor::new(data_dir, image_dir, "default".into(), "virbr0".into());
        let vm_id = VmId::new();
        let other_vm_id = VmId::new();
        let paths = executor.paths_for_vm(vm_id).unwrap();
        fs::create_dir_all(&paths.vm_dir).unwrap();
        fs::write(&paths.disk_path, "disk").unwrap();
        fs::write(&paths.seed_iso_path, "seed").unwrap();
        fs::write(
            &paths.domain_xml_path,
            format!(
                "<domain><name>{}</name><uuid>{}</uuid></domain>",
                super::domain_name(other_vm_id),
                other_vm_id
            ),
        )
        .unwrap();

        let error = executor
            .delete_vm(vm_id)
            .await
            .expect_err("delete must reject mismatched local domain metadata before virsh");

        assert!(
            error.to_string().contains("domain metadata"),
            "unexpected error: {error}"
        );
    }

    #[tokio::test]
    async fn stop_vm_waits_for_domain_to_be_shut_off_before_reporting_success() {
        let data_dir = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        let image_dir = data_dir.join("images");
        fs::create_dir_all(&image_dir).unwrap();
        let runner = FakeCommandRunner::stopped_after_shutdown();
        let executor = LibvirtExecutor::new(data_dir, image_dir, "default".into(), "virbr0".into())
            .with_command_runner(Arc::new(runner.clone()));
        let vm_id = VmId::new();
        let paths = executor.paths_for_vm(vm_id).unwrap();
        fs::create_dir_all(&paths.vm_dir).unwrap();
        fs::write(&paths.disk_path, "disk").unwrap();
        fs::write(&paths.seed_iso_path, "seed").unwrap();
        let request = CreateVmRequest {
            node_id: NodeId::new(),
            vm_id: Some(vm_id),
            ip_pool_id: None,
            plan_id: None,
            assigned_ip: None,
            assigned_ip_prefix: None,
            assigned_gateway_ip: None,
            name: "demo".into(),
            image: "debian.qcow2".into(),
            ssh_public_key: None,
            cpu_cores: 1,
            memory_mb: 512,
            disk_gb: 10,
        };
        fs::write(
            &paths.domain_xml_path,
            executor.domain_xml(&request, vm_id, &paths).unwrap(),
        )
        .unwrap();

        executor
            .virsh_vm_command("shutdown", vm_id)
            .await
            .expect("stop should complete after domstate reports shut off");

        let calls = runner.calls();
        let shutdown_index = calls
            .iter()
            .position(|call| call.iter().any(|arg| arg == "shutdown"))
            .expect("shutdown should be issued");
        let domstate_index = calls
            .iter()
            .position(|call| call.iter().any(|arg| arg == "domstate"))
            .expect("stop should read domstate before success");

        assert!(
            domstate_index > shutdown_index,
            "domstate must be checked after shutdown before reporting success"
        );
    }

    #[tokio::test]
    async fn start_vm_waits_for_domain_to_be_running_before_reporting_success() {
        let data_dir = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        let image_dir = data_dir.join("images");
        fs::create_dir_all(&image_dir).unwrap();
        let runner = FakeCommandRunner::running_after_power_action();
        let executor = LibvirtExecutor::new(data_dir, image_dir, "default".into(), "virbr0".into())
            .with_command_runner(Arc::new(runner.clone()));
        let vm_id = VmId::new();
        let paths = executor.paths_for_vm(vm_id).unwrap();
        fs::create_dir_all(&paths.vm_dir).unwrap();
        fs::write(&paths.disk_path, "disk").unwrap();
        fs::write(&paths.seed_iso_path, "seed").unwrap();
        let request = CreateVmRequest {
            node_id: NodeId::new(),
            vm_id: Some(vm_id),
            ip_pool_id: None,
            plan_id: None,
            assigned_ip: None,
            assigned_ip_prefix: None,
            assigned_gateway_ip: None,
            name: "demo".into(),
            image: "debian.qcow2".into(),
            ssh_public_key: None,
            cpu_cores: 1,
            memory_mb: 512,
            disk_gb: 10,
        };
        fs::write(
            &paths.domain_xml_path,
            executor.domain_xml(&request, vm_id, &paths).unwrap(),
        )
        .unwrap();

        executor
            .virsh_vm_command("start", vm_id)
            .await
            .expect("start should complete after domstate reports running");

        let calls = runner.calls();
        let start_index = calls
            .iter()
            .position(|call| call.iter().any(|arg| arg == "start"))
            .expect("start should be issued");
        let domstate_index = calls
            .iter()
            .position(|call| call.iter().any(|arg| arg == "domstate"))
            .expect("start should read domstate before success");

        assert!(
            domstate_index > start_index,
            "domstate must be checked after start before reporting success"
        );
    }

    #[tokio::test]
    async fn reboot_vm_waits_for_domain_to_be_running_before_reporting_success() {
        let data_dir = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        let image_dir = data_dir.join("images");
        fs::create_dir_all(&image_dir).unwrap();
        let runner = FakeCommandRunner::running_after_power_action();
        let executor = LibvirtExecutor::new(data_dir, image_dir, "default".into(), "virbr0".into())
            .with_command_runner(Arc::new(runner.clone()));
        let vm_id = VmId::new();
        let paths = executor.paths_for_vm(vm_id).unwrap();
        fs::create_dir_all(&paths.vm_dir).unwrap();
        fs::write(&paths.disk_path, "disk").unwrap();
        fs::write(&paths.seed_iso_path, "seed").unwrap();
        let request = CreateVmRequest {
            node_id: NodeId::new(),
            vm_id: Some(vm_id),
            ip_pool_id: None,
            plan_id: None,
            assigned_ip: None,
            assigned_ip_prefix: None,
            assigned_gateway_ip: None,
            name: "demo".into(),
            image: "debian.qcow2".into(),
            ssh_public_key: None,
            cpu_cores: 1,
            memory_mb: 512,
            disk_gb: 10,
        };
        fs::write(
            &paths.domain_xml_path,
            executor.domain_xml(&request, vm_id, &paths).unwrap(),
        )
        .unwrap();

        executor
            .virsh_vm_command("reboot", vm_id)
            .await
            .expect("reboot should complete after domstate reports running");

        let calls = runner.calls();
        let reboot_index = calls
            .iter()
            .position(|call| call.iter().any(|arg| arg == "reboot"))
            .expect("reboot should be issued");
        let domstate_index = calls
            .iter()
            .position(|call| call.iter().any(|arg| arg == "domstate"))
            .expect("reboot should read domstate before success");

        assert!(
            domstate_index > reboot_index,
            "domstate must be checked after reboot before reporting success"
        );
    }

    #[tokio::test]
    async fn delete_vm_rejects_non_directory_vm_root_before_artifact_checks() {
        let data_dir = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        let image_dir = data_dir.join("images");
        fs::create_dir_all(data_dir.join("vms")).unwrap();
        fs::create_dir_all(&image_dir).unwrap();
        let executor = LibvirtExecutor::new(data_dir, image_dir, "default".into(), "virbr0".into());
        let vm_id = VmId::new();
        let paths = executor.paths_for_vm(vm_id).unwrap();
        fs::write(&paths.vm_dir, "not a directory").unwrap();

        let error = executor
            .delete_vm(vm_id)
            .await
            .expect_err("delete must reject a non-directory VM root before artifact checks");

        assert!(
            error.to_string().contains("vm directory"),
            "unexpected error: {error}"
        );
    }

    #[tokio::test]
    async fn delete_vm_rejects_unexpected_vm_directory_entries_before_cleanup() {
        let data_dir = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        let image_dir = data_dir.join("images");
        fs::create_dir_all(&image_dir).unwrap();
        let executor = LibvirtExecutor::new(data_dir, image_dir, "default".into(), "virbr0".into());
        let vm_id = VmId::new();
        let paths = executor.paths_for_vm(vm_id).unwrap();
        fs::create_dir_all(&paths.vm_dir).unwrap();
        fs::write(&paths.disk_path, "disk").unwrap();
        fs::write(&paths.seed_iso_path, "seed").unwrap();
        fs::write(
            &paths.domain_xml_path,
            format!(
                r#"<domain>
  <name>{name}</name>
  <uuid>{vm_id}</uuid>
  <devices>
    <disk type="file" device="disk"><source file="{disk}"/></disk>
    <disk type="file" device="cdrom"><source file="{seed}"/></disk>
  </devices>
</domain>"#,
                name = super::domain_name(vm_id),
                disk = super::xml_escape(super::path_str(&paths.disk_path).unwrap()),
                seed = super::xml_escape(super::path_str(&paths.seed_iso_path).unwrap()),
            ),
        )
        .unwrap();
        let unexpected_path = paths.vm_dir.join("operator-note.txt");
        fs::write(&unexpected_path, "inspect me before deleting").unwrap();

        let error = executor
            .delete_vm(vm_id)
            .await
            .expect_err("delete must reject unexpected files instead of removing the whole VM dir");

        assert!(
            error.to_string().contains("unexpected"),
            "unexpected error: {error}"
        );
        assert!(unexpected_path.exists());
    }

    #[tokio::test]
    async fn delete_vm_preserves_managed_files_when_undefine_fails() {
        let data_dir = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        let image_dir = data_dir.join("images");
        fs::create_dir_all(&image_dir).unwrap();
        let runner = FakeCommandRunner::stopped_with_undefine_failure();
        let executor = LibvirtExecutor::new(data_dir, image_dir, "default".into(), "virbr0".into())
            .with_command_runner(Arc::new(runner.clone()));
        let vm_id = VmId::new();
        let paths = executor.paths_for_vm(vm_id).unwrap();
        fs::create_dir_all(&paths.vm_dir).unwrap();
        fs::write(&paths.disk_path, "disk").unwrap();
        fs::write(&paths.seed_iso_path, "seed").unwrap();
        let request = CreateVmRequest {
            node_id: NodeId::new(),
            vm_id: Some(vm_id),
            ip_pool_id: None,
            plan_id: None,
            assigned_ip: None,
            assigned_ip_prefix: None,
            assigned_gateway_ip: None,
            name: "demo".into(),
            image: "debian.qcow2".into(),
            ssh_public_key: None,
            cpu_cores: 1,
            memory_mb: 512,
            disk_gb: 10,
        };
        fs::write(
            &paths.domain_xml_path,
            executor.domain_xml(&request, vm_id, &paths).unwrap(),
        )
        .unwrap();

        let error = executor
            .delete_vm(vm_id)
            .await
            .expect_err("delete must fail when libvirt cannot undefine the domain");

        assert!(
            error.to_string().contains("simulated undefine failure"),
            "unexpected error: {error}"
        );
        assert!(
            runner
                .calls()
                .iter()
                .any(|call| call.iter().any(|arg| arg == "undefine")),
            "undefine should be reached when domstate reports shut off"
        );
        assert!(
            paths.vm_dir.exists(),
            "managed files must remain for inspection when undefine fails"
        );
        assert!(paths.disk_path.exists());
        assert!(paths.seed_iso_path.exists());
        assert!(paths.domain_xml_path.exists());
    }

    #[tokio::test]
    async fn delete_vm_preserves_managed_files_when_destroy_leaves_domain_running() {
        let data_dir = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        let image_dir = data_dir.join("images");
        fs::create_dir_all(&image_dir).unwrap();
        let runner = FakeCommandRunner::running_after_destroy();
        let executor = LibvirtExecutor::new(data_dir, image_dir, "default".into(), "virbr0".into())
            .with_command_runner(Arc::new(runner.clone()));
        let vm_id = VmId::new();
        let paths = executor.paths_for_vm(vm_id).unwrap();
        fs::create_dir_all(&paths.vm_dir).unwrap();
        fs::write(&paths.disk_path, "disk").unwrap();
        fs::write(&paths.seed_iso_path, "seed").unwrap();
        let request = CreateVmRequest {
            node_id: NodeId::new(),
            vm_id: Some(vm_id),
            ip_pool_id: None,
            plan_id: None,
            assigned_ip: None,
            assigned_ip_prefix: None,
            assigned_gateway_ip: None,
            name: "demo".into(),
            image: "debian.qcow2".into(),
            ssh_public_key: None,
            cpu_cores: 1,
            memory_mb: 512,
            disk_gb: 10,
        };
        fs::write(
            &paths.domain_xml_path,
            executor.domain_xml(&request, vm_id, &paths).unwrap(),
        )
        .unwrap();

        let error = executor
            .delete_vm(vm_id)
            .await
            .expect_err("delete must not clean files while the domain is still running");

        assert!(
            error.to_string().contains("still running"),
            "unexpected error: {error}"
        );
        assert!(
            !runner
                .calls()
                .iter()
                .any(|call| call.iter().any(|arg| arg == "undefine")),
            "undefine should not run while domstate reports running"
        );
        assert!(paths.vm_dir.exists());
        assert!(paths.disk_path.exists());
        assert!(paths.seed_iso_path.exists());
        assert!(paths.domain_xml_path.exists());
    }

    #[tokio::test]
    async fn reinstall_vm_preserves_existing_disk_when_destroy_leaves_domain_running() {
        let data_dir = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        let image_dir = data_dir.join("images");
        fs::create_dir_all(&image_dir).unwrap();
        fs::write(image_dir.join("debian.qcow2"), "base image").unwrap();
        let runner = FakeCommandRunner::running_after_destroy();
        let executor = LibvirtExecutor::new(data_dir, image_dir, "default".into(), "virbr0".into())
            .with_command_runner(Arc::new(runner.clone()));
        let vm_id = VmId::new();
        let paths = executor.paths_for_vm(vm_id).unwrap();
        fs::create_dir_all(&paths.vm_dir).unwrap();
        fs::write(&paths.disk_path, "existing disk").unwrap();
        fs::write(&paths.seed_iso_path, "existing seed").unwrap();
        fs::write(paths.vm_dir.join("user-data"), "existing user data").unwrap();
        fs::write(paths.vm_dir.join("meta-data"), "existing meta data").unwrap();
        let request = CreateVmRequest {
            node_id: NodeId::new(),
            vm_id: Some(vm_id),
            ip_pool_id: None,
            plan_id: None,
            assigned_ip: None,
            assigned_ip_prefix: None,
            assigned_gateway_ip: None,
            name: "demo".into(),
            image: "debian.qcow2".into(),
            ssh_public_key: None,
            cpu_cores: 1,
            memory_mb: 512,
            disk_gb: 10,
        };
        fs::write(
            &paths.domain_xml_path,
            executor.domain_xml(&request, vm_id, &paths).unwrap(),
        )
        .unwrap();

        let error = executor
            .reinstall_vm(vm_id, "demo", "debian.qcow2", None, 10)
            .await
            .expect_err("reinstall must not replace disk while the domain is still running");

        assert!(
            error.to_string().contains("still running"),
            "unexpected error: {error}"
        );
        assert_eq!(
            fs::read_to_string(&paths.disk_path).unwrap(),
            "existing disk"
        );
        assert_eq!(
            fs::read_to_string(&paths.seed_iso_path).unwrap(),
            "existing seed"
        );
        assert!(
            !runner.calls().iter().any(|call| call
                .first()
                .is_some_and(|program| program == "qemu-img")
                && call.iter().any(|arg| arg == "create")),
            "qemu-img create must not run while domstate reports running"
        );
    }

    #[tokio::test]
    async fn reinstall_vm_waits_for_domain_running_after_restart() {
        let data_dir = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        let image_dir = data_dir.join("images");
        fs::create_dir_all(&image_dir).unwrap();
        fs::write(image_dir.join("debian.qcow2"), "base image").unwrap();
        let runner = FakeCommandRunner::stopped_then_running_after_start();
        let executor = LibvirtExecutor::new(data_dir, image_dir, "default".into(), "virbr0".into())
            .with_command_runner(Arc::new(runner.clone()));
        let vm_id = VmId::new();
        let paths = executor.paths_for_vm(vm_id).unwrap();
        fs::create_dir_all(&paths.vm_dir).unwrap();
        fs::write(&paths.disk_path, "existing disk").unwrap();
        fs::write(&paths.seed_iso_path, "existing seed").unwrap();
        fs::write(paths.vm_dir.join("user-data"), "existing user data").unwrap();
        fs::write(paths.vm_dir.join("meta-data"), "existing meta data").unwrap();
        let request = CreateVmRequest {
            node_id: NodeId::new(),
            vm_id: Some(vm_id),
            ip_pool_id: None,
            plan_id: None,
            assigned_ip: None,
            assigned_ip_prefix: None,
            assigned_gateway_ip: None,
            name: "demo".into(),
            image: "debian.qcow2".into(),
            ssh_public_key: None,
            cpu_cores: 1,
            memory_mb: 512,
            disk_gb: 10,
        };
        fs::write(
            &paths.domain_xml_path,
            executor.domain_xml(&request, vm_id, &paths).unwrap(),
        )
        .unwrap();

        executor
            .reinstall_vm(vm_id, "demo", "debian.qcow2", None, 10)
            .await
            .expect("reinstall should succeed when the restarted domain reaches running");

        let calls = runner.calls();
        let start_index = calls
            .iter()
            .position(|call| call.iter().any(|arg| arg == "start"))
            .expect("reinstall must start the domain");
        assert!(
            calls
                .iter()
                .skip(start_index + 1)
                .any(|call| call.iter().any(|arg| arg == "domstate")),
            "reinstall must verify the domain state after virsh start"
        );
    }

    #[tokio::test]
    async fn reinstall_vm_rejects_unsafe_cloud_init_name_before_destroying_domain() {
        let data_dir = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        let image_dir = data_dir.join("images");
        fs::create_dir_all(&image_dir).unwrap();
        fs::write(image_dir.join("debian.qcow2"), "base image").unwrap();
        let runner = FakeCommandRunner::stopped_after_shutdown();
        let executor = LibvirtExecutor::new(data_dir, image_dir, "default".into(), "virbr0".into())
            .with_command_runner(Arc::new(runner.clone()));
        let vm_id = VmId::new();
        let paths = executor.paths_for_vm(vm_id).unwrap();
        fs::create_dir_all(&paths.vm_dir).unwrap();
        fs::write(&paths.disk_path, "existing disk").unwrap();
        fs::write(&paths.seed_iso_path, "existing seed").unwrap();
        fs::write(paths.vm_dir.join("user-data"), "existing user data").unwrap();
        fs::write(paths.vm_dir.join("meta-data"), "existing meta data").unwrap();
        let request = CreateVmRequest {
            node_id: NodeId::new(),
            vm_id: Some(vm_id),
            ip_pool_id: None,
            plan_id: None,
            assigned_ip: None,
            assigned_ip_prefix: None,
            assigned_gateway_ip: None,
            name: "demo".into(),
            image: "debian.qcow2".into(),
            ssh_public_key: None,
            cpu_cores: 1,
            memory_mb: 512,
            disk_gb: 10,
        };
        fs::write(
            &paths.domain_xml_path,
            executor.domain_xml(&request, vm_id, &paths).unwrap(),
        )
        .unwrap();

        let error = executor
            .reinstall_vm(vm_id, "demo\ninstance-id: evil", "debian.qcow2", None, 10)
            .await
            .expect_err("unsafe cloud-init name should fail before domain shutdown");

        assert!(
            error.to_string().contains("cloud-init metadata"),
            "unexpected error: {error}"
        );
        assert!(
            !runner
                .calls()
                .iter()
                .any(|call| call.iter().any(|arg| arg == "destroy")),
            "unsafe metadata must be rejected before virsh destroy"
        );
        assert_eq!(
            fs::read_to_string(paths.vm_dir.join("meta-data")).unwrap(),
            "existing meta data"
        );
    }

    #[tokio::test]
    async fn reinstall_vm_preserves_existing_artifacts_when_seed_iso_creation_fails() {
        let data_dir = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        let image_dir = data_dir.join("images");
        fs::create_dir_all(&image_dir).unwrap();
        fs::write(image_dir.join("debian.qcow2"), "base image").unwrap();
        let runner = FakeCommandRunner::seed_iso_failure("simulated seed iso failure");
        let executor = LibvirtExecutor::new(data_dir, image_dir, "default".into(), "virbr0".into())
            .with_command_runner(Arc::new(runner.clone()));
        let vm_id = VmId::new();
        let paths = executor.paths_for_vm(vm_id).unwrap();
        fs::create_dir_all(&paths.vm_dir).unwrap();
        fs::write(&paths.disk_path, "existing disk").unwrap();
        fs::write(&paths.seed_iso_path, "existing seed").unwrap();
        fs::write(paths.vm_dir.join("user-data"), "existing user data").unwrap();
        fs::write(paths.vm_dir.join("meta-data"), "existing meta data").unwrap();
        let request = CreateVmRequest {
            node_id: NodeId::new(),
            vm_id: Some(vm_id),
            ip_pool_id: None,
            plan_id: None,
            assigned_ip: None,
            assigned_ip_prefix: None,
            assigned_gateway_ip: None,
            name: "demo".into(),
            image: "debian.qcow2".into(),
            ssh_public_key: None,
            cpu_cores: 1,
            memory_mb: 512,
            disk_gb: 10,
        };
        fs::write(
            &paths.domain_xml_path,
            executor.domain_xml(&request, vm_id, &paths).unwrap(),
        )
        .unwrap();

        let error = executor
            .reinstall_vm(vm_id, "demo", "debian.qcow2", None, 10)
            .await
            .expect_err("seed ISO failure should not replace existing reinstall artifacts");

        assert!(
            error.to_string().contains("simulated seed iso failure"),
            "unexpected error: {error}"
        );
        assert_eq!(
            fs::read_to_string(&paths.disk_path).unwrap(),
            "existing disk"
        );
        assert_eq!(
            fs::read_to_string(&paths.seed_iso_path).unwrap(),
            "existing seed"
        );
        assert!(
            !paths.vm_dir.join("disk.qcow2.reinstalling").exists(),
            "failed reinstall should not leave a temporary disk"
        );
        assert!(
            !paths.vm_dir.join("seed.iso.reinstalling").exists(),
            "failed reinstall should not leave a temporary seed ISO"
        );
    }

    #[tokio::test]
    async fn reinstall_vm_rejects_stale_temp_artifacts_before_destroying_domain() {
        let data_dir = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        let image_dir = data_dir.join("images");
        fs::create_dir_all(&image_dir).unwrap();
        fs::write(image_dir.join("debian.qcow2"), "base image").unwrap();
        let runner = FakeCommandRunner::stopped_after_start_failure("start should not run");
        let executor = LibvirtExecutor::new(data_dir, image_dir, "default".into(), "virbr0".into())
            .with_command_runner(Arc::new(runner.clone()));
        let vm_id = VmId::new();
        let paths = executor.paths_for_vm(vm_id).unwrap();
        fs::create_dir_all(&paths.vm_dir).unwrap();
        fs::write(&paths.disk_path, "existing disk").unwrap();
        fs::write(&paths.seed_iso_path, "existing seed").unwrap();
        fs::write(paths.vm_dir.join("user-data"), "existing user data").unwrap();
        fs::write(paths.vm_dir.join("meta-data"), "existing meta data").unwrap();
        fs::write(paths.vm_dir.join("disk.qcow2.reinstalling"), "stale disk").unwrap();
        let request = CreateVmRequest {
            node_id: NodeId::new(),
            vm_id: Some(vm_id),
            ip_pool_id: None,
            plan_id: None,
            assigned_ip: None,
            assigned_ip_prefix: None,
            assigned_gateway_ip: None,
            name: "demo".into(),
            image: "debian.qcow2".into(),
            ssh_public_key: None,
            cpu_cores: 1,
            memory_mb: 512,
            disk_gb: 10,
        };
        fs::write(
            &paths.domain_xml_path,
            executor.domain_xml(&request, vm_id, &paths).unwrap(),
        )
        .unwrap();

        let error = executor
            .reinstall_vm(vm_id, "demo", "debian.qcow2", None, 10)
            .await
            .expect_err("stale reinstall temp artifacts should fail before domain shutdown");

        assert!(
            error.to_string().contains("stale reinstall artifact"),
            "unexpected error: {error}"
        );
        assert!(
            !runner
                .calls()
                .iter()
                .any(|call| call.iter().any(|arg| arg == "destroy")),
            "stale local staging state must be rejected before virsh destroy"
        );
        assert_eq!(
            fs::read_to_string(&paths.disk_path).unwrap(),
            "existing disk"
        );
        assert_eq!(
            fs::read_to_string(&paths.seed_iso_path).unwrap(),
            "existing seed"
        );
    }

    #[test]
    fn commit_reinstall_artifacts_validates_all_targets_before_replacing_disk() {
        let data_dir = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        let image_dir = data_dir.join("images");
        fs::create_dir_all(&image_dir).unwrap();
        let executor = LibvirtExecutor::new(data_dir, image_dir, "default".into(), "virbr0".into());
        let vm_id = VmId::new();
        let paths = executor.paths_for_vm(vm_id).unwrap();
        let temp_paths = super::ReinstallTempPaths::for_vm(&paths);
        let user_data_path = paths.vm_dir.join("user-data");
        let meta_data_path = paths.vm_dir.join("meta-data");

        fs::create_dir_all(&paths.vm_dir).unwrap();
        fs::write(&paths.disk_path, "existing disk").unwrap();
        fs::create_dir(&paths.seed_iso_path).unwrap();
        fs::write(&user_data_path, "existing user data").unwrap();
        fs::write(&meta_data_path, "existing meta data").unwrap();
        fs::write(&temp_paths.disk_path, "replacement disk").unwrap();
        fs::write(&temp_paths.seed_iso_path, "replacement seed").unwrap();
        fs::write(&temp_paths.user_data_path, "replacement user data").unwrap();
        fs::write(&temp_paths.meta_data_path, "replacement meta data").unwrap();

        let error = executor
            .commit_reinstall_artifacts(&paths, &temp_paths, &user_data_path, &meta_data_path)
            .expect_err("unsafe later target should fail before any live artifact is replaced");

        assert!(
            error.to_string().contains("regular file"),
            "unexpected error: {error}"
        );
        assert_eq!(
            fs::read_to_string(&paths.disk_path).unwrap(),
            "existing disk"
        );
        assert_eq!(
            fs::read_to_string(&temp_paths.disk_path).unwrap(),
            "replacement disk"
        );
    }

    #[test]
    fn prepare_vm_dir_for_create_creates_missing_managed_directories() {
        let data_dir = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        let image_dir = data_dir.join("images");
        fs::create_dir_all(&image_dir).unwrap();
        let executor = LibvirtExecutor::new(data_dir, image_dir, "default".into(), "virbr0".into());
        let vm_id = VmId::new();
        let paths = executor.paths_for_vm(vm_id).unwrap();

        executor
            .prepare_vm_dir_for_create(&paths.vm_dir)
            .expect("missing managed VM directories should be created safely");

        assert!(paths.vm_dir.is_dir());
    }

    #[cfg(unix)]
    #[test]
    fn prepare_vm_dir_for_create_rejects_symlinked_parent_after_path_planning() {
        let data_dir = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        let image_dir = data_dir.join("images");
        fs::create_dir_all(&image_dir).unwrap();
        let executor = LibvirtExecutor::new(
            data_dir.clone(),
            image_dir,
            "default".into(),
            "virbr0".into(),
        );
        let paths = executor.paths_for_vm(VmId::new()).unwrap();
        let outside_parent =
            std::env::temp_dir().join(format!("vps-agent-outside-vms-{}", Uuid::new_v4()));
        fs::create_dir_all(&outside_parent).unwrap();
        std::os::unix::fs::symlink(&outside_parent, data_dir.join("vms")).unwrap();

        let error = executor
            .prepare_vm_dir_for_create(&paths.vm_dir)
            .expect_err("create must reject a symlinked vm parent before creating the VM root");

        assert!(
            error.to_string().contains("vm parent") && error.to_string().contains("symlink"),
            "unexpected error: {error}"
        );

        let _ = fs::remove_dir_all(outside_parent);
    }

    #[cfg(unix)]
    #[test]
    fn paths_for_vm_rejects_symlinked_vm_root_before_create() {
        let data_dir = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        let image_dir = data_dir.join("images");
        fs::create_dir_all(data_dir.join("vms")).unwrap();
        fs::create_dir_all(&image_dir).unwrap();
        let outside_dir =
            std::env::temp_dir().join(format!("vps-agent-outside-vm-{}", Uuid::new_v4()));
        fs::create_dir_all(&outside_dir).unwrap();
        let executor = LibvirtExecutor::new(data_dir, image_dir, "default".into(), "virbr0".into());
        let vm_id = VmId::new();
        let vm_dir = executor.data_dir.join("vms").join(vm_id.to_string());
        std::os::unix::fs::symlink(&outside_dir, &vm_dir).unwrap();

        let error = executor
            .paths_for_vm(vm_id)
            .expect_err("VM root symlink should fail before create_dir_all");
        assert!(
            error.to_string().contains("symlink"),
            "unexpected error: {error}"
        );
    }

    #[cfg(unix)]
    #[test]
    fn paths_for_vm_rejects_symlinked_vm_parent_before_create() {
        let data_dir = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        let image_dir = data_dir.join("images");
        fs::create_dir_all(&data_dir).unwrap();
        fs::create_dir_all(&image_dir).unwrap();
        let alternate_vm_parent = data_dir.join("alternate-vms");
        fs::create_dir_all(&alternate_vm_parent).unwrap();
        std::os::unix::fs::symlink(&alternate_vm_parent, data_dir.join("vms")).unwrap();
        let executor = LibvirtExecutor::new(data_dir, image_dir, "default".into(), "virbr0".into());

        let error = executor
            .paths_for_vm(VmId::new())
            .expect_err("VM parent symlink should fail before create_dir_all");
        assert!(
            error.to_string().contains("symlink"),
            "unexpected error: {error}"
        );
    }

    #[cfg(unix)]
    #[test]
    fn paths_for_vm_rejects_symlinked_data_dir_before_create() {
        let temp_root = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        let real_data_dir = temp_root.join("real-data");
        let data_dir = temp_root.join("data-link");
        fs::create_dir_all(&real_data_dir).unwrap();
        std::os::unix::fs::symlink(&real_data_dir, &data_dir).unwrap();
        let image_dir = data_dir.join("images");
        let executor = LibvirtExecutor::new(data_dir, image_dir, "default".into(), "virbr0".into());

        let error = executor
            .paths_for_vm(VmId::new())
            .expect_err("data_dir symlink should fail before create_dir_all");

        assert!(
            error.to_string().contains("data_dir") && error.to_string().contains("symlink"),
            "unexpected error: {error}"
        );
    }

    #[cfg(unix)]
    #[test]
    fn paths_for_vm_rejects_non_directory_data_dir_before_create() {
        let data_dir = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        fs::write(&data_dir, "not a directory").unwrap();
        let image_dir = data_dir.join("images");
        let executor = LibvirtExecutor::new(data_dir, image_dir, "default".into(), "virbr0".into());

        let error = executor
            .paths_for_vm(VmId::new())
            .expect_err("data_dir file should fail before create_dir_all");

        assert!(
            error.to_string().contains("data_dir") && error.to_string().contains("directory"),
            "unexpected error: {error}"
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn create_vm_rejects_preexisting_symlinked_disk_before_qemu_img() {
        let data_dir = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        let image_dir = data_dir.join("images");
        fs::create_dir_all(&image_dir).unwrap();
        fs::write(image_dir.join("debian-12.qcow2"), "base image").unwrap();

        let executor = LibvirtExecutor::new(data_dir, image_dir, "default".into(), "virbr0".into());
        let vm_id = VmId::new();
        let paths = executor.paths_for_vm(vm_id).unwrap();
        fs::create_dir_all(&paths.vm_dir).unwrap();
        let outside_disk =
            std::env::temp_dir().join(format!("vps-agent-outside-disk-{}", Uuid::new_v4()));
        fs::write(&outside_disk, "outside").unwrap();
        std::os::unix::fs::symlink(&outside_disk, &paths.disk_path).unwrap();

        let error = executor
            .create_vm(&CreateVmRequest {
                node_id: NodeId::new(),
                vm_id: Some(vm_id),
                ip_pool_id: None,
                plan_id: None,
                assigned_ip: None,
                assigned_ip_prefix: None,
                assigned_gateway_ip: None,
                name: "demo".into(),
                image: "debian-12.qcow2".into(),
                ssh_public_key: None,
                cpu_cores: 1,
                memory_mb: 512,
                disk_gb: 10,
            })
            .await
            .expect_err("create must reject a pre-existing symlinked disk before qemu-img");

        assert!(
            error.to_string().contains("symlink"),
            "unexpected error: {error}"
        );

        let _ = fs::remove_file(outside_disk);
    }

    #[test]
    fn replace_managed_file_replaces_existing_regular_file_safely() {
        let data_dir = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        let vm_dir = data_dir.join("vms").join(Uuid::new_v4().to_string());
        let path = vm_dir.join("user-data");
        fs::create_dir_all(&vm_dir).unwrap();
        fs::write(&path, "old cloud init").unwrap();

        super::replace_managed_file(&path, &data_dir, "new cloud init")
            .expect("regular managed cloud-init artifact should be replaceable");

        assert_eq!(fs::read_to_string(&path).unwrap(), "new cloud init");
    }

    #[cfg(unix)]
    #[test]
    fn replace_managed_file_rejects_symlinked_cloud_init_artifacts() {
        let data_dir = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        let vm_dir = data_dir.join("vms").join(Uuid::new_v4().to_string());
        let path = vm_dir.join("user-data");
        let outside_path =
            std::env::temp_dir().join(format!("vps-agent-outside-user-data-{}", Uuid::new_v4()));
        fs::create_dir_all(&vm_dir).unwrap();
        fs::write(&outside_path, "outside").unwrap();
        std::os::unix::fs::symlink(&outside_path, &path).unwrap();

        let error = super::replace_managed_file(&path, &data_dir, "new cloud init")
            .expect_err("managed cloud-init replacement must reject symlinked artifacts");

        assert!(
            error.to_string().contains("symlink"),
            "unexpected error: {error}"
        );
        assert_eq!(fs::read_to_string(&outside_path).unwrap(), "outside");

        let _ = fs::remove_file(outside_path);
    }

    #[test]
    fn remove_required_managed_file_removes_existing_regular_file() {
        let data_dir = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        let vm_dir = data_dir.join("vms").join(Uuid::new_v4().to_string());
        let path = vm_dir.join("disk.qcow2");
        fs::create_dir_all(&vm_dir).unwrap();
        fs::write(&path, "disk").unwrap();
        let executor = LibvirtExecutor::new(
            data_dir,
            PathBuf::from("/images"),
            "default".into(),
            "virbr0".into(),
        );

        executor
            .remove_required_managed_file(&path)
            .expect("existing managed disk should be removable");

        assert!(!path.exists());
    }

    #[test]
    fn remove_required_managed_file_rejects_missing_artifact() {
        let data_dir = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        let vm_dir = data_dir.join("vms").join(Uuid::new_v4().to_string());
        let path = vm_dir.join("disk.qcow2");
        fs::create_dir_all(&vm_dir).unwrap();
        let executor = LibvirtExecutor::new(
            data_dir,
            PathBuf::from("/images"),
            "default".into(),
            "virbr0".into(),
        );

        let error = executor
            .remove_required_managed_file(&path)
            .expect_err("missing managed disk should not be treated as removed");

        assert!(
            error.to_string().contains("missing managed file"),
            "unexpected error: {error}"
        );
    }

    #[test]
    fn domain_metadata_validation_ignores_spoofed_comment_fragments() {
        let data_dir = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        let image_dir = data_dir.join("images");
        fs::create_dir_all(&image_dir).unwrap();
        let executor = LibvirtExecutor::new(data_dir, image_dir, "default".into(), "virbr0".into());
        let vm_id = VmId::new();
        let other_vm_id = VmId::new();
        let paths = executor.paths_for_vm(vm_id).unwrap();
        fs::create_dir_all(&paths.vm_dir).unwrap();
        fs::write(&paths.disk_path, "disk").unwrap();
        fs::write(&paths.seed_iso_path, "seed").unwrap();
        fs::write(
            &paths.domain_xml_path,
            format!(
                r#"<domain>
  <!-- <name>{expected_name}</name><uuid>{expected_uuid}</uuid><source file="{expected_disk}"/><source file="{expected_seed}"/> -->
  <name>{other_name}</name>
  <uuid>{other_uuid}</uuid>
  <devices>
    <disk type="file" device="disk"><source file="/tmp/outside.qcow2"/></disk>
    <disk type="file" device="cdrom"><source file="/tmp/outside.iso"/></disk>
  </devices>
</domain>"#,
                expected_name = super::domain_name(vm_id),
                expected_uuid = vm_id,
                expected_disk = super::xml_escape(super::path_str(&paths.disk_path).unwrap()),
                expected_seed = super::xml_escape(super::path_str(&paths.seed_iso_path).unwrap()),
                other_name = super::domain_name(other_vm_id),
                other_uuid = other_vm_id,
            ),
        )
        .unwrap();

        let error = executor
            .ensure_vm_domain_metadata(vm_id, &paths)
            .expect_err("domain metadata validation must inspect XML elements, not comments");

        assert!(
            error.to_string().contains("domain metadata"),
            "unexpected error: {error}"
        );
    }

    #[test]
    fn domain_metadata_rejects_non_regular_managed_artifacts() {
        let data_dir = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        let image_dir = data_dir.join("images");
        fs::create_dir_all(&image_dir).unwrap();
        let executor = LibvirtExecutor::new(data_dir, image_dir, "default".into(), "virbr0".into());
        let vm_id = VmId::new();
        let paths = executor.paths_for_vm(vm_id).unwrap();
        fs::create_dir_all(&paths.vm_dir).unwrap();
        fs::create_dir_all(&paths.disk_path).unwrap();
        fs::write(&paths.seed_iso_path, "seed").unwrap();
        fs::write(
            &paths.domain_xml_path,
            executor
                .domain_xml(
                    &CreateVmRequest {
                        node_id: NodeId::new(),
                        vm_id: Some(vm_id),
                        ip_pool_id: None,
                        plan_id: None,
                        assigned_ip: None,
                        assigned_ip_prefix: None,
                        assigned_gateway_ip: None,
                        name: "demo".into(),
                        image: "debian.qcow2".into(),
                        ssh_public_key: None,
                        cpu_cores: 1,
                        memory_mb: 512,
                        disk_gb: 10,
                    },
                    vm_id,
                    &paths,
                )
                .unwrap(),
        )
        .unwrap();

        let error = executor
            .ensure_vm_domain_metadata(vm_id, &paths)
            .expect_err("managed VM artifacts must be regular files");

        assert!(
            error.to_string().contains("regular file"),
            "unexpected error: {error}"
        );
    }

    #[cfg(unix)]
    #[test]
    fn domain_metadata_rejects_symlinked_managed_artifacts() {
        let data_dir = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        let image_dir = data_dir.join("images");
        fs::create_dir_all(&image_dir).unwrap();
        let executor = LibvirtExecutor::new(data_dir, image_dir, "default".into(), "virbr0".into());
        let vm_id = VmId::new();
        let paths = executor.paths_for_vm(vm_id).unwrap();
        fs::create_dir_all(&paths.vm_dir).unwrap();
        let real_disk_path = paths.vm_dir.join("real-disk.qcow2");
        fs::write(&real_disk_path, "disk").unwrap();
        std::os::unix::fs::symlink(&real_disk_path, &paths.disk_path).unwrap();
        fs::write(&paths.seed_iso_path, "seed").unwrap();
        fs::write(
            &paths.domain_xml_path,
            executor
                .domain_xml(
                    &CreateVmRequest {
                        node_id: NodeId::new(),
                        vm_id: Some(vm_id),
                        ip_pool_id: None,
                        plan_id: None,
                        assigned_ip: None,
                        assigned_ip_prefix: None,
                        assigned_gateway_ip: None,
                        name: "demo".into(),
                        image: "debian.qcow2".into(),
                        ssh_public_key: None,
                        cpu_cores: 1,
                        memory_mb: 512,
                        disk_gb: 10,
                    },
                    vm_id,
                    &paths,
                )
                .unwrap(),
        )
        .unwrap();

        let error = executor
            .ensure_vm_domain_metadata(vm_id, &paths)
            .expect_err("managed VM artifacts must not be symlinks");

        assert!(
            error.to_string().contains("symlink"),
            "unexpected error: {error}"
        );
    }

    #[test]
    fn base_image_path_must_stay_under_image_dir_and_data_dir() {
        let data_dir = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        let image_dir = data_dir.join("images");
        fs::create_dir_all(&image_dir).unwrap();
        fs::write(image_dir.join("debian-12.qcow2"), "base image").unwrap();
        let executor = LibvirtExecutor::new(
            data_dir.clone(),
            image_dir.clone(),
            "default".into(),
            "virbr0".into(),
        );

        let path = executor.base_image_path("debian-12.qcow2").unwrap();
        assert_eq!(path, image_dir.join("debian-12.qcow2"));

        let outside_dir =
            std::env::temp_dir().join(format!("vps-agent-outside-images-{}", Uuid::new_v4()));
        fs::create_dir_all(&outside_dir).unwrap();
        fs::write(outside_dir.join("debian-12.qcow2"), "base image").unwrap();
        let executor =
            LibvirtExecutor::new(data_dir, outside_dir, "default".into(), "virbr0".into());

        let error = executor
            .base_image_path("debian-12.qcow2")
            .expect_err("base image outside data_dir should fail");
        assert!(
            error.to_string().contains("image_dir"),
            "unexpected error: {error}"
        );
    }

    #[test]
    fn base_image_path_must_be_a_regular_file() {
        let data_dir = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        let image_dir = data_dir.join("images");
        fs::create_dir_all(image_dir.join("debian-12.qcow2")).unwrap();
        let executor = LibvirtExecutor::new(data_dir, image_dir, "default".into(), "virbr0".into());

        let error = executor
            .base_image_path("debian-12.qcow2")
            .expect_err("base image directory should fail before qemu-img");
        assert!(
            error.to_string().contains("regular file"),
            "unexpected error: {error}"
        );
    }

    #[cfg(unix)]
    #[test]
    fn base_image_path_rejects_symlinked_image_dir() {
        let data_dir = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        let real_image_dir = data_dir.join("real-images");
        let image_dir = data_dir.join("images");
        fs::create_dir_all(&real_image_dir).unwrap();
        fs::write(real_image_dir.join("debian-12.qcow2"), "base image").unwrap();
        std::os::unix::fs::symlink(&real_image_dir, &image_dir).unwrap();
        let executor = LibvirtExecutor::new(data_dir, image_dir, "default".into(), "virbr0".into());

        let error = executor
            .base_image_path("debian-12.qcow2")
            .expect_err("image_dir symlink should fail before qemu-img");
        assert!(
            error.to_string().contains("symlink"),
            "unexpected error: {error}"
        );
    }

    #[cfg(unix)]
    #[test]
    fn base_image_path_rejects_symlinked_image_files() {
        let data_dir = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        let image_dir = data_dir.join("images");
        fs::create_dir_all(&image_dir).unwrap();
        let real_image_path = image_dir.join("real-debian-12.qcow2");
        fs::write(&real_image_path, "base image").unwrap();
        std::os::unix::fs::symlink(&real_image_path, image_dir.join("debian-12.qcow2")).unwrap();
        let executor = LibvirtExecutor::new(data_dir, image_dir, "default".into(), "virbr0".into());

        let error = executor
            .base_image_path("debian-12.qcow2")
            .expect_err("base image symlink should fail before qemu-img");
        assert!(
            error.to_string().contains("symlink"),
            "unexpected error: {error}"
        );
    }

    #[cfg(unix)]
    #[test]
    fn base_image_path_rejects_symlinked_data_dir() {
        let temp_root = std::env::temp_dir().join(format!("vps-agent-test-{}", Uuid::new_v4()));
        let real_data_dir = temp_root.join("real-data");
        let data_dir = temp_root.join("data-link");
        fs::create_dir_all(real_data_dir.join("images")).unwrap();
        fs::write(
            real_data_dir.join("images").join("debian-12.qcow2"),
            "base image",
        )
        .unwrap();
        std::os::unix::fs::symlink(&real_data_dir, &data_dir).unwrap();
        let image_dir = data_dir.join("images");
        let executor = LibvirtExecutor::new(data_dir, image_dir, "default".into(), "virbr0".into());

        let error = executor
            .base_image_path("debian-12.qcow2")
            .expect_err("data_dir symlink should fail before qemu-img");

        assert!(
            error.to_string().contains("data_dir") && error.to_string().contains("symlink"),
            "unexpected error: {error}"
        );
    }

    #[test]
    fn qemu_img_info_format_parser_requires_qcow2() {
        assert_eq!(
            super::qemu_img_info_format(r#"{"format":"qcow2"}"#).unwrap(),
            "qcow2"
        );

        let error = super::qemu_img_info_format(r#"{"format":"raw"}"#)
            .expect_err("raw base image should not pass qcow2 overlay validation");
        assert!(
            error.to_string().contains("qcow2"),
            "unexpected error: {error}"
        );
    }
}
