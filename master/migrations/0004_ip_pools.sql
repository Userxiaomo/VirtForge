CREATE TABLE ip_pools (
    id UUID PRIMARY KEY,
    name TEXT NOT NULL UNIQUE CHECK (length(name) BETWEEN 1 AND 80),
    cidr TEXT NOT NULL CHECK (length(cidr) BETWEEN 9 AND 18),
    gateway_ip TEXT NOT NULL CHECK (length(gateway_ip) BETWEEN 7 AND 15),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE ip_allocations (
    id UUID PRIMARY KEY,
    ip_pool_id UUID NOT NULL REFERENCES ip_pools(id) ON DELETE CASCADE,
    vm_id UUID NOT NULL,
    ip_address TEXT NOT NULL CHECK (length(ip_address) BETWEEN 7 AND 15),
    reserved_by_task_id UUID REFERENCES tasks(id) ON DELETE SET NULL,
    reserved_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    released_at TIMESTAMPTZ
);

CREATE UNIQUE INDEX ip_allocations_active_pool_ip_idx
    ON ip_allocations(ip_pool_id, ip_address)
    WHERE released_at IS NULL;

CREATE UNIQUE INDEX ip_allocations_active_vm_idx
    ON ip_allocations(vm_id)
    WHERE released_at IS NULL;

ALTER TABLE vms
    ADD COLUMN ip_pool_id UUID REFERENCES ip_pools(id) ON DELETE SET NULL,
    ADD COLUMN assigned_ip TEXT CHECK (assigned_ip IS NULL OR length(assigned_ip) BETWEEN 7 AND 15);

CREATE INDEX vms_ip_pool_idx ON vms(ip_pool_id);
