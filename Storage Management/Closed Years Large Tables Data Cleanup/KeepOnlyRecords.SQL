/*
Description:
This script is designed to archive records from specified tables in a database. It creates a stored procedure that takes table name, legal entity, date, and simulation mode as parameters. The stored procedure performs the following steps:

1. Checks for the existence of necessary fields in the table.
2. Disables Change Data Capture or Change Tracking if enabled.
3. In simulation mode, estimates the duration of select, truncate, and insert statements and counts records.
4. In actual mode, performs the select, truncate, and insert operations.
5. Inserts results into a log table.
6. Re-enables Change Data Capture or Change Tracking if previously enabled.

Parameters:
- @Table: Name of the table to be archived
- @LE: List of legal entities
- @KeepFromDate: Date to keep records from
- @Simulation: Set to 1 for simulation mode, 0 for actual deletion

The script performs the following steps:
1. Drops the stored procedure if it already exists.
2. Creates the stored procedure with the specified parameters.
3. Performs the archiving operations based on the provided parameters.
*/

-- Drop the stored procedure if it already exists
IF OBJECT_ID('dbo.KeepOnlyRecordsSp', 'P') IS NOT NULL
    DROP PROCEDURE dbo.KeepOnlyRecordsSp;
GO

-- Create the stored procedure with specified parameters
CREATE PROCEDURE KeepOnlyRecordsSp
    @Table NVARCHAR(Max),
    @LE NVARCHAR(Max),
    @KeepFromDate DATE,
    @Simulation BIT,
	@Threshold INT = 2000000,
	@BatchSize INT = 5000000
