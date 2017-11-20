#Requires -Version 3.0
# .Synopsis
# Creates a database migration script,
# based on the delta between the current SSDT project version, and the previous snapshot
[CmdLetBinding()]
param(
	[Parameter(Mandatory=$true)]
	$projectPath,
	$databaseName = $([System.IO.Path]::GetFileNameWithoutExtension($projectPath)),
    $migrationsDir,

    [version] $targetVersion,
	[switch] $isMajor,
	[switch] $isMinor,
	[switch] $whatif
)

$programFiles32 = $env:ProgramFiles
if (Test-Path environment::"ProgramFiles(x86)") { $programFiles32 = (gi "Env:ProgramFiles(x86)").Value };

$ErrorActionPreference = 'stop';
$scriptDir = Split-Path $MyInvocation.MyCommand.Path;
function resolvePath([Parameter(Mandatory=$true)] $path, [switch]$relativeToScriptDir){
	$baseDir = if($relativeToScriptDir) { $scriptDir } else { $pwd }
	pushd $baseDir
	try{
		Resolve-Path $path
	}finally{
		popd
	}
}

# if $projectPath is a directory (not a path to a .sqlproj), infer the full path
# Note: defaults must be resolved relative to script dir (groan)
$projectPath = ( resolvePath $projectPath -relativeToScriptDir:(!$PSBoundParameters.ContainsKey("projectPath")) ).Path
Write-Verbose $projectPath
if (![IO.File]::Exists($projectPath)){
	# it must be a directory then
	$projectPath = Join-Path $projectPath ((Split-Path -Leaf $projectPath) + ".sqlproj")
	Write-Verbose "Inferred projectPath from directory, as $projectPath"
}
$projectDir = Split-Path -Parent $projectPath
$projectName = [IO.Path]::GetFileNameWithoutExtension($projectPath)
# migrationsDir is resolved relative to scriptDir *if supplied*, to projectDir if defaulted
$migrationsDir = if($migrationsDir) { (Resolve-Path $migrationsDir).Path } else { Join-Path $projectDir "migrations" }

Write-Verbose "ProjectPath = $projectPath"
Write-Verbose "MigrationsDir = $migrationsDir"

function ensureExists([Parameter(Mandatory=$true)] $path){
    if(-not (Test-Path $path)){ mkdir $path | Out-Null }
}

function incrementVersion($version, [switch]$isMajor, [switch]$isMinor){
	if($isMajor) { New-Object System.Version (($version.Major+1),0,0) }
	elseif($isMinor) { New-Object System.Version ($version.Major,($version.Minor+1),0) }
	else { New-Object System.Version ($version.Major,$version.Minor,($version.Build+1)) }
}

function findSqlPackage(){
	# use on path if present
	$sqlPackage = (Get-Command "sqlPackage.exe" -ErrorAction:SilentlyContinue | Select-Object -First:1 -ExpandProperty:Path)

	if(!$sqlPackage){
		# failing that, go and look in a couple of expected locations
		# Wonder if I should locate them all and sort by modified date or something? At the moment FIFO
		# NB: Now using wildcards, to cover more cases
		# "$programFiles32\Microsoft Visual Studio\2017\Enterprise\Common7\IDE\Extensions\Microsoft\SQLDB\DAC\130\sqlPackage.exe"
		# "$programFiles32\Microsoft SQL Server\140\DAC\bin\sqlPackage.exe"
		Write-Verbose "Searching for sqlPackage.exe"
		$possiblePaths = @(
			"$programFiles32\Microsoft Visual Studio\2017\*\Common7\IDE\Extensions\Microsoft\SQLDB\DAC\130\sqlPackage.exe"
			,"$programFiles32\Microsoft SQL Server\*\DAC\bin\sqlPackage.exe"
			)

		$sqlPackage = $possiblePaths |
			? { Get-Item $_ } |
			Select-Object -First:1
	}
	Write-Verbose "Using $sqlPackage"
	$sqlPackage
}

function getCurrentVersion([Parameter(Mandatory=$true)] $migrationsDir) { 
	Get-ChildItem $migrationsDir |
		? { $_.Name.StartsWith("v") } |
		Select-Object -Property:@{
			Name="Path";
			Expression={$_.FullName}
		},@{
			Name="Version";
			Expression={ [Version] (($_.Name.Substring(1) -split '_')[0]) }
		} |
		? { !$targetVersion -or ($_ -lt $targetVersion)} |
		Sort-Object |
		Select-Object -Last:1
}

