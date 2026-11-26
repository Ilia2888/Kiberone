/* =============================================================
   msdb: задания бэкапов и алерты
   ============================================================= */
USE msdb;
GO

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name=N'AppDb_FullBackup')
EXEC sp_add_job @job_name=N'AppDb_FullBackup', @enabled=1,
                @description=N'Полный бэкап AppDb ежедневно';

EXEC sp_add_jobstep @job_name=N'AppDb_FullBackup',
    @step_name=N'Backup',
    @subsystem=N'TSQL',
    @command=N'BACKUP DATABASE AppDb TO DISK=''D:\Backup\AppDb_full_$(ESCAPE_SQUOTE(STRTDTIME)).bak''
               WITH INIT, COMPRESSION, CHECKSUM;';

EXEC sp_add_schedule @schedule_name=N'Daily_0200',
    @freq_type=4, @freq_interval=1, @active_start_time=020000;
EXEC sp_attach_schedule @job_name=N'AppDb_FullBackup', @schedule_name=N'Daily_0200';
EXEC sp_add_jobserver  @job_name=N'AppDb_FullBackup';
GO

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name=N'AppDb_LogBackup')
EXEC sp_add_job @job_name=N'AppDb_LogBackup', @enabled=1;

EXEC sp_add_jobstep @job_name=N'AppDb_LogBackup',
    @step_name=N'LogBackup',
    @subsystem=N'TSQL',
    @command=N'BACKUP LOG AppDb TO DISK=''D:\Backup\AppDb_log_$(ESCAPE_SQUOTE(STRTDTIME)).trn''
               WITH COMPRESSION, CHECKSUM;';

EXEC sp_add_schedule @schedule_name=N'Every_15min',
    @freq_type=4, @freq_interval=1, @freq_subday_type=4, @freq_subday_interval=15,
    @active_start_time=000000;
EXEC sp_attach_schedule @job_name=N'AppDb_LogBackup', @schedule_name=N'Every_15min';
EXEC sp_add_jobserver  @job_name=N'AppDb_LogBackup';
GO

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysalerts WHERE name=N'Sev_17_plus')
EXEC msdb.dbo.sp_add_alert @name=N'Sev_17_plus', @severity=17, @enabled=1;

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysalerts WHERE name=N'Deadlock_1205')
EXEC msdb.dbo.sp_add_alert @name=N'Deadlock_1205',
    @message_id=1205, @severity=0, @enabled=1;

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysalerts WHERE name=N'Corruption_823_824_825')
BEGIN
  EXEC msdb.dbo.sp_add_alert @name=N'Corruption_823_824_825',
       @message_id=823, @severity=0, @enabled=1;
  EXEC msdb.dbo.sp_add_alert @name=N'Corruption_824',
       @message_id=824, @severity=0, @enabled=1;
  EXEC msdb.dbo.sp_add_alert @name=N'Corruption_825',
       @message_id=825, @severity=0, @enabled=1;
END
GO