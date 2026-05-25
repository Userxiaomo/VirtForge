CREATE TABLE vms (
    id UUID PRIMARY KEY,
    node_id UUID NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
    name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 64),
    image TEXT NOT NULL CHECK (length(image) BETWEEN 1 AND 80),
    cpu_cores SMALLINT NOT NULL CHECK (cpu_cores BETWEEN 1 AND 32),
    memory_mb INTEGER NOT NULL CHECK (memory_mb BETWEEN 128 AND 262144),
    disk_gb INTEGER NOT NULL CHECK (disk_gb BETWEEN 1 AND 4096),
    status TEXT NOT NULL DEFAULT 'provisioning',
    last_task_id UUID REFERENCES tasks(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at TIMESTAMPTZ
);

CREATE INDEX vms_node_status_idx ON vms(node_id, status);
