/* =============================================================
   AppDb: создание БД, схем, базовых таблиц и таблиц под сайт
   ============================================================= */
USE master;
GO

IF DB_ID('AppDb') IS NULL
    CREATE DATABASE AppDb;
GO

ALTER DATABASE AppDb SET RECOVERY FULL;
ALTER DATABASE AppDb SET COMPATIBILITY_LEVEL = 160;
ALTER DATABASE AppDb SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE, INTERVAL_LENGTH_MINUTES = 15);
ALTER DATABASE AppDb SET QUERY_STORE (MAX_STORAGE_SIZE_MB = 1024, STALE_QUERY_THRESHOLD_DAYS = 30);
GO

USE AppDb;
GO

IF SCHEMA_ID('app')   IS NULL EXEC('CREATE SCHEMA app');
IF SCHEMA_ID('sec')   IS NULL EXEC('CREATE SCHEMA sec');
IF SCHEMA_ID('audit') IS NULL EXEC('CREATE SCHEMA audit');
GO

/* ---------- Базовые таблицы ---------- */
IF OBJECT_ID('sec.Users') IS NULL
CREATE TABLE sec.Users (
    UserId       INT IDENTITY PRIMARY KEY,
    Login        NVARCHAR(100) NOT NULL UNIQUE,
    PasswordHash VARBINARY(64) NOT NULL,
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

IF OBJECT_ID('app.Orders') IS NULL
CREATE TABLE app.Orders (
    OrderId   BIGINT IDENTITY PRIMARY KEY,
    UserId    INT NOT NULL REFERENCES sec.Users(UserId),
    Amount    DECIMAL(18,2) NOT NULL,
    Status    TINYINT NOT NULL DEFAULT 0,
    CreatedAt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    ValidFrom DATETIME2 GENERATED ALWAYS AS ROW START HIDDEN
              CONSTRAINT DF_Orders_ValidFrom DEFAULT SYSUTCDATETIME(),
    ValidTo   DATETIME2 GENERATED ALWAYS AS ROW END HIDDEN
              CONSTRAINT DF_Orders_ValidTo   DEFAULT '9999-12-31T23:59:59.9999999',
    PERIOD FOR SYSTEM_TIME (ValidFrom, ValidTo)
) WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = app.OrdersHistory));
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_Orders_UserId_CreatedAt')
    CREATE INDEX IX_Orders_UserId_CreatedAt
      ON app.Orders(UserId, CreatedAt)
      INCLUDE (Amount, Status);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='UX_Users_Email')
    CREATE UNIQUE INDEX UX_Users_Email
      ON sec.Users(Email) WHERE Email IS NOT NULL;
GO

