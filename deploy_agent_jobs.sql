/* ============================================================================
   deploy_agent_jobs.sql — задания SQL Server Agent для обслуживания AppDb
   Целевая версия: SQL Server 2022
   ----------------------------------------------------------------------------
   ИСПРАВЛЕНО относительно исходной версии скрипта:
   1. ГЛАВНАЯ ОШИБКА: исходные шаги бэкапов использовали несуществующий
      токен с именем STRTDTIME — в SQL Server Agent есть только STRTDT (дата запуска, yyyyMMdd) и
      STRTTM (время запуска, HHmmss). Оба шага бэкапа падали бы при
      каждом запуске с ошибкой токена. Заменено на
      AppDb_full_$(ESCAPE_SQUOTE(STRTDT))_$(ESCAPE_SQUOTE(STRTTM)).bak.
   2. Идемпотентность: sp_add_jobstep / sp_add_schedule / sp_attach_schedule /
      sp_add_jobserver вызывались без проверок — повторный запуск скрипта
      падал. Теперь задания пересоздаются (delete + create), расписания
      и оператор создаются только при отсутствии, привязки проверяются.
   3. Шагам заданий явно задан @database_name (раньше полагались на
      умолчание).
   4. Убран WITH INIT из полного бэкапа: имя файла уникально за счёт
      токена даты/времени, перезапывать нечего (INIT был бессмысленным).
   5. Добавлен оператор DBA_Operator и уведомления по e-mail при сбое
      заданий и срабатывании всех алертов (раньше алерты просто писались
      в журнал, никого не извещая).

   ДОРАБОТАНО (по согласованию):
   6. Новое задание AppDb_BackupCleanup: удаление файлов бэкапов старше
      14 дней из D:\Backup + sp_delete_backuphistory (история бэкапов в
      msdb росла бы бесконечно).
   7. Вместо одного алерта Sev_17_plus, который ловил ТОЛЬКО severity 17
      (имя вводило в заблуждение), создан полный набор Sev_17..Sev_25;
      алерты повреждения разделены на Corruption_823/824/825; каждому
      алерту привязано уведомление оператору.

   ТРЕБОВАНИЯ К СРЕДЕ:
   - папка D:\Backup существует (создайте вручную при необходимости);
   - для e-mail-уведомлений настроен Database Mail и выбран в SQL Server
     Agent -> Properties -> Alert System (иначе письма не уйдут —
     задания и алерты при этом работают);
   - PowerShell-подсистема разрешена (шаг удаления старых файлов). Если
     в вашей среде она запрещена — удалите шаг DeleteOldFiles.

   Запускать ПОСЛЕ deploy_appdb.sql. Скрипт можно повторять — он приведёт
   всё к описанному состоянию. Пересоздание заданий очищает их историю
   запусков (это единственный побочный эффект).
   ============================================================================ */

USE msdb;
GO

/* ============ 0. ОПЕРАТОР ДЛЯ УВЕДОМЛЕНИЙ ============ */
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysoperators WHERE name = N'DBA_Operator')
    EXEC msdb.dbo.sp_add_operator
         @name          = N'DBA_Operator',
         @enabled       = 1,
         @email_address = N'dba@company.local';   -- ЗАМЕНИТЕ на реальный адрес
PRINT N'Оператор DBA_Operator: готов (создан сейчас или существовал ранее).';
GO

/* ============ 1. ПОЛНЫЙ БЭКАП: ежедневно в 02:00 ============ */
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'AppDb_FullBackup')
    EXEC msdb.dbo.sp_delete_job @job_name = N'AppDb_FullBackup';  -- пересоздаём с исправленным шагом
EXEC msdb.dbo.sp_add_job
     @job_name                   = N'AppDb_FullBackup',
     @enabled                    = 1,
     @description                = N'Полный бэкап AppDb ежедневно в 02:00',
     @notify_level_email         = 2,                -- уведомлять при сбое
     @notify_email_operator_name = N'DBA_Operator';
EXEC msdb.dbo.sp_add_jobstep
     @job_name      = N'AppDb_FullBackup',
     @step_name     = N'Backup',
     @subsystem     = N'TSQL',
     @database_name = N'master',
     @command       = N'BACKUP DATABASE AppDb
                          TO DISK = ''D:\Backup\AppDb_full_$(ESCAPE_SQUOTE(STRTDT))_$(ESCAPE_SQUOTE(STRTTM)).bak''
                          WITH COMPRESSION, CHECKSUM;';
EXEC msdb.dbo.sp_add_jobserver
     @job_name   = N'AppDb_FullBackup',
     @server_name = N'(local)';

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.syschedules WHERE name = N'Daily_0200')
    EXEC msdb.dbo.sp_add_schedule
         @schedule_name      = N'Daily_0200',
         @freq_type          = 4,          -- ежедневно
         @freq_interval      = 1,
         @active_start_time  = 20000;       -- 02:00:00 (формат HHMMSS)
