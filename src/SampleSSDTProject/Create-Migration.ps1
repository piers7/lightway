[CmdLetBinding()]
param(
    [version] $targetVersion,
	[switch] $isMajor,
	[switch] $isMinor,
	[switch] $whatif
)

$scriptDir = Split-Path $MyInvocation.MyCommand.Path
$projectPath = Get-ChildItem -Path:$scriptDir *.sqlproj | Select-Object -First:1 -ExpandProperty:FullName
$projectDir = Split-Path -Parent $projectPath
$migrationsDir = Join-Path $projectDir "migrations"

pushd $scriptDir
try{
    ..\lightway\Create-Migration.ps1 -projectPath:$projectPath -migrationsDir:$migrationsDir `
        -targetVersion:$targetVersion -isMajor:$isMajor -isMinor:$isMinor -whatif:$whatif

}finally{
    popd;
}