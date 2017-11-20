[CmdLetBinding()]
param(
)

$scriptDir = Split-Path $MyInvocation.MyCommand.Path
$projectPath = Get-ChildItem -Path:$scriptDir *.sqlproj | Select-Object -First:1 -ExpandProperty:FullName
$projectDir = Split-Path -Parent $projectPath
$migrationsDir = Join-Path $projectDir "migrations"

pushd $scriptDir
try{
    ..\lightway\Create-Migration.ps1 -projectPath:$projectPath -migrationsDir:$migrationsDir

}finally{
    popd;
}