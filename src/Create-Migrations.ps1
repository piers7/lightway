[CmdLetBinding()]
param(
    [version] $targetVersion,
	[switch] $isMajor,
	[switch] $isMinor,
	[switch] $whatif
)

$projectFolders = @(
    "$psScriptRoot\SampleSSDTProject"
)

foreach($projectDir in $projectFolders){
    $projectPath = Get-ChildItem -Path:$projectDir *.sqlproj | Select-Object -First:1 -ExpandProperty:FullName
    $migrationsDir = Join-Path $projectDir "migrations"

    & $psScriptRoot\lightway\Create-Migration.ps1 -projectPath:$projectPath -migrationsDir:$migrationsDir `
        -targetVersion:$targetVersion -isMajor:$isMajor -isMinor:$isMinor -whatif:$whatif

}