/* ============================================================================
   deploy_appdb.sql — развёртывание базы AppDb
   Целевая версия: SQL Server 2022 (COMPATIBILITY_LEVEL 160)
   ----------------------------------------------------------------------------
   ИСПРАВЛЕНО относительно исходной версии скрипта:
   1. Проверки существования индексов шли только по имени во всей БД —
      индекс с таким именем в ДРУГОЙ таблице блокировал создание. Добавлен
      фильтр по OBJECT_ID.
   2. Настройки Query Store разнесены на два ALTER DATABASE — объединены в один.
   3. Роли app_read не давалось вообще ничего на схему sec — приложение не могло
      читать даже не секретные данные пользователей. Добавлен грант SELECT
      по конкретным НЕ секретным колонкам sec.Users.
   4. Добавлена серверная спецификация аудита неудачных входов
      (FAILED_LOGIN_GROUP) — раньше аудировались только DML по схемам.
   5. Включение CDC (база + таблица) обёрнуто в TRY/CATCH: если Agent
      остановлен, развёртывание не падает, а печатает понятное предупреждение.
   6. Первичный бэкап и DBCC CHECKDB обёрнуты в TRY/CATCH с подсказкой
      (например, «создайте папку D:\Backup»).
   7. Проверка CDC на таблице шла по cdc.change_tables (упадёт, если CDC
      на уровне БД не включился) — заменена на безопасный просмотр sys.tables.
   8. Добавлены тестовые данные (роли, пользователи, заказы) и примеры
      запросов к temporal-истории и CDC.

   ТРЕБОВАНИЯ К СРЕДЕ:
   - права sysadmin;
   - SQL Server Agent запущен (обязателен для CDC; задания — см.
     deploy_agent_jobs.sql);
   - существуют папки D:\Backup и D:\Audit (создайте вручную при необходимости);
   - пароль логина app_svc ниже — демонстрационный, ЗАМЕНИТЕ перед реальным
     использованием и не храните в репозитории.

   Порядок запуска: сначала этот скрипт, затем deploy_agent_jobs.sql.
   Скрипт полностью идемпотентен — его можно запускать повторно.
   ============================================================================ */

USE master;
GO

IF DB_ID('AppDb') IS NULL
    CREATE DATABASE AppDb;
GO

ALTER DATABASE AppDb SET RECOVERY FULL;
ALTER DATABASE AppDb SET COMPATIBILITY_LEVEL = 160;
ALTER DATABASE AppDb SET QUERY_STORE = ON (
    OPERATION_MODE            = READ_WRITE,
    INTERVAL_LENGTH_MINUTES   = 15,
    MAX_STORAGE_SIZE_MB       = 1024,
    STALE_QUERY_THRESHOLD_DAYS = 30
);
GO

USE AppDb;
GO

IF SCHEMA_ID('app')   IS NULL EXEC('CREATE SCHEMA app');
IF SCHEMA_ID('sec')   IS NULL EXEC('CREATE SCHEMA sec');
IF SCHEMA_ID('audit') IS NULL EXEC('CREATE SCHEMA audit');
GO

/* ============ 1. СХЕМА БЕЗОПАСНОСТИ ============ */

IF OBJECT_ID('sec.Users') IS NULL
CREATE TABLE sec.Users (
    UserId       INT IDENTITY PRIMARY KEY,
    Login        NVARCHAR(100) NOT NULL UNIQUE,
    PasswordHash VARBINARY(64) NOT NULL,          -- хеш пароля (считает приложение)
    PasswordSalt VARBINARY(32) NOT NULL,
    Email        NVARCHAR(255) NULL,
    IsActive     BIT NOT NULL DEFAULT 1,
    CreatedAt    DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    RowVersion   ROWVERSION
);
GO

IF OBJECT_ID('sec.Roles') IS NULL
CREATE TABLE sec.Roles (
    RoleId INT IDENTITY PRIMARY KEY,
    Name   NVARCHAR(50) NOT NULL UNIQUE
);
GO

