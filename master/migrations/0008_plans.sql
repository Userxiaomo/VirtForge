CREATE TABLE plans (
    id UUID PRIMARY KEY,
    name TEXT NOT NULL UNIQUE CHECK (length(name) BETWEEN 1 AND 80),
    slug TEXT NOT NULL UNIQUE CHECK (length(slug) BETWEEN 1 AND 80),
    cpu_cores SMALLINT NOT NULL CHECK (cpu_cores BETWEEN 1 AND 32),
    memory_mb INTEGER NOT NULL CHECK (memory_mb BETWEEN 128 AND 262144),
    disk_gb INTEGER NOT NULL CHECK (disk_gb BETWEEN 1 AND 4096),
    enabled BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX plans_enabled_idx ON plans(enabled);

ALTER TABLE vms
    ADD COLUMN plan_id UUID REFERENCES plans(id);
