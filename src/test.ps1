[CmdLetBinding()]
param(
    $serverInstance,
    $databaseName = 'LightwayDb.Test',
    [PSCredential] $credentials
)

$dockerPort = 1402

$scriptDir = Split-Path (Convert-Path $MyInvocation.MyCommand.Path)
pushd $scriptDir
try{

$useDocker = !$serverInstance
if($useDocker){
    # do test run against docker instance


    $password = "abAB@#" + (get-random 9999)
    $secpasswd = ConvertTo-SecureString $password -AsPlainText -Force
    $credentials = New-Object System.Management.Automation.PSCredential ("sa", $secpasswd)

    $serverInstance = "localhost,$dockerport" # sql's somewhat bizarre approach for alternative ports

    $containerId = docker run -e "ACCEPT_EULA=Y" -e "MSSQL_SA_PASSWORD=$password" -p "$($dockerport):1433" -d microsoft/mssql-server-linux:2017-latest
    if ($LASTEXITCODE -gt 0) { throw "Run failed" }

    Write-Verbose "Created container $containerId with password $password"

    # Let SQL get its house in order
    Start-Sleep -Seconds:5
}
d
function exec([scriptblock]$fn, [switch]$warningsAsErrors){
    Write-Verbose ([string] $fn)
    & $fn;
    if($LASTERRORCODE -gt 0)    { throw "Process returned exit code $fn"; }
	if($warningsAsErrors -and (!$?))    { throw 'Process returned errors to std.out'}
}

# Create the initial empty database for the test run
.\lightway\Exec-SqlCommand.ps1 -serverInstance:$serverInstance -databaseName:$databaseName -credentials:$credentials -commandText:"CREATE DATABASE [$databaseName]"

# Migrate it
.\lightway\Upgrade-Database.ps1 -serverInstance:$serverInstance -databaseName:$databaseName -credentials:$credentials


#if($useDocker){
#    Write-Verbose "Cleanup container $containerId"
#    docker stop $containerId
#    docker rm $containerId
#}

}finally{
    popd
}