IF OBJECT_ID('sec.UserRoles') IS NULL
CREATE TABLE sec.UserRoles (
    UserId INT NOT NULL REFERENCES sec.Users(UserId),
    RoleId INT NOT NULL REFERENCES sec.Roles(RoleId),
    PRIMARY KEY (UserId, RoleId)
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID('sec.UserRoles')
                 AND name = 'IX_UserRoles_RoleId')
    CREATE INDEX IX_UserRoles_RoleId ON sec.UserRoles(RoleId);
GO

/* ============ 2. ЗАКАЗЫ: temporal-версионирование + CDC ============ */

IF OBJECT_ID('app.Orders') IS NULL
CREATE TABLE app.Orders (
    OrderId   BIGINT IDENTITY PRIMARY KEY,
    UserId    INT NOT NULL REFERENCES sec.Users(UserId),
    Amount    DECIMAL(18,2) NOT NULL,
    Status    TINYINT NOT NULL DEFAULT 0 CHECK (Status BETWEEN 0 AND 4),
               -- 0=новый, 1=оплачен, 2=отправлен, 3=закрыт, 4=отменён
    CreatedAt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    ValidFrom DATETIME2 GENERATED ALWAYS AS ROW START HIDDEN NOT NULL
              CONSTRAINT DF_Orders_ValidFrom DEFAULT SYSUTCDATETIME(),
    ValidTo   DATETIME2 GENERATED ALWAYS AS ROW END HIDDEN NOT NULL
              CONSTRAINT DF_Orders_ValidTo   DEFAULT '9999-12-31T23:59:59.9999999',
    PERIOD FOR SYSTEM_TIME (ValidFrom, ValidTo)
) WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = app.OrdersHistory));
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID('app.Orders')
                 AND name = 'IX_Orders_UserId_CreatedAt')
    CREATE INDEX IX_Orders_UserId_CreatedAt
      ON app.Orders(UserId, CreatedAt)
      INCLUDE (Amount, Status);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID('sec.Users')
                 AND name = 'UX_Users_Email')
    CREATE UNIQUE INDEX UX_Users_Email
      ON sec.Users(Email) WHERE Email IS NOT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.extended_properties
               WHERE name = 'MS_Description' AND major_id = OBJECT_ID('app.Orders'))
    EXEC sys.sp_addextendedproperty
        @name = N'MS_Description',
        @value = N'Заказы: агрегируют корзину и оплату; версионируются через temporal, изменения отдаются через CDC',
        @level0type = N'SCHEMA', @level0name = N'app',
        @level1type = N'TABLE',  @level1name = N'Orders';
GO

/* ============ 3. ЛОГИН И РОЛИ БД ============ */

USE master;
GO
/* ВНИМАНИЕ: демонстрационный пароль. Перед боевым использованием замените
   и храните в секретах, а не в скриптах. */
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'app_svc')
    CREATE LOGIN app_svc WITH PASSWORD = N'Ch@ngeMe_Str0ng!2025',
        CHECK_POLICY = ON, CHECK_EXPIRATION = OFF;
GO

USE AppDb;
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'app_svc')
    CREATE USER app_svc FOR LOGIN app_svc;
GO

IF DATABASE_PRINCIPAL_ID('app_read')  IS NULL CREATE ROLE app_read;
IF DATABASE_PRINCIPAL_ID('app_write') IS NULL CREATE ROLE app_write;
IF DATABASE_PRINCIPAL_ID('app_admin') IS NULL CREATE ROLE app_admin;
GO

GRANT SELECT ON SCHEMA::app TO app_read;
GRANT SELECT ON SCHEMA::app TO app_write;
GRANT INSERT, UPDATE, DELETE ON SCHEMA::app TO app_write;
GRANT EXECUTE ON SCHEMA::app TO app_write;
GRANT CONTROL ON SCHEMA::app TO app_admin;

