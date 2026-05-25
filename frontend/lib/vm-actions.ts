import type { VmDto, VmStatus } from "./api";

export type VmAction = "start-vm" | "stop-vm" | "reboot-vm" | "reinstall-vm" | "delete-vm";

type VmActionTarget = Pick<VmDto, "id" | "name">;
type VmActionAvailabilityTarget = { status: VmStatus; hasActiveTask?: boolean };

export function availableVmActions(vm: VmActionAvailabilityTarget): VmAction[] {
  if (vm.hasActiveTask) {
    return [];
  }

  switch (vm.status) {
    case "running":
      return ["stop-vm", "reboot-vm", "reinstall-vm", "delete-vm"];
    case "stopped":
    case "error":
      return ["start-vm", "reinstall-vm", "delete-vm"];
    case "provisioning":
    case "deleting":
    case "deleted":
      return [];
  }
}

export function vmActionConfirmationMessage(action: VmAction, vm: VmActionTarget) {
  switch (action) {
    case "start-vm":
      return `Start VM ${vm.name}?`;
    case "stop-vm":
      return `Stop VM ${vm.name}? This can interrupt running workloads.`;
    case "reboot-vm":
      return `Reboot VM ${vm.name}? This can interrupt running workloads.`;
    case "reinstall-vm":
      return `Reinstall VM ${vm.name}? This replaces the guest disk and can destroy data inside ${vm.id}.`;
    case "delete-vm":
      return `Delete VM ${vm.name}? This schedules libvirt domain and managed disk removal for ${vm.id}.`;
  }
}
