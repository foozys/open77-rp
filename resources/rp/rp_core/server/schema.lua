-- Схема БД ядра. Новые изменения — только новой версией в конце файла;
-- уже применённые миграции не редактировать.

Migrations.add(1, "audit_log", {
    [[
        CREATE TABLE IF NOT EXISTS rp_audit_log (
            id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
            created_at DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
            action     VARCHAR(64)     NOT NULL,
            actor      VARCHAR(64)     NULL,
            target     VARCHAR(64)     NULL,
            details    TEXT            NULL,
            PRIMARY KEY (id),
            KEY idx_audit_action (action, created_at),
            KEY idx_audit_actor (actor, created_at),
            KEY idx_audit_target (target, created_at)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ]],
})

-- license — постоянный ID аккаунта OPEN//77 (32 hex). user_id — ID установки
-- (identity GUID); нужен, чтобы отказать забаненному ещё на входе, где license
-- ещё неизвестен.
Migrations.add(2, "accounts_and_bans", {
    [[
        CREATE TABLE IF NOT EXISTS rp_accounts (
            license          VARCHAR(64)  NOT NULL,
            last_name        VARCHAR(64)  NOT NULL DEFAULT '',
            first_seen       DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
            last_seen        DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
            playtime_seconds INT UNSIGNED NOT NULL DEFAULT 0,
            steam            VARCHAR(32)  NULL,
            gog              VARCHAR(32)  NULL,
            PRIMARY KEY (license)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ]],
    [[
        CREATE TABLE IF NOT EXISTS rp_account_identities (
            license    VARCHAR(64) NOT NULL,
            user_id    VARCHAR(64) NOT NULL,
            first_seen DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            last_seen  DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (license, user_id),
            KEY idx_identity_user (user_id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ]],
    [[
        CREATE TABLE IF NOT EXISTS rp_bans (
            id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
            license    VARCHAR(64)     NOT NULL,
            reason     VARCHAR(255)    NOT NULL,
            created_at DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
            expires_at DATETIME        NULL,
            banned_by  VARCHAR(64)     NOT NULL,
            revoked_at DATETIME        NULL,
            revoked_by VARCHAR(64)     NULL,
            PRIMARY KEY (id),
            KEY idx_bans_license (license, revoked_at)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ]],
})

-- Допуск по анкете на уровне аккаунта.
Migrations.add(3, "account_whitelist", {
    [[
        ALTER TABLE rp_accounts
            ADD COLUMN IF NOT EXISTS whitelisted_at DATETIME NULL,
            ADD COLUMN IF NOT EXISTS whitelisted_by VARCHAR(64) NULL
    ]],
})