/* Исправление: app_read может читать НЕ секретные колонки пользователей
   (раньше роль не имела на схему sec никаких прав) */
GRANT SELECT ON sec.Users (UserId, Login, Email, IsActive, CreatedAt) TO app_read;

DENY SELECT ON sec.Users(PasswordHash, PasswordSalt) TO app_read, app_write;
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_role_members
               WHERE role_principal_id = DATABASE_PRINCIPAL_ID('app_write')
                 AND member_principal_id = DATABASE_PRINCIPAL_ID('app_svc'))
    ALTER ROLE app_write ADD MEMBER app_svc;
GO

/* ============ 4. АУДИТ ============ */

USE master;
GO
IF NOT EXISTS (SELECT 1 FROM sys.server_audits WHERE name = 'AppAudit')
BEGIN
    BEGIN TRY
        CREATE SERVER AUDIT AppAudit TO FILE (
            FILEPATH = 'D:\Audit\',            -- папка должна существовать
            MAXSIZE  = 100 MB,
            MAX_ROLLOVER_FILES = 20,
            RESERVE_DISK_SPACE = OFF
        ) WITH (QUEUE_DELAY = 1000, ON_FAILURE = CONTINUE);
    END TRY
    BEGIN CATCH
        PRINT N'ПРЕДУПРЕЖДЕНИЕ: серверный аудит не создан: ' + ERROR_MESSAGE()
            + N' — проверьте, что папка D:\Audit существует.';
    END CATCH
END
GO
BEGIN TRY
    ALTER SERVER AUDIT AppAudit WITH (STATE = ON);
END TRY
BEGIN CATCH
    PRINT N'ПРЕДУПРЕЖДЕНИЕ: аудит AppAudit не включён: ' + ERROR_MESSAGE();
END CATCH
GO

/* Доработка: неудачные входы на сервере (раньше не аудировались) */
IF NOT EXISTS (SELECT 1 FROM sys.server_audit_specs WHERE name = N'AppDbFailedLogins')
    CREATE SERVER AUDIT SPECIFICATION AppDbFailedLogins
      FOR SERVER AUDIT AppAudit
      ADD (FAILED_LOGIN_GROUP)
      WITH (STATE = ON);
GO

USE AppDb;
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_audit_specifications WHERE name = 'AppDbAudit')
BEGIN
    CREATE DATABASE AUDIT SPECIFICATION AppDbAudit
      FOR SERVER AUDIT AppAudit
      ADD (SELECT, INSERT, UPDATE, DELETE ON SCHEMA::sec BY [public]),
      ADD (SELECT, INSERT, UPDATE, DELETE ON SCHEMA::app BY [public])
      WITH (STATE = OFF);
END
GO
BEGIN TRY
    ALTER DATABASE AUDIT SPECIFICATION AppDbAudit WITH (STATE = ON);
END TRY
BEGIN CATCH
    PRINT N'ПРЕДУПРЕЖДЕНИЕ: спецификация аудита AppDbAudit не включена: ' + ERROR_MESSAGE();
END CATCH
GO

/* ============ 5. CDC ============
   CDC на системно-версионируемой таблице поддерживается официально
   (только по текущей таблице, история в CDC не попадает). */

USE AppDb;
GO
IF (SELECT is_cdc_enabled FROM sys.databases WHERE name = 'AppDb') = 0
BEGIN
    BEGIN TRY
        EXEC sys.sp_cdc_enable_db;
        PRINT N'CDC включён на уровне базы.';
    END TRY
    BEGIN CATCH
        PRINT N'ПРЕДУПРЕЖДЕНИЕ: CDC на уровне базы не включён: ' + ERROR_MESSAGE()
            + N' — включите SQL Server Agent и выполните: EXEC sys.sp_cdc_enable_db;';
    END CATCH
END
GO

