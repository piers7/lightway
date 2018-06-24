#Requires -Version 3.0
# .Synopsis
# Creates a database migration script 
# based on a delta between current model and the previous migration.

# .Notes
# This is the SSDT version, which expects DACPACs, and requires the EmptyDatabase.dacpac file in 'first run' cases.
# This script is part of Lightway - https://github.com/piers7/lightway/
[CmdLetBinding()]
param(
    # Path to the SSDT project that represents the current model (defaults to first .sqlproj in current directory)
    $projectPath = $(dir *.sqlproj | select-object -First:1 -ExpandProperty:FullName),

    # The database name to be used in the generated migration scripts. This can be overridden using SQLCMD parameters
    $databaseName = $([System.IO.Path]::GetFileNameWithoutExtension($projectPath)),

    # The location of where the migration scripts are generated to ( 'migrations' under the project folder by default)
    $migrationsDir = "migrations",

    # If provided, specifies a target version for the migration, otherwise the previous version is rolled
    [version] $targetVersion,
    # If set (and targetVersion not set), the major part of the version number is rolled
    [switch] $isMajor,
    # If set (and targetVersion not set), the minor part of the version number is rolled
    [switch] $isMinor,
    [switch] $whatif
)

$programFiles32 = $env:ProgramFiles
if (Test-Path environment::"ProgramFiles(x86)") { $programFiles32 = (gi "Env:ProgramFiles(x86)").Value };

$ErrorActionPreference = 'stop';
$scriptDir = Split-Path $MyInvocation.MyCommand.Path;

# .synopsis Resolves a parameter as a path.
# This has to be done differently, depending on if the parameter was supplied (ie relative to caller's $PWD)
# compared to if it's set to the default value in the script (resolve relative to scriptDir)
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
# migrationsDir is resolved relative to $PWD *if supplied*, to projectDir otherwise
$migrationsDir = if($migrationsDir) { $migrationsDir } else { Join-Path $projectDir $migrationsDir }

Write-Verbose "ProjectPath = $projectPath"
Write-Verbose "MigrationsDir = $migrationsDir"

# .synopsis Ensure a path exists, or create it
function ensureExists([Parameter(Mandatory=$true)] $path){
    if(-not (Test-Path $path)){ mkdir $path | Out-Null }
}

# .synopsis Increments a version number, either major, minor or patch part
function incrementVersion($version, [switch]$isMajor, [switch]$isMinor){
    if($isMajor) { New-Object System.Version (($version.Major+1),0,0) }
    elseif($isMinor) { New-Object System.Version ($version.Major,($version.Minor+1),0) }
    else { New-Object System.Version ($version.Major,$version.Minor,($version.Build+1)) }
}

# .synopsis Locates sqlPackage.exe on the local machine (either in path, or well-known locations)
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
            ,"$programFiles32\Microsoft Visual Studio 14.0\Common7\IDE\Extensions\Microsoft\SQLDB\DAC\140\sqlpackage.exe"
            )

        $sqlPackage = $possiblePaths |
            % { Get-Item $_ } |
            Select-Object -First:1
    }
    Write-Verbose "Using $sqlPackage"
    $sqlPackage
}

# .synopsis Finds the most recent migration (version and path), as the basis for the comparison
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

# .synopsis Creates a new migration script, based on a source and destination dacpack
function createMigration($source, $target, $outputPath, $databaseName, $parameters){
    Write-Verbose "Create migration: $source -> $target => $outputPath"
    $sqlPackager = findSqlPackage
    # See <https://msdn.microsoft.com/library/hh550080(vs.103).aspx#Script Parameters and Properties>
    $sqlPackagerArgs = @(
        "/Action:Script"
        ,"/SourceFile:$source"
        ,"/TargetFile:$target"
        ,"/OutputPath:$outputPath"
        ,"/TargetDatabaseName:$databaseName"
        ,"/p:CommentOutSetVarDeclarations=true" #comment out SETVAR variables 
        # ,"/p:IgnoreRoleMembership:true" # causes failure! apparently valid option however
        #,"/p:DoNotDropObjectTypes:Tables" # semicolon seperated
        #,"/p:ExcludeObjectTypes:Logins"   # semicolon seperated
    )
    if($parameters){
        $extras = @(
            $parameters.GetEnumerator() |
            % { "/p:{0}={1}" -f $_.Key,$_.Value}
        )
        $sqlPackagerArgs += $extras		
    }

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
    $currentVersion = if ($current) { $current.Version } else { [Version]'0.0.0' }
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
        createMigration -source:$targetSnapshot -target:$currentSnapshot -outputPath:"$targetDir\Upgrade.sql" -databaseName:$databaseName

        Write-Host ".. create undo v$targetVersion" -ForegroundColor:Yellow
        createMigration -source:$currentSnapshot -target:$targetSnapshot -outputPath:"$targetDir\Rollback.sql" -databaseName:$databaseName `
            -parameters:@{
                DropObjectsNotInSource=$true;
                BlockOnPossibleDataLoss=$false;
            }
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