ALTER TABLE nodes
    ADD COLUMN libvirt_status TEXT NOT NULL DEFAULT 'not_checked'
        CHECK (libvirt_status IN ('not_checked', 'available', 'unavailable')),
    ADD COLUMN host_checks JSONB NOT NULL DEFAULT '[]'::jsonb
        CHECK (jsonb_typeof(host_checks) = 'array');