/* Проверяем существование capture-таблицы через sys.tables:
   обращение к cdc.change_tables упало бы, если CDC на БД включить не удалось */
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = 'AppDb' AND is_cdc_enabled = 1)
   AND NOT EXISTS (SELECT 1
                   FROM sys.tables t
                   JOIN sys.schemas s ON s.schema_id = t.schema_id
                   WHERE s.name = 'cdc' AND t.name = 'app_Orders_CT')
BEGIN
    BEGIN TRY
        EXEC sys.sp_cdc_enable_table
             @source_schema = 'app',
             @source_name = 'Orders',
             @role_name = NULL,
             @supports_net_changes = 1;   -- capture instance: app_Orders
        PRINT N'CDC включён на таблице app.Orders (capture instance: app_Orders).';
    END TRY
    BEGIN CATCH
        PRINT N'ПРЕДУПРЕЖДЕНИЕ: CDC на app.Orders не включён: ' + ERROR_MESSAGE();
    END CATCH
END
GO

/* ============ 6. ТЕСТОВЫЕ ДАННЫЕ ============ */

USE AppDb;
GO

IF NOT EXISTS (SELECT 1 FROM sec.Roles WHERE Name = N'admin')
    INSERT INTO sec.Roles (Name) VALUES (N'admin'), (N'operator'), (N'reader');
GO

/* Демо-пользователи. Хеш = SHA2_256 от строки 'Login|Demo#2025', соль —
   SHA2_256 от 'salt-<Login>'. ВНИМАНИЕ: это только для демо и проверки
   запросов. В реальном приложении пароли хеширует само приложение
   (PBKDF2/bcrypt/argon2), база хранит готовый хеш. */
IF NOT EXISTS (SELECT 1 FROM sec.Users WHERE Login = N'demo_admin')
BEGIN
    INSERT INTO sec.Users (Login, PasswordHash, PasswordSalt, Email, IsActive)
    VALUES
      (N'demo_admin',
       HASHBYTES('SHA2_256', N'demo_admin|Demo#2025'),
       HASHBYTES('SHA2_256', N'salt-demo_admin'),
       N'admin@bel.com', 1),
      (N'demo_operator',
       HASHBYTES('SHA2_256', N'demo_operator|Demo#2025'),
       HASHBYTES('SHA2_256', N'salt-demo_operator'),
       N'operator@bel.com', 1),
      (N'demo_reader',
       HASHBYTES('SHA2_256', N'demo_reader|Demo#2025'),
       HASHBYTES('SHA2_256', N'salt-demo_reader'),
       N'reader@bel.com', 1);
END
GO

/* Связки пользователь-роль (без дублей при повторном запуске) */
INSERT INTO sec.UserRoles (UserId, RoleId)
SELECT u.UserId, r.RoleId
FROM sec.Users u
JOIN sec.Roles r
  ON (u.Login = N'demo_admin'    AND r.Name = N'admin')
  OR (u.Login = N'demo_operator' AND r.Name = N'operator')
  OR (u.Login = N'demo_reader'   AND r.Name = N'reader')
WHERE NOT EXISTS (SELECT 1 FROM sec.UserRoles ur
                  WHERE ur.UserId = u.UserId AND ur.RoleId = r.RoleId);
GO

/* Заказы: 6 строк + пара UPDATE, чтобы в temporal-истории и CDC было что смотреть */
IF NOT EXISTS (SELECT 1 FROM app.Orders o
               JOIN sec.Users u ON u.UserId = o.UserId
               WHERE u.Login = N'demo_operator')
BEGIN
    DECLARE @admin INT = (SELECT UserId FROM sec.Users WHERE Login = N'demo_admin');
    DECLARE @oper  INT = (SELECT UserId FROM sec.Users WHERE Login = N'demo_operator');

    INSERT INTO app.Orders (UserId, Amount, Status) VALUES
        (@admin, 1250.00, 1),
        (@admin,  480.50, 0),
        (@oper,  2399.00, 1),
        (@oper,    75.00, 0),
        (@oper,   610.00, 3),
        (@oper,   320.00, 0);

    UPDATE app.Orders SET Status = 1
     WHERE UserId = @oper AND Status = 0 AND Amount = 75.00;
    UPDATE app.Orders SET Amount = 335.00
     WHERE UserId = @oper AND Status = 0 AND Amount = 320.00;