/* ---------- Таблицы под сайт ---------- */
IF OBJECT_ID('app.Tutors') IS NULL
CREATE TABLE app.Tutors (
    TutorId  INT IDENTITY PRIMARY KEY,
    Name     NVARCHAR(100) NOT NULL,
    Spec     NVARCHAR(100) NULL,
    CreatedAt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

IF OBJECT_ID('app.Modules') IS NULL
CREATE TABLE app.Modules (
    ModuleId INT IDENTITY PRIMARY KEY,
    Title    NVARCHAR(100) NOT NULL,
    Hours    INT NULL,
    CreatedAt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

IF OBJECT_ID('app.Groups') IS NULL
CREATE TABLE app.Groups (
    GroupId      INT IDENTITY PRIMARY KEY,
    Name         NVARCHAR(100) NOT NULL,
    Level        TINYINT NOT NULL DEFAULT 1,
    DayOfWeek    NVARCHAR(20) NULL,
    TimeStart    TIME(0) NULL,
    TimeEnd      TIME(0) NULL,
    TutorId      INT NULL REFERENCES app.Tutors(TutorId),
    IsCamp       BIT NOT NULL DEFAULT 0,
    ModulesPlan  NVARCHAR(MAX) NULL,
    CreatedAt    DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

IF OBJECT_ID('app.GroupStudents') IS NULL
CREATE TABLE app.GroupStudents (
    GroupId   INT NOT NULL REFERENCES app.Groups(GroupId) ON DELETE CASCADE,
    StudentId INT NOT NULL REFERENCES sec.Users(UserId)   ON DELETE CASCADE,
    PRIMARY KEY (GroupId, StudentId)
);
GO

IF OBJECT_ID('app.Attendance') IS NULL
CREATE TABLE app.Attendance (
    GroupId   INT  NOT NULL REFERENCES app.Groups(GroupId) ON DELETE CASCADE,
    StudentId INT  NOT NULL REFERENCES sec.Users(UserId)   ON DELETE CASCADE,
    [Date]    DATE NOT NULL,
    Value     NVARCHAR(10) NULL,
    UpdatedAt DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
    PRIMARY KEY (GroupId, StudentId, [Date])
);
GO

/* ---------- Доп. поля ученика под сайт ---------- */
IF COL_LENGTH('sec.Users','BirthDate') IS NULL
    ALTER TABLE sec.Users ADD BirthDate DATE NULL;
IF COL_LENGTH('sec.Users','FullName') IS NULL
    ALTER TABLE sec.Users ADD FullName NVARCHAR(100) NULL;
IF COL_LENGTH('sec.Users','EnrollDate') IS NULL
    ALTER TABLE sec.Users ADD EnrollDate DATE NULL;
GO

/* ---------- Стартовый админ ---------- */
IF NOT EXISTS (SELECT 1 FROM sec.Users WHERE Login = N'admin')
    INSERT INTO sec.Users (Login, PasswordHash, PasswordSalt, Email, FullName, IsActive)
    VALUES (N'admin', 0x00, 0x00, N'admin@bel.com', N'Администратор', 1);
GO

/* ---------- Логин приложения ---------- */
USE master;
GO
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name='app_svc')
    CREATE LOGIN app_svc WITH PASSWORD = N'Ch@ngeMe_Str0ng!2025',
        CHECK_POLICY = ON, CHECK_EXPIRATION = OFF;
GO

USE AppDb;
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name='app_svc')
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

GRANT SELECT ON SCHEMA::sec TO app_write;
GRANT INSERT, UPDATE, DELETE ON sec.Users TO app_write;

DENY SELECT ON sec.Users(PasswordHash, PasswordSalt) TO app_read, app_write;
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_role_members
               WHERE role_principal_id = DATABASE_PRINCIPAL_ID('app_write')
                 AND member_principal_id = DATABASE_PRINCIPAL_ID('app_svc'))
    ALTER ROLE app_write ADD MEMBER app_svc;
GO

/* ---------- Аудит ---------- */
USE master;
GO
IF NOT EXISTS (SELECT 1 FROM sys.server_audits WHERE name='AppAudit')
BEGIN
    CREATE SERVER AUDIT AppAudit TO FILE (
        FILEPATH = 'D:\Audit\',
        MAXSIZE  = 100 MB,
        MAX_ROLLOVER_FILES = 20,
        RESERVE_DISK_SPACE = OFF
    ) WITH (QUEUE_DELAY = 1000, ON_FAILURE = CONTINUE);
END
GO
ALTER SERVER AUDIT AppAudit WITH (STATE = ON);
GO

USE AppDb;
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_audit_specifications WHERE name='AppDbAudit')
BEGIN
    CREATE DATABASE AUDIT SPECIFICATION AppDbAudit
      FOR SERVER AUDIT AppAudit
      ADD (SELECT, INSERT, UPDATE, DELETE ON SCHEMA::sec BY public),
      ADD (SELECT, INSERT, UPDATE, DELETE ON SCHEMA::app BY public)
      WITH (STATE = OFF);
END
GO
ALTER DATABASE AUDIT SPECIFICATION AppDbAudit WITH (STATE = ON);
GO

/* ---------- CDC ---------- */
IF (SELECT is_cdc_enabled FROM sys.databases WHERE name='AppDb') = 0
    EXEC sys.sp_cdc_enable_db;
GO
IF NOT EXISTS (SELECT 1 FROM cdc.change_tables WHERE source_object_id=OBJECT_ID('app.Orders'))
    EXEC sys.sp_cdc_enable_table
        @source_schema='app', @source_name='Orders',
        @role_name=NULL, @supports_net_changes=1;
GO

/* ---------- Первичный бэкап ---------- */
IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name='AppDb' AND state_desc='ONLINE')
    PRINT 'БД не в сети — проверьте состояние';
GO
BEGIN TRY
    BACKUP DATABASE AppDb
        TO DISK = 'D:\Backup\AppDb_INIT.bak'
        WITH INIT, COMPRESSION, CHECKSUM, STATS = 10;
END TRY
BEGIN CATCH
    PRINT 'Не удалось сделать бэкап (проверьте папку D:\Backup): ' + ERROR_MESSAGE();
END CATCH
GO

DBCC CHECKDB (AppDb) WITH NO_INFOMSGS;
GO

PRINT '=== AppDb: развёртывание завершено ===';
GO