IF NOT EXISTS (SELECT 1
                 FROM msdb.dbo.sysjobschedules js
                 JOIN msdb.dbo.sysjobs      j ON j.job_id      = js.job_id
                 JOIN msdb.dbo.syschedules  s ON s.schedule_id = js.schedule_id
                WHERE j.name = N'AppDb_FullBackup'
                  AND s.name = N'Daily_0200')
    EXEC msdb.dbo.sp_attach_schedule
         @job_name       = N'AppDb_FullBackup',
         @schedule_name  = N'Daily_0200';
PRINT N'Задание AppDb_FullBackup развёрнуто.';
GO

/* ============ 2. БЭКАП ЖУРНАЛА ТРАНЗАКЦИЙ: каждые 15 минут ============ */
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'AppDb_LogBackup')
    EXEC msdb.dbo.sp_delete_job @job_name = N'AppDb_LogBackup';
EXEC msdb.dbo.sp_add_job
     @job_name                   = N'AppDb_LogBackup',
     @enabled                    = 1,
     @description                = N'Бэкап журнала транзакций AppDb каждые 15 минут',
     @notify_level_email         = 2,
     @notify_email_operator_name = N'DBA_Operator';
EXEC msdb.dbo.sp_add_jobstep
     @job_name      = N'AppDb_LogBackup',
     @step_name     = N'LogBackup',
     @subsystem     = N'TSQL',
     @database_name = N'master',
     @command       = N'BACKUP LOG AppDb
                          TO DISK = ''D:\Backup\AppDb_log_$(ESCAPE_SQUOTE(STRTDT))_$(ESCAPE_SQUOTE(STRTTM)).trn''
                          WITH COMPRESSION, CHECKSUM;';
EXEC msdb.dbo.sp_add_jobserver
     @job_name   = N'AppDb_LogBackup',
     @server_name = N'(local)';

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.syschedules WHERE name = N'Every_15min')
    EXEC msdb.dbo.sp_add_schedule
         @schedule_name      = N'Every_15min',
         @freq_type          = 4,          -- ежедневно
         @freq_interval      = 1,
         @freq_subday_type   = 4,          -- единица интервала: минуты
         @freq_subday_interval = 15,       -- каждые 15 минут
         @active_start_time  = 0,          -- с 00:00:00
         @active_end_time    = 235959;     -- до 23:59:59 (сутки целиком)
IF NOT EXISTS (SELECT 1
                 FROM msdb.dbo.sysjobschedules js
                 JOIN msdb.dbo.sysjobs      j ON j.job_id      = js.job_id
                 JOIN msdb.dbo.syschedules  s ON s.schedule_id = js.schedule_id
                WHERE j.name = N'AppDb_LogBackup'
                  AND s.name = N'Every_15min')
    EXEC msdb.dbo.sp_attach_schedule
         @job_name       = N'AppDb_LogBackup',
         @schedule_name  = N'Every_15min';
PRINT N'Задание AppDb_LogBackup развёрнуто.';
GO

/* ============ 3. ОЧИСТКА СТАРЫХ БЭКАПОВ: ежедневно в 03:00 ============
   Срок хранения 14 дней: при полном бэкапе раз в день и бэкапе журнала
   раз в 15 минут накапливается ~14*93+14 файлов — без очистки диск
   закончится быстро. Хотите другой срок — меняйте цифру 14
   в обоих шагах ниже. */
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'AppDb_BackupCleanup')
    EXEC msdb.dbo.sp_delete_job @job_name = N'AppDb_BackupCleanup';
EXEC msdb.dbo.sp_add_job
     @job_name                   = N'AppDb_BackupCleanup',
     @enabled                    = 1,
     @description                = N'Удаление бэкапов старше 14 дней (файлы + история в msdb)',
     @notify_level_email         = 2,
     @notify_email_operator_name = N'DBA_Operator';
EXEC msdb.dbo.sp_add_jobstep
     @job_name          = N'AppDb_BackupCleanup',
     @step_name         = N'PurgeHistory',
     @subsystem         = N'TSQL',
     @database_name     = N'msdb',
     @command           = N'EXEC msdb.dbo.sp_delete_backuphistory
                              @oldest_date = DATEADD(DAY, -14, GETDATE());',
     @on_success_action = 3;               -- перейти к следующему шагу
EXEC msdb.dbo.sp_add_jobstep
     @job_name      = N'AppDb_BackupCleanup',
     @step_name     = N'DeleteOldFiles',
     @subsystem     = N'PowerShell',
     @command       = N'$path = ''D:\Backup''
$retentionDays = 14
Get-ChildItem -LiteralPath $path -File -Filter ''AppDb_*'' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$retentionDays) } |
    Remove-Item -Force -ErrorAction SilentlyContinue';
EXEC msdb.dbo.sp_add_jobserver
     @job_name   = N'AppDb_BackupCleanup',
     @server_name = N'(local)';

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.syschedules WHERE name = N'Daily_0300')
    EXEC msdb.dbo.sp_add_schedule
         @schedule_name     = N'Daily_0300',
         @freq_type         = 4,
         @freq_interval     = 1,
         @active_start_time = 30000;        -- 03:00:00
