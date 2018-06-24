[CmdLetBinding()]
param(
    $serverInstance = "(localdb)\MSSQLLocalDB",
    #$serverInstance = "docker:lightway",
    $databaseName = 'LightwayDb.Test',
    [PSCredential] $credentials,
    [switch]$fromModel,
    [switch]$useDocker
)

$dockerPort = 1402

$scriptDir = $PSScriptRoot # Split-Path (Convert-Path $MyInvocation.MyCommand.Path)
$ErrorActionPreference = 'stop'

function exec([scriptblock]$fn, [switch]$warningsAsErrors){
    Write-Verbose ([string] $fn)
    & $fn;
    if($LASTERRORCODE -gt 0)    { throw "Process returned exit code $fn"; }
	if($warningsAsErrors -and (!$?))    { throw 'Process returned errors to std.out'}
}

pushd $scriptDir
try{

    if($useDocker){
        # do test run against docker instance
        $password = "abAB@#" + (get-random 9999)
        $secpasswd = ConvertTo-SecureString $password -AsPlainText -Force
        $credentials = New-Object System.Management.Automation.PSCredential ("sa", $secpasswd)
        $containerName = $databaseName

        $serverInstance = "localhost,$dockerport" # sql's somewhat bizarre approach for alternative ports

        $containerId = docker run --rm --name $containerName -e "ACCEPT_EULA=Y" -e "MSSQL_SA_PASSWORD=$password" -p "$($dockerport):1433" -d microsoft/mssql-server-linux:2017-latest
        if ($LASTEXITCODE -gt 0) { throw "Run failed" }

        Write-Verbose "Created container $containerId, userid $($credentials.UserName), password $password"

        # Let SQL get its house in order
        Start-Sleep -Seconds:5
    }


    # Create the initial empty database for the test run
    $dropSql = @"
    if exists (select * from sys.databases d where d.database_id = DB_ID('$databaseName'))
    begin
        ALTER DATABASE [$databaseName] SET SINGLE_USER with rollback immediate
        DROP DATABASE [$databaseName]
    end
    CREATE DATABASE [$databaseName]
"@
    [void] (.\lightway\Exec-SqlCommand.ps1 -serverInstance:$serverInstance -credentials:$credentials -commandText:$dropSql)

    # Migrate it
    .\lightway\Deploy-Database.ps1 -serverInstance:$serverInstance -databaseName:$databaseName -credentials:$credentials -migrationsDir:.\SampleSSDTProject\migrations -model:.\SampleSSDTProject\bin\debug\SampleSSDTProject.dacpac -fromModel:$fromModel

    if($useDocker){
        Write-Verbose "Cleanup container $containerId"
        docker stop $containerId
    #    docker rm $containerId
    }

}catch{
    Write-Host $error[0].ScriptStackTrace
    throw
}finally{
    popd
}