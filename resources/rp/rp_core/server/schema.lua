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