function createMigration($source,$target,$outputPath,$databaseName){
	Write-Verbose "Create migration: $source -> $target => $outputPath"
	$sqlPackager = findSqlPackage
	# See <https://msdn.microsoft.com/library/hh550080(vs.103).aspx#Script Parameters and Properties>
	$sqlPackagerArgs = @(
		"/Action:Script"
		,"/SourceFile:$source"
		,"/TargetFile:$target"
		,"/OutputPath:$outputPath"
		,"/TargetDatabaseName:$databaseName"
		# ,"/p:IgnoreRoleMembership:true" # causes failure! apparently valid option however
		#,"/p:DoNotDropObjectTypes:Tables" # semicolon seperated
		#,"/p:ExcludeObjectTypes:Logins"   # semicolon seperated
	)

	ensureExists (split-path -parent $outputPath)

    Write-Verbose ("$sqlPackager " + ($sqlPackagerArgs -join ' '));
    # Handling of stderr FUBAR in Powershell 3
    # http://connect.microsoft.com/PowerShell/feedback/details/765551/in-powershell-v3-you-cant-redirect-stderr-to-stdout-without-generating-error-records
    # http://stackoverflow.com/questions/10666101/powershell-lastexitcode-0-but-false-redirecting-stderr-to-stdout-gives-nat
    $eap = $ErrorActionPreference
    try{
        $ErrorActionPreference = 'continue'
        & $sqlPackager $sqlPackagerArgs 2>&1;
    }finally{
        $ErrorActionPreference = $eap;
    }

	if($LASTEXITCODE -gt 0){
        throw "Publish failed: exitcode $LASTEXITCODE";
    }
}

pushd $scriptDir
try{
    # allow relative paths from non-powershell apps (exe's etc...)
    [Environment]::CurrentDirectory = $scriptDir

	Write-Verbose "Setup required folder structure"
	ensureExists $migrationsDir
	ensureExists "$migrationsDir\Pre-Deployment"
	ensureExists "$migrationsDir\Post-Deployment"

	Write-Verbose "Check for incomplete migrations"
	if(Test-Path "$migrationsDir\*\CurrentSnapshot.new.dacpac"){
		throw "Temporary 'new' file exists from failed previous migration - please revert state manually before trying again"
	}

	Write-Verbose "Determine prior migration version (if present)"
	$current = getCurrentVersion $migrationsDir
	$currentVersion = if ($current) { $current.Version } else { [Version]::new(0,0,0) }
    if(!$targetVersion){
        $targetVersion = incrementVersion $currentVersion -isMajor:$isMajor -isMinor:$isMinor
	}

    Write-Host "Generating migration $databaseName v$currentVersion -> v$targetVersion" -ForegroundColor:Yellow

	Write-Verbose "Locate prior (current) snapshot" 
	$currentSnapshot = `
		if ($current) { 
			Join-Path $current.Path "CurrentSnapshot.dacpac"
		} else { 
			Join-Path $scriptDir "EmptyDatabase.dacpac"
		}

	Write-Verbose "Setup paths for new migration" 
	$targetDir = Join-Path $migrationsDir "v$targetVersion"
	$targetSnapshot = Join-Path $targetDir "CurrentSnapshot.new.dacpac"
	$targetSnapshotFinal = Join-Path $targetDir "CurrentSnapshot.dacpac"
	ensureExists $targetDir

	Write-Verbose "Copy over new (future) snapshot" 
	Copy-Item "$projectDir\bin\debug\$projectName.dacpac" $targetSnapshot

	try{
		Write-Host ".. create delta v$targetVersion" -ForegroundColor:Yellow
		createMigration -source:$currentSnapshot -target:$targetSnapshot -outputPath:"$targetDir\Upgrade.sql" -databaseName:$databaseName

		Write-Host ".. create undo v$targetVersion" -ForegroundColor:Yellow
		createMigration -source:$targetSnapshot -target:$currentSnapshot -outputPath:"$targetDir\Rollback.sql" -databaseName:$databaseName
	}catch{
		Write-Warning "Failed. Rolling back temporary state"
		Write-Verbose "Removing $targetDir"
		Remove-Item $targetDir -Recurse:$true
		throw # rethrow original ex
	}

    # commit the update
	Write-Verbose "Commit snapshot swap" 
	Move-Item $targetSnapshot $targetSnapshotFinal -Force

	Write-Host
	Write-Host "Upgrade all done" -ForegroundColor:Yellow
	Write-Host "Be sure to commit and publish your changes"
}finally{
	popd
}