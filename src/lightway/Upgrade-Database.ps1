#Requires -Version 3.0
# .Synopsis
# Upgrades a target database from a set of migration scripts
param(
	[Parameter(Mandatory=$true)]
	$serverInstance,

	[Parameter(Mandatory=$true)]
	$databaseName,

	[PSCredential] $dbCredentials,

	$targetVersion,
	$scriptsDir,
	$schemaVersionTable = "dbo.SCHEMA_VERSION",

	[Switch]
	$whatif
)

$programFiles32 = $env:ProgramFiles
if (Test-Path environment::"ProgramFiles(x86)") { $programFiles32 = (gi "Env:ProgramFiles(x86)").Value };

function exec([scriptblock]$fn, [switch]$warningsAsErrors){
    Write-Verbose ([string] $fn)
    & $fn;
    if($LASTERRORCODE -gt 0)    { throw "Process returned exit code $fn"; }
	if($warningsAsErrors -and (!$?))    { throw 'Process returned errors to std.out'}
}

# .synopsis
# Create the versions table in the database, if it doesn't exist already
function initDatabase($serverInstance, $databaseName){
	exec {
		if($dbCredentials){
			$username = $dbCredentials.UserName
			$password = $dbCredentials.GetNetworkCredential().Password
            Write-Verbose "Init $serverInstance $databaseName as '$username'"
			sqlcmd -S $serverInstance -d $databaseName -i "$scriptDir\sql\Init Database.sql" -U $username -P $password -v schemaVersionTableName="$schemaVersionTable"
		}else{
            Write-Verbose "Init $serverInstance $databaseName with integrated auth $($env:username)"
			sqlcmd -S $serverInstance -d $databaseName -i "$scriptDir\sql\Init Database.sql" -E -v schemaVersionTableName="$schemaVersionTable"
		}
	}
}

function getCurrentVersion($serverInstance, $databaseName){

}

$scriptDir = Split-Path (Convert-Path $MyInvocation.MyCommand.Path)
pushd $scriptDir
try{
	initDatabase -serverInstance:$serverInstance -databaseName:$databaseName
	getCurrentVersion -serverInstance:$serverInstance -databaseName:$databaseName

}finally{
	popd
}