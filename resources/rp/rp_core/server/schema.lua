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

-- Персонажи. Ключ внешности в open77_appearance — "rp-<id>". slot = NULL у
-- удалённых, чтобы слот освобождался. look — снимок тела и одежды для
-- манекена на экране выбора. next_character_id — кого загрузить при следующем
-- входе (создание нового персонажа требует перезахода).
Migrations.add(4, "characters", {
    [[
        CREATE TABLE IF NOT EXISTS rp_characters (
            id             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
            license        VARCHAR(64)     NOT NULL,
            slot           TINYINT UNSIGNED NULL,
            status         ENUM('creating', 'active', 'deleted') NOT NULL DEFAULT 'creating',
            first_name     VARCHAR(32)     NOT NULL DEFAULT '',
            last_name      VARCHAR(32)     NOT NULL DEFAULT '',
            birth_date     DATE            NULL,
            look           MEDIUMTEXT      NULL,
            pos_x          DOUBLE          NULL,
            pos_y          DOUBLE          NULL,
            pos_z          DOUBLE          NULL,
            heading        DOUBLE          NULL,
            created_at     DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
            last_played_at DATETIME        NULL,
            deleted_at     DATETIME        NULL,
            PRIMARY KEY (id),
            UNIQUE KEY uq_characters_slot (license, slot),
            KEY idx_characters_license (license, status)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ]],
    [[
        ALTER TABLE rp_accounts
            ADD COLUMN IF NOT EXISTS next_character_id BIGINT UNSIGNED NULL
    ]],
})

-- Админ-роль аккаунта (id из RpConfig.staffRoles). Нет строки — не администрация.
Migrations.add(5, "staff_roles", {
    [[
        CREATE TABLE IF NOT EXISTS rp_staff (
            license    VARCHAR(64) NOT NULL,
            role       VARCHAR(32) NOT NULL,
            granted_by VARCHAR(64) NOT NULL,
            granted_at DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (license)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ]],
})

-- Здоровье персонажа при выходе (доля от максимума, 0..1). NULL — полное.
Migrations.add(6, "character_health", {
    [[
        ALTER TABLE rp_characters
            ADD COLUMN IF NOT EXISTS health DOUBLE NULL
    ]],
})

-- Расширенная анкета и предыстория. У старых активных персонажей поля остаются
-- NULL: миграция не заставляет их проходить создание повторно.
Migrations.add(7, "character_profile_and_background", {
    [[
        ALTER TABLE rp_characters
            ADD COLUMN IF NOT EXISTS race VARCHAR(32) NULL AFTER birth_date,
            ADD COLUMN IF NOT EXISTS gender VARCHAR(16) NULL AFTER race,
            ADD COLUMN IF NOT EXISTS origin_country VARCHAR(64) NULL AFTER gender,
            ADD COLUMN IF NOT EXISTS background VARCHAR(16) NULL AFTER origin_country
    ]],
})
