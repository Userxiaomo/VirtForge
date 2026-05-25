ALTER TABLE nodes
    ADD COLUMN cpu_total BIGINT NOT NULL DEFAULT 0 CHECK (cpu_total >= 0),
    ADD COLUMN cpu_used BIGINT NOT NULL DEFAULT 0 CHECK (cpu_used >= 0),
    ADD COLUMN memory_total BIGINT NOT NULL DEFAULT 0 CHECK (memory_total >= 0),
    ADD COLUMN memory_used BIGINT NOT NULL DEFAULT 0 CHECK (memory_used >= 0),
    ADD COLUMN disk_total BIGINT NOT NULL DEFAULT 0 CHECK (disk_total >= 0),
    ADD COLUMN disk_used BIGINT NOT NULL DEFAULT 0 CHECK (disk_used >= 0),
    ADD COLUMN vm_count INTEGER NOT NULL DEFAULT 0 CHECK (vm_count >= 0),
    ADD CONSTRAINT nodes_memory_used_within_total CHECK (memory_used <= memory_total),
    ADD CONSTRAINT nodes_disk_used_within_total CHECK (disk_used <= disk_total);
