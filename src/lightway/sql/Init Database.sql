IF NOT EXISTS(SELECT name from sys.tables where schema_id = schema_id('$(schemaVersionSchemaName)') and name = '$(schemaVersionTableName)')
BEGIN
	print 'Creating $(schemaVersionSchemaName).$(schemaVersionTableName) table'
	CREATE TABLE [$(schemaVersionSchemaName)].[$(schemaVersionTableName)](
		[installed_rank] [int] NOT NULL IDENTITY(1,1),
		[version] [nvarchar](50) NOT NULL,
		[description] [nvarchar](200) NULL,
		[type] [nvarchar](20) NOT NULL,
		[script] [nvarchar](1000) NOT NULL,
		[checksum] [int] NULL,
		[installed_by] [nvarchar](100) NOT NULL,
		[installed_on] [datetime] NOT NULL,
		[execution_time] [int] NOT NULL,
		[success] [bit] NOT NULL,
	 CONSTRAINT [schema_version_pk] PRIMARY KEY CLUSTERED 
	(
		[installed_rank] ASC
	)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
	) ON [PRIMARY]
END
GO

ALTER TABLE dbo.SCHEMA_VERSION ADD CONSTRAINT
	DF_SCHEMA_VERSION_installed_on DEFAULT getdate() FOR installed_on
GO