END
GO

/* ============ 7. ПЕРВИЧНЫЙ БЭКАП И ПРОВЕРКА ЦЕЛОСТНОСТИ ============ */

USE master;
GO
BEGIN TRY
    BACKUP DATABASE AppDb
        TO DISK = 'D:\Backup\AppDb_INIT.bak'
        WITH INIT, COMPRESSION, CHECKSUM, STATS = 10;
END TRY
BEGIN CATCH
    PRINT N'ПРЕДУПРЕЖДЕНИЕ: первичный бэкап не выполнен: ' + ERROR_MESSAGE()
        + N'. Создайте папку D:\Backup и повторите: '
        + N'BACKUP DATABASE AppDb TO DISK = ''D:\Backup\AppDb_INIT.bak'' '
        + N'WITH INIT, COMPRESSION, CHECKSUM;';
END CATCH
GO

BEGIN TRY
    DBCC CHECKDB (AppDb) WITH NO_INFOMSGS;
    PRINT N'DBCC CHECKDB: ошибок целостности нет.';
END TRY
BEGIN CATCH
    PRINT N'ПРЕДУПРЕЖДЕНИЕ: DBCC CHECKDB сообщил об ошибках: ' + ERROR_MESSAGE();
END CATCH
GO

/* ============ 8. ПРИМЕРЫ ЗАПРОСОВ К ИСТОРИИ ИЗМЕНЕНИЙ ============
   Выполнять в SSMS после развёртывания. CDC-данные появляются
   асинхронно: нужен работающий SQL Server Agent и ~1 минута после DML.

   1) Вся история заказа 1 (temporal):
      SELECT * FROM app.Orders
        FOR SYSTEM_TIME ALL WHERE OrderId = 1 ORDER BY ValidFrom;

   2) Состояние на указанный момент времени:
      DECLARE @t datetime2(7) = '2026-11-27 12:00:00';
      SELECT * FROM app.Orders FOR SYSTEM_TIME AS OF @t;

   3) Все версии строк, действовавшие в интервале:
      SELECT * FROM app.Orders
        FOR SYSTEM_TIME BETWEEN '2026-11-01' AND '2026-11-30';

   4) CDC: все изменения с момента включения (capture instance app_Orders):
      DECLARE @from_lsn binary(10) = sys.fn_cdc_get_min_lsn(N'app_Orders');
      DECLARE @to_lsn   binary(10) = sys.fn_cdc_get_max_lsn();
      SELECT * FROM cdc.fn_cdc_get_all_changes_app_Orders(@from_lsn, @to_lsn, 'all');

   5) CDC: нетто-изменения (итог по каждой строке):
      DECLARE @from_lsn binary(10) = sys.fn_cdc_get_min_lsn(N'app_Orders');
      DECLARE @to_lsn   binary(10) = sys.fn_cdc_get_max_lsn();
      SELECT * FROM cdc.fn_cdc_get_net_changes_app_Orders(@from_lsn, @to_lsn, 'all');
   ============================================================================ */

USE AppDb;
GO
SELECT (SELECT COUNT(*) FROM sec.Users)        AS Пользователи,
       (SELECT COUNT(*) FROM sec.Roles)         AS Роли,
       (SELECT COUNT(*) FROM sec.UserRoles)     AS Связки_Ролей,
       (SELECT COUNT(*) FROM app.Orders)        AS Заказы,
       (SELECT COUNT(*) FROM app.OrdersHistory) AS Строк_Истории;
GO

PRINT '=== AppDb: развёртывание завершено ===';
GO