AS
BEGIN

	DECLARE @SQL NVARCHAR(MAX)
    DECLARE @DateField NVARCHAR(255)
    DECLARE @CDCState BIT
    DECLARE @StartTime DATETIME
    DECLARE @EndTime DATETIME 
    DECLARE @Duration INT
    DECLARE @DeletedRecords INT
	DECLARE @SavedRecords INT
    DECLARE @ColumnList NVARCHAR(MAX)
    DECLARE @RunTimestamp DATETIME
	DECLARE @CurrentRow INT = 0;
	DECLARE @BufferTABLEName NVARCHAR(MAX)
	DECLARE @BufferTableDropPrefix NVARCHAR(10) = ''
	DECLARE @Interimstart DATETIME
    DECLARE @Interimend DATETIME 
	DECLARE @nbBatchExecution INT = 0


    -- Create DBCleanupResultsLog table if it doesn't exist
    IF NOT EXISTS (SELECT * FROM sysobjects WHERE name='DBCleanupResultsLog' AND xtype='U')
    BEGIN
        CREATE TABLE DBCleanupResultsLog(
            TableName NVARCHAR(MAX),
            LegalEntity NVARCHAR(MAX),
            KeepFromDate NVARCHAR(120),
            NbRecordsDeleted INT,
			NbRecordsSaved INT,
            EstimatedDuration INT,
            RunTimestamp DATETIME
        )
    END

    -- Check for CreatedDateTime and ModifiedDateTime fields
    IF EXISTS (SELECT * FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = @Table AND COLUMN_NAME = 'CREATEDDATETIME')
    BEGIN
        SET @DateField = 'CREATEDDATETIME'
    END
    ELSE IF EXISTS (SELECT * FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = @Table AND COLUMN_NAME = 'MODIFIEDDATETIME')
    BEGIN
        SET @DateField = 'MODIFIEDDATETIME'
    END
    ELSE
    BEGIN
        PRINT 'Warning: Table ' + @Table + ' does not have CreatedDateTime or ModifiedDateTime fields.'
        RETURN
    END

    -- Check for DataAreaId field in the table
    IF EXISTS (SELECT * FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = @Table AND (COLUMN_NAME = 'DataAreaId'))
    BEGIN
        PRINT 'DataAreaId exists in ' + @Table
    END
    ELSE
    BEGIN
        PRINT 'Warning: Table ' + @Table + ' does not have DataAreaId'
        RETURN
    END

    -- Get column list excluding timestamp columns
    SELECT @ColumnList = STUFF((
        SELECT ', ' + column_name
        FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_NAME = @Table AND DATA_TYPE NOT IN ('timestamp') AND TABLE_SCHEMA = 'DBO'
        FOR XML PATH(''), TYPE
    ).value('.', 'NVARCHAR(MAX)'), 1, 2, '')

    -- Check if CDC is enabled and disable it if necessary
    SELECT @CDCState = is_tracked_by_cdc
    FROM sys.tables
    WHERE name = @Table AND schema_id = SCHEMA_ID('dbo')

    IF @CDCState = 1
    BEGIN
        SET @SQL = 'EXEC sys.sp_cdc_disable_table @source_schema = N''dbo'', @source_name = N''' + @Table + ''', @capture_instance = N''dbo_' + @Table + ''''
                EXEC sp_executesql @SQL
    END

    -- Disable Change Data Capture or Change Tracking if enabled
    SET @SQL = 'IF EXISTS (SELECT * FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(''' + @Table + ''')) ALTER TABLE ' + @Table + ' DISABLE CHANGE_TRACKING'
    EXEC sp_executesql @SQL

    -- Set the run timestamp to current date and time
    SET @RunTimestamp = GETDATE()
    SET @StartTime = GETDATE()

        -- Count records to be deleted in simulation mode
        SET @SQL = 'SELECT @DeletedRecords = COUNT(*) FROM ' + @Table + ' WHERE DataAreaID IN (SELECT value FROM STRING_SPLIT('''+@LE+''', '',''))'+' AND ' + @DateField + ' < ''' + CONVERT(NVARCHAR, @KeepFromDate, 120) + ''''
        EXEC sp_executesql @SQL, N'@DeletedRecords INT OUTPUT', @DeletedRecords OUTPUT

		        -- Count records to be deleted in simulation mode
        SET @SQL = 'SELECT @SavedRecords = COUNT(*) FROM ' + @Table + ' WHERE DataAreaID IN (SELECT value FROM STRING_SPLIT('''+@LE+''', '',''))'+' AND ' + @DateField + ' >= ''' + CONVERT(NVARCHAR, @KeepFromDate, 120) + ''''
        EXEC sp_executesql @SQL, N'@SavedRecords INT OUTPUT', @SavedRecords OUTPUT

		Print @SQL
		Print 'nbRecord to save : ' + CONVERT(NVARCHAR,@SavedRecords)
		IF (@SavedRecords > @Threshold)
			BEGIN
				set @BufferTABLEName = @Table+'cleanupbuffer'
				set @BufferTableDropPrefix = ''
			END
		ELSE
			BEGIN
				set @BufferTABLEName = '##TempTableCleanuDB'
				set @BufferTableDropPrefix = 'tempdb..'
			END
		print 'BufferTable : '+@BufferTABLEName

    -- Simulation mode: Estimate duration of select, truncate, and insert statements and count records
	IF @Simulation = 1
    BEGIN
        -- Estimate duration of select statement in simulation mode
		SET @nbBatchExecution = 1
		SET @Interimstart = GETDATE()
		WHILE @CurrentRow < @SavedRecords
		BEGIN
						-- Drop temporary table if it exists in tempdb
			IF OBJECT_ID(@BufferTableDropPrefix+@BufferTABLEName+Convert(NVARCHAR,@nbBatchExecution)) IS NOT NULL
			BEGIN
				SET @SQL = 'DROP TABLE '+@BufferTABLEName+Convert(NVARCHAR,@nbBatchExecution)
				EXEC sp_executesql @SQL
			END
			BEGIN TRANSACTION
			SET @SQL = 'SELECT ' + @ColumnList + ' INTO '+@BufferTABLEName+Convert(NVARCHAR,@nbBatchExecution)+' FROM ' + @Table + ' WHERE DataAreaID IN (SELECT value FROM STRING_SPLIT('''+@LE+''', '',''))'+' AND ' + @DateField + ' >= ''' + CONVERT(NVARCHAR, @KeepFromDate, 120) + ''''
--			print @SQL
			SET @sql =@SQL + ' ORDER BY RecId OFFSET '+CONvert(NVARCHAR,@CurrentRow)+' ROWS FETCH NEXT '+CONvert(NVARCHAR,@BatchSize)+' ROWS ONLY;'
			EXEC sp_executesql @SQL 
			SET @CurrentRow = @CurrentRow + @BatchSize;
			SET @nbBatchExecution = @nbBatchExecution +1
			COMMIT TRANSACTION
		END
		SET @Interimend = GETDATE()
		SET @Duration = DATEDIFF(MILLISECOND, @Interimstart, @Interimend)
		Print 'copy from main table' + convert(NVARCHAR,@Duration)

		SET @Interimstart = GETDATE()
		-- Estimate duration of truncate statement in simulation mode
        BEGIN TRANSACTION
		SET @SQL = 'TRUNCATE TABLE ' + @Table
        EXEC sp_executesql @SQL
		ROLLBACK TRANSACTION
		SET @Interimend = GETDATE()
		SET @Duration = DATEDIFF(MILLISECOND, @Interimstart, @Interimend)
		Print 'Trucate table' + convert(NVARCHAR,@Duration)
		
        -- Estimate duration of insert statement in simulation mode
        SET @CurrentRow = 0
		SET @nbBatchExecution = 1
		SET @Interimstart = GETDATE()
		WHILE @CurrentRow < @SavedRecords
		BEGIN
			SET @SQL = 'SELECT ' + @ColumnList + ' FROM '+@BufferTABLEName+Convert(NVARCHAR,@nbBatchExecution)
			print @SQL
			EXEC sp_executesql @SQL 
			-- Drop temporary table if it exists in tempdb
			IF OBJECT_ID(@BufferTableDropPrefix+@BufferTABLEName+Convert(NVARCHAR,@nbBatchExecution)) IS NOT NULL
			BEGIN
				SET @SQL = 'DROP TABLE '+@BufferTABLEName+Convert(NVARCHAR,@nbBatchExecution)
				EXEC sp_executesql @SQL
			END
			SET @CurrentRow = @CurrentRow + @BatchSize;
			SET @nbBatchExecution = @nbBatchExecution +1
		END

		SET @Interimend = GETDATE()
		SET @Duration = DATEDIFF(MILLISECOND, @Interimstart, @Interimend)
		Print 'Copy Back data' + convert(NVARCHAR,@Duration)
		
    END
    ELSE
    BEGIN
		-- Estimate duration of select statement in simulation mode
		SET @nbBatchExecution = 1
		SET @Interimstart = GETDATE()
		WHILE @CurrentRow < @SavedRecords
		BEGIN
						-- Drop temporary table if it exists in tempdb
			IF OBJECT_ID(@BufferTableDropPrefix+@BufferTABLEName+Convert(NVARCHAR,@nbBatchExecution)) IS NOT NULL
			BEGIN
				SET @SQL = 'DROP TABLE '+@BufferTABLEName+Convert(NVARCHAR,@nbBatchExecution)
				EXEC sp_executesql @SQL
			END

			BEGIN TRANSACTION
			Begin 
				SET @SQL = 'SELECT ' + @ColumnList + ' INTO '+@BufferTABLEName+Convert(NVARCHAR,@nbBatchExecution)+' FROM ' + @Table + ' WHERE DataAreaID IN (SELECT value FROM STRING_SPLIT('''+@LE+''', '',''))'+' AND ' + @DateField + ' >= ''' + CONVERT(NVARCHAR, @KeepFromDate, 120) + ''''
				print @SQL
			END
			SET @sql =@SQL + ' ORDER BY RecId OFFSET '+CONvert(NVARCHAR,@CurrentRow)+' ROWS FETCH NEXT '+CONvert(NVARCHAR,@BatchSize)+' ROWS ONLY;'
			EXEC sp_executesql @SQL 
			SET @CurrentRow = @CurrentRow + @BatchSize;
			SET @nbBatchExecution = @nbBatchExecution +1
			COMMIT TRANSACTION
		END
		SET @Interimend = GETDATE()
		SET @Duration = DATEDIFF(MILLISECOND, @Interimstart, @Interimend)
		Print 'copy from main table' + convert(NVARCHAR,@Duration)

		SET @Interimstart = GETDATE()
		-- Estimate duration of truncate statement in simulation mode
        BEGIN TRANSACTION
		SET @SQL = 'TRUNCATE TABLE ' + @Table
        EXEC sp_executesql @SQL
		COMMIT TRANSACTION
		SET @Interimend = GETDATE()
		SET @Duration = DATEDIFF(MILLISECOND, @Interimstart, @Interimend)
		Print 'Trucate table' + convert(NVARCHAR,@Duration)
		
        -- Estimate duration of insert statement in simulation mode
        SET @CurrentRow = 0
		SET @nbBatchExecution = 1
		SET @Interimstart = GETDATE()
		WHILE @CurrentRow < @SavedRecords
		BEGIN
			BEGIN TRANSACTION
			SET @SQL = 'INSERT INTO ' + @Table + ' (' + @ColumnList + ') SELECT ' + @ColumnList + ' FROM '+@BufferTABLEName+Convert(NVARCHAR,@nbBatchExecution)
			print @SQL
			EXEC sp_executesql @SQL 
			-- Drop temporary table if it exists in tempdb
			IF OBJECT_ID(@BufferTableDropPrefix+@BufferTABLEName+Convert(NVARCHAR,@nbBatchExecution)) IS NOT NULL
			BEGIN
				SET @SQL = 'DROP TABLE '+@BufferTABLEName+Convert(NVARCHAR,@nbBatchExecution)
				EXEC sp_executesql @SQL
			END
			SET @CurrentRow = @CurrentRow + @BatchSize;
			SET @nbBatchExecution = @nbBatchExecution +1

			COMMIT TRANSACTION
		END

		SET @Interimend = GETDATE()
		SET @Duration = DATEDIFF(MILLISECOND, @Interimstart, @Interimend)
		Print 'Copy Back data' + convert(NVARCHAR,@Duration)

    END

    SET @EndTime = GETDATE()
        -- Calculate duration of operations in simulation mode
    SET @Duration = DATEDIFF(MILLISECOND, @StartTime, @EndTime)


	        -- Insert results into persisted table DBCleanupResultsLog 
        INSERT INTO DBCleanupResultsLog (TableName, LegalEntity, KeepFromDate, NbRecordsDeleted, NbRecordsSaved, EstimatedDuration, RunTimestamp)
        VALUES (@Table, @LE, CONVERT(NVARCHAR, @KeepFromDate, 120), @DeletedRecords,@SavedRecords, @Duration, @RunTimestamp)
        
        -- Select results from log table for verification in simulation mode 
        SELECT * FROM DBCleanupResultsLog WHERE TableName=@Table AND LegalEntity=@LE AND KeepFromDate=CONVERT(NVARCHAR, @KeepFromDate, 120)


    -- Re-enable Change Data Capture or Change Tracking if previously enabled
    IF @CDCState = 1
    BEGIN
		SET @SQL = 'EXEC sys.sp_cdc_enable_table @source_schema = N''dbo'', @source_name = N''' + @Table + ''', @role_name = NULL'
        EXEC sp_executesql @SQL
    END

    SET @SQL = 'IF EXISTS (SELECT * FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID(''' + @Table + ''')) ALTER TABLE ' + @Table + ' ENABLE CHANGE_TRACKING'
    EXEC sp_executesql @SQL
END
GO
