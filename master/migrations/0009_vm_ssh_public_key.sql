ALTER TABLE vms
    ADD COLUMN ssh_public_key TEXT CHECK (
        ssh_public_key IS NULL
        OR (
            length(ssh_public_key) BETWEEN 1 AND 1024
            AND position(chr(10) in ssh_public_key) = 0
            AND position(chr(13) in ssh_public_key) = 0
        )
    );