IF NOT EXISTS (SELECT 1
                 FROM msdb.dbo.sysjobschedules js
                 JOIN msdb.dbo.sysjobs      j ON j.job_id      = js.job_id
                 JOIN msdb.dbo.syschedules  s ON s.schedule_id = js.schedule_id
                WHERE j.name = N'AppDb_BackupCleanup'
                  AND s.name = N'Daily_0300')
    EXEC msdb.dbo.sp_attach_schedule
         @job_name       = N'AppDb_BackupCleanup',
         @schedule_name  = N'Daily_0300';
PRINT N'Задание AppDb_BackupCleanup развёрнуто.';
GO

/* ============ 4. АЛЕРТЫ И УВЕДОМЛЕНИЯ ============ */

/* Удаляем алерты со старыми именами, созданные исходной версией скрипта:
   Sev_17_plus ловил только severity 17 (не «17 и выше»),
   Corruption_823_824_825 ловил только сообщение 823. */
IF EXISTS (SELECT 1 FROM msdb.dbo.sysalerts WHERE name = N'Sev_17_plus')
    EXEC msdb.dbo.sp_delete_alert @name = N'Sev_17_plus';
IF EXISTS (SELECT 1 FROM msdb.dbo.sysalerts WHERE name = N'Corruption_823_824_825')
    EXEC msdb.dbo.sp_delete_alert @name = N'Corruption_823_824_825';
GO

/* Аlerты по серьёзности 17..25 (софтверные и аппаратные ошибки).
   Напоминание: один alert ловит ровно один уровень серьёзности,
   «>= 17» одной строкой задать нельзя — потому создаём полный набор. */
DECLARE @sev int = 17, @alert_name nvarchar(128);
WHILE @sev <= 25
BEGIN
    SET @alert_name = N'Sev_' + CONVERT(nvarchar(2), @sev);
    IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysalerts WHERE name = @alert_name)
        EXEC msdb.dbo.sp_add_alert
             @name     = @alert_name,
             @severity = @sev,
             @enabled  = 1;
    /* Привязка уведомления (пересоздаём — без дублей при повторном запуске) */
    BEGIN TRY
        EXEC msdb.dbo.sp_delete_notification
             @alert_name = @alert_name, @operator_name = N'DBA_Operator';
    END TRY
    BEGIN CATCH
        /* уведомления ещё не было — это нормальная ситуация */
    END CATCH
    EXEC msdb.dbo.sp_add_notification
         @alert_name         = @alert_name,
         @operator_name      = N'DBA_Operator',
         @notification_method = 1;           -- 1 = e-mail
    SET @sev += 1;
END
PRINT N'Алерты Sev_17..Sev_25 с уведомлениями готовы.';
GO

/* Дедлоки: жертва получает сообщение 1205 */
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysalerts WHERE name = N'Deadlock_1205')
    EXEC msdb.dbo.sp_add_alert
         @name       = N'Deadlock_1205',
         @message_id = 1205,
         @severity   = 0,
         @enabled    = 1;
BEGIN TRY
    EXEC msdb.dbo.sp_delete_notification
         @alert_name = N'Deadlock_1205', @operator_name = N'DBA_Operator';
END TRY
BEGIN CATCH
END CATCH
EXEC msdb.dbo.sp_add_notification
     @alert_name         = N'Deadlock_1205',
     @operator_name      = N'DBA_Operator',
     @notification_method = 1;
GO

/* Повреждения чтения/записи страниц: 823, 824, 825 — отдельный алерт
   на каждую ошибку */
DECLARE @eid int = 823, @aname nvarchar(128);
WHILE @eid <= 825
BEGIN
    SET @aname = N'Corruption_' + CONVERT(nvarchar(3), @eid);
    IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysalerts WHERE name = @aname)
        EXEC msdb.dbo.sp_add_alert
             @name       = @aname,
             @message_id = @eid,
             @severity   = 0,
             @enabled    = 1;
    BEGIN TRY
        EXEC msdb.dbo.sp_delete_notification
             @alert_name = @aname, @operator_name = N'DBA_Operator';
    END TRY
    BEGIN CATCH
    END CATCH
    EXEC msdb.dbo.sp_add_notification
         @alert_name         = @aname,
         @operator_name      = N'DBA_Operator',
         @notification_method = 1;
    SET @eid += 1;
END
PRINT N'Алерты Deadlock_1205 и Corruption_823/824/825 с уведомлениями готовы.';
GO

/* ============ 5. ИТОГ ============ */
SELECT name AS [Созданные задания]
FROM msdb.dbo.sysjobs
WHERE name LIKE N'AppDb_%'
ORDER BY name;

SELECT name AS [Алерты]
FROM msdb.dbo.sysalerts
WHERE name LIKE N'Sev_%' OR name LIKE N'Corruption_%' OR name = N'Deadlock_1205'
ORDER BY name;

PRINT '=== deploy_agent_jobs: развёртывание завершено ===';
GO
