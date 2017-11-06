#Requires -Version 3.0
# .Synopsis
# Lightway is a lightweight script runner for running SQL change scripts into a database
# It's intended to be Flyway compatable, but without the 100mb footprint
# This script is an implementation of a ReadyRoll-esqe workflow to generate the scripts in the first place
# NB: One of the disadvantages of this kind of approach is that database names get baked into the scripts up-front
[CmdLetBinding()]
param(
	#[Parameter(Mandatory=$true)]
	$projectPath = "SampleSSDTProject",
	$databaseName = $([System.IO.Path]::GetFileNameWithoutExtension($projectPath)),
	$releasesRelDir = "migrations",

	$scriptsDir,

	[switch] $isMajor,
	[switch] $isMinor,
	[switch] $whatif
)

$programFiles32 = $env:ProgramFiles
if (Test-Path environment::"ProgramFiles(x86)") { $programFiles32 = (gi "Env:ProgramFiles(x86)").Value };

function resolvePath($path, [switch]$relativeToScriptDir){
	$baseDir = if($relativeToScriptDir) { $scriptsDir } else { $pwd }
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
$releasesDir = Join-Path $projectDir $releasesRelDir
$projectName = [IO.Path]::GetFileNameWithoutExtension($projectPath)
Write-Verbose "ProjectPath = $projectPath"
Write-Verbose "ReleasesDir = $releasesDir"

function findSqlPackage(){
	# use on path if present
	$sqlPackage = (Get-Command "sqlPackage.exe" -ErrorAction:SilentlyContinue | Select-Object -First:1 -ExpandProperty:Path)

	if(!$sqlPackage){
		# failing that, go and look in a couple of expected locations
		# Wonder if I should locate them all and sort by modified date or something? At the moment FIFO
		Write-Verbose "Searching for sqlPackage.exe"
		$possiblePaths = @(
			"$programFiles32\Microsoft Visual Studio\2017\Enterprise\Common7\IDE\Extensions\Microsoft\SQLDB\DAC\130\sqlPackage.exe"
			,"$programFiles32\Microsoft SQL Server\140\DAC\bin\sqlPackage.exe"
			,"$programFiles32\Microsoft SQL Server\130\DAC\bin\sqlPackage.exe"
			,"$programFiles32\Microsoft SQL Server\120\DAC\bin\sqlPackage.exe"
			,"$programFiles32\Microsoft SQL Server\110\DAC\bin\sqlPackage.exe"
			)

		$sqlPackage = $possiblePaths |
			? { Test-Path $_ } |
			Select-Object -First:1
	}
	Write-Verbose "Using $sqlPackage"
	$sqlPackage
}

function getCurrentVersion() { 
	$currentVersion = 
		Get-ChildItem $releasesDir |
			? { $_.Name.StartsWith("v") } |
			%{ [Version] $_.Name.Substring(1) } |
			Sort-Object |
			Select-Object -Last:1
	
	if($currentVersion) { 
		$currentVersion
	}else{
		[Version]"1.0.0"
	}
}

function ensureFolderExists($path){
	if(!(Test-Path $path)) { mkdir $path | out-null }
}

function createDeltaScript($sourceDacpac, $targetDacpac, $scriptFilePath, $databaseName){
	$sqlPackager = findSqlPackage
	# See <https://msdn.microsoft.com/library/hh550080(vs.103).aspx#Script Parameters and Properties>
	$sqlPackagerArgs = @(
		"/Action:Script"
		,"/SourceFile:$sourceDacpac"
		,"/TargetFile:$targetDacpac"
		,"/OutputPath:$scriptFilePath"
		,"/TargetDatabaseName:$databaseName"
		# ,"/p:IgnoreRoleMembership:true" # causes failure! apparently valid option however
		#,"/p:DoNotDropObjectTypes:Tables" # semicolon seperated
		#,"/p:ExcludeObjectTypes:Logins"   # semicolon seperated
	)

	ensureFolderExists (split-path -parent $scriptFilePath)

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

$scriptDir = Split-Path (Convert-Path $MyInvocation.MyCommand.Path)
pushd $scriptDir
try{
	[Version] $version = getCurrentVersion $releasesDir
	$targetVersion = `
		if($isMajor) { New-Object System.Version (($version.Major+1),$version.Minor,$version.Build) }
		elseif($isMinor) { New-Object System.Version ($version.Major,($version.Minor+1),$version.Build) }
		else { New-Object System.Version ($version.Major,$version.Minor,($version.Build+1)) }

	Write-Verbose "Setup required folder structure"
	ensureFolderExists $releasesDir
	ensureFolderExists "$releasesDir\Pre-Deployment"
	ensureFolderExists "$releasesDir\Post-Deployment"

	Write-Host "Generating upgrade for $databaseName v$targetVersion" -ForegroundColor:Yellow

	Write-Verbose "Check for previous failed migrations"
	if(Test-Path "$releasesDir\CurrentSnapshot.new.dacpac"){
		throw "Temporary 'new' file exists from failed previous migration - please revert state manually before trying again"
	}

	Write-Verbose "Locate prior (current) snapshot" 
	if(!(Test-Path "$releasesDir\CurrentSnapshot.dacpac")){
		Copy-Item "$scriptDir\EmptyDatabase.dacpac" "$releasesDir\CurrentSnapshot.dacpac"
	}

	Write-Verbose "Locate new (future) snapshot" 
	Copy-Item "$projectDir\bin\debug\$projectName.dacpac" "$releasesDir\CurrentSnapshot.new.dacpac"

	try{
		Write-Host ".. create delta v$targetVersion" -ForegroundColor:Yellow
		createDeltaScript -sourceDacpac:"$releasesDir\CurrentSnapshot.dacpac" -targetDacpac:"$releasesDir\CurrentSnapshot.new.dacpac" "$releasesDir\v$targetVersion\Upgrade.sql" -databaseName:$databaseName

		Write-Host ".. create undo v$targetVersion" -ForegroundColor:Yellow
		createDeltaScript -targetDacpac:"$releasesDir\CurrentSnapshot.dacpac" -sourceDacpac:"$releasesDir\CurrentSnapshot.new.dacpac" "$releasesDir\v$targetVersion\Rollback.sql" -databaseName:$databaseName
	}catch{
		Remove-Item "$releasesDir\CurrentSnapshot.new.dacpac"
		throw # rethrow original ex
	}

	Write-Verbose "Commit snapshot swap" 
	Move-Item "$releasesDir\CurrentSnapshot.new.dacpac" "$releasesDir\CurrentSnapshot.dacpac" -Force

	Write-Host
	Write-Host "Upgrade all done" -ForegroundColor:Yellow
	Write-Host "Be sure to commit and publish your changes"
}finally{
	popd
}