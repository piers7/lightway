#Requires -Version 3.0

<#
.SYNOPSIS
Deploys or upgrades a target database from a set of migration scripts
.DESCRIPTION
This script migrates a database schema between one version and another,
based on either a series of canned migration scripts (the default), or (optionally) a model snapshot file.

By default the script will migrate the database between its current version (based on a tracking
table in the schema) to the latest version, but both -fromVersion and -toVersion may be specified if required.
.NOTES
Migration scripts are executed using System.Version sorting semantics.
Version numbers are padded out to three parts before sorting, to 'fix' some OOB sorting issues.

Scripts starting with an underscore (or in a folder starting with an underscore) are ignored.
#>
[CmdLetBinding(SupportsShouldProcess=$true)]
param(
	[Parameter(Mandatory=$true)]
	$serverInstance,

	[Parameter(Mandatory=$true)]
	$databaseName,

	[PSCredential] $credentials,

	$schemaTable = "dbo.SCHEMA_VERSION",
	$migrationsDir = "../migrations/",

	# Version to migrate from, determined from tracking table in schema if not supplied
	[Version]$fromVersion,
	# Version to migrate to, defaults to latest version if not supplied
	[Version]$toVersion,

	# If specified, deployment occurs from the model, and not the migrations. This is primarily intended for local dev scenarios
	[switch]$fromModel,
	# If -fromModel specified, the path to the DACPAC that represents the model for this deployment
	$model,

    [switch]$allowCreate,
	[switch]$skipPreScripts,
	[switch]$skipPostScripts
)

$programFiles32 = $env:ProgramFiles
if (Test-Path environment::"ProgramFiles(x86)") { $programFiles32 = (gi "Env:ProgramFiles(x86)").Value };
$scriptDir = Split-Path (Convert-Path $MyInvocation.MyCommand.Path)

# load in sqlpackage library
. $scriptDir\sql\sqlpackage.ps1

# .synopsis 
# Expands 2 part version numbers out to 3 parts
function expandVersionNumber([Version]$version){
    # Pass nulls / unspecified version as-is
    if(!$version) { return $version }

    # Explicitly don't support 4-part versions
    if($version.Revision -ne -1){
        throw "Only 3 part version numbers supported (cannot expand '$version')"
    }

    # Expand 2 part versions to 3 parts, otherwise sorting doesn't work
    if($version.Build -eq -1){
        return new-object Version ($version.Major,$version.Minor,0)
    }

    # Pass others (3 parts) as-is
    $version
}

# .synopsys 
# Extracts the version number from a script path
function get-scriptversion($scriptPath) {
    # We use a very liberal scheme here, where we attempt to get the last version number
    # from the script path that we can locate.
    # This allows for the version number to be in the file name, or in the parent folder
    # depending on how the migrations are built
    # eg both

    # v0.0.1\v0.0.1.Update.sql and
    # v0.0.1\01.TheFirstMigration.upgrade.sql

    $versionMatches = [System.Text.RegularExpressions.Regex]::Matches($scriptPath, '[Vv](\d+\.\d+(\.\d+)?)')
    $raw = $versionMatches | % { $_.Groups[1].Value } | Select-Object -Last:1
    Write-Verbose "Extracted version '$raw' from $scriptPath"

    $rawVersion = [Version]::Parse($raw)
    expandVersionNumber $rawVersion
}

# .synopsis
# Gets all the scripts under a certain folder (recursively)
# Scripts are returned in version order (in case they've not been padded for natural ordering)
function Get-Scripts($dir, $filter = '*.sql', [switch]$reverseOrder){
    Get-ChildItem -Path:$dir -filter:$filter -Recurse |
        ? { ! ( $_.Name.StartsWith('_') -or $_.Directory.Name.StartsWith('_') ) } |
        % { 
            new-object psobject -property:@{
                Name = $_.Name;
                FullName = $_.FullName;
                Version = Get-ScriptVersion $_.FullName;
            }         
        } |
        Sort-Object -Property:Version,Name -Descending:$reverseOrder
}

function exec([scriptblock]$fn, [switch]$warningsAsErrors){
    Write-Verbose ([string] $fn)
    & $fn;
    if($LASTERRORCODE -gt 0)    { throw "Process returned exit code $fn"; }
	if($warningsAsErrors -and (!$?))    { throw 'Process returned errors to std.out'}
}

function Invoke-SqlCommand(
    $commandText, 
    $commandParams, 
    $databaseName=$databaseName,
    [switch]$execScalar
){
	& $scriptDir\Exec-SqlCommand.ps1 -serverInstance:$serverInstance -databaseName:$databaseName -credentials:$credentials -commandText:$commandText -commandParams:$commandParams -execScalar:$execScalar
}

function Invoke-SqlScriptFile{
    [cmdletbinding()]
    param(
        [parameter(mandatory=$true, valuefrompipeline=$true, valuefrompipelinebypropertyname=$true)]
        [alias("fullname")]
        [string[]]$scriptpath,
        [hashtable]$scriptargs=@{DatabaseName=$databaseName}
    )
    begin{
        $sqlScriptArgs = @($scriptArgs.GetEnumerator() | % { "{0}={1}" -f $_.Key,$_.Value })
    }
    process{
        Invoke-SqlCmd -serverinstance:$serverInstance -database:$databaseName -inputfile:$_ -Variable:$sqlScriptArgs
    }
    end{}
}

# .synopsis
# Create the versions table in the database, if it doesn't exist already
function initDatabase([switch]$allowCreate){
    if($allowCreate){
        exec {
            [void] (Invoke-SqlCommand -databaseName:master -commandText:"IF NOT EXISTS (select * from sys.databases where name = '$databaseName') CREATE DATABASE $databaseName")
        }
    }

    $scripts = @(
        "$scriptDir\sql\InitDatabase.sql"
    )

	$schemaVersionParts = $schemaTable -split '\.',2
	$schema = $schemaVersionParts[0]
	$table = $schemaVersionParts[1]

    $scripts | Invoke-SqlScriptFile -scriptargs:@{
        schemaVersionSchemaName=$schema
        schemaVersionTableName=$table
    }
}

function getCurrentSchemaVersion() {
	$sql = "select top 1 [version] from $schemaTable order by installed_rank desc"
	$versionTxt = Invoke-SqlCommand -commandText:$sql -execScalar
	[Version]$version = [Version]'0.0.0'
	if([Version]::TryParse($versionTxt, [ref]$version)){
		$version
	}else{
		[Version]'0.0.0'
	}
}

function writeSchemaVersion($version, $type, $script, [timespan]$duration, [switch]$success){
	$sql = @"
INSERT INTO $schemaTable 
([Version], [Type], [Script], [Installed_On], [Installed_By], [Success], [Execution_Time]) 
VALUES
(@version, @type, @script, getdate(), @installed_by, @success, @execution_time)
"@
    $sqlParams = @{
        '@version' = $version.ToString()
        '@type' = $type
        '@script' = $script
        '@success' = $success.IsPresent
        '@installed_By' = $env:username
        '@execution_time' = $duration.TotalMilliseconds
    }
	[void] (Invoke-SqlCommand -commandText:$sql -commandParams:$sqlParams)
}

function getCurrentModelVersion() {
	$currentVersion = `
		Get-Scripts "$migrationsDir\v*" -filter:*upgrade.sql -reverseOrder:$true | 
		select-object -first:1 -expandProperty:Version
	Write-Verbose "Detected current model version as $currentVersion"
	$currentVersion
}

function runPreScripts() {
    # note simple name-based sorting here and no version stamping
    get-childitem "$migrationsDir\Pre-Deployment" -filter "*.sql" | Sort-Object -Property:Name | Invoke-SqlScriptFile
}

function runPostScripts() {
    # note simple name-based sorting here and no version stamping
    get-childitem "$migrationsDir\Post-Deployment" -filter "*.sql" | Sort-Object -Property:Name | Invoke-SqlScriptFile
}

function Invoke-MigrationAction([scriptblock]$action, $version, $type = 'Upgrade', $script){
    Write-Host "Execute $script"
    if ($pscmdlet.ShouldProcess($script, "Execute $type $script?")){
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $isSuccess = $true;
        try{
            & $action
            $stopwatch.Stop()
        }catch{
            $stopwatch.Stop()
            $isSuccess = $false
            throw;
        }finally{
            $stopwatch.Stop()
            writeSchemaVersion -version:$version -type:$type -script:$script -duration:$stopwatch.Elapsed -success:$isSuccess
        }
    }
}

function Invoke-MigrationScript($script, $version, $type){
    Invoke-MigrationAction -version:$version -type:$type -script:$script -action:{
        $script | Invoke-SqlScriptFile
    }
}

function deployFromModel($dacpac, [version]$targetVersion){
    Write-Host "Deploying from $dacpac to $serverInstance $databaseName"
    $dacpac = (Resolve-Path $dacpac).Path
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    Invoke-MigrationAction -version:$targetVersion -script:$dacpac {
    	Exec-SqlPackageDeployment $dacpac -sqlInstance:$serverInstance -databaseName:$databaseName

        # Nasty hack: deploying 'from model' can delete the versions table, may need to re-create
	    initDatabase
    }
}

function deployFromMigrations(
    [Parameter(Mandatory=$true)] [version]$from,
    [Parameter(Mandatory=$true)] [version]$to
){

    $isRollback = $to -and ($from -gt $to)
    $scriptsPath = "$migrationsDir\v*"
    
    if($isRollback){
        Write-Warning "Executing rollback $from -> $to"
        Get-Scripts $scriptsPath -filter:*rollback.sql -reverseOrder:$true | 
            ? {
                ($_.Version -gt $to) -and (!$from -or ($_.Version -le $from))
            } |
            % {
                Invoke-MigrationScript -script:$_.FullName -version:$_.Version -type:'Rollback'
            }
    } else {
        Get-Scripts $scriptsPath -filter:*upgrade.sql | 
            ? {
                ($_.Version -gt $from) -and (!$to -or ($_.Version -le $to))
            } |
            % {
                Invoke-MigrationScript -script:$_.FullName -version:$_.Version -type:'Upgrade'
            }
    }
}

# .synopsis
# Runs the migration, either from the model or from the migration scripts (or possibly both)
function runMigration(
	$fromVersion,
	$toVersion,
	[switch]$fromModel,
	[switch]$skipPreScripts,
	[switch]$skipPostScripts
){
    if(!$skipPreScripts){
        Write-Host "Execute pre-deployment scripts" -ForegroundColor:Yellow
        runPreScripts
    }

    Write-Host "Execute migrations" -ForegroundColor:Yellow
    if($fromModel){
		# run in any additional delta from the model as required (and stamp final version)
		deployFromModel $model -targetVersion:$toVersion
    }else{
        # run migrations up to and including the target version (or backwards, if rolling back)
        deployFromMigrations -from:$fromVersion -to:$toVersion
	}

    if(!$skipPostScripts){
        Write-Host "Execute post-deployment scripts" -ForegroundColor:Yellow
        runPostScripts
    }
}

# Create version table if doesn't already exist
initDatabase -allowCreate:$allowCreate

if ($fromModel -and $toVersion){
	throw "Can't specify target version when deploying from model - at present will always push latest model"
}

# Establish the version range for this release (for unspecified parameters)
if(!$fromVersion){
	$fromVersion = getCurrentSchemaVersion        
}
if(!$toVersion){
	$toVersion = getCurrentModelVersion
}

$fromVersion = expandVersionNumber $fromVersion
$toVersion = expandVersionNumber $toVersion
$noMigrationRequired = $toVersion -eq $fromVersion

if($noMigrationRequired -and (-not $force)){
	Write-Host "Migrate from $fromVersion to $toVersion - nothing to do!"
	return
}elseif($fromModel){
	Write-Host "Push model as $toVersion" -ForegroundColor:Yellow
    runMigration -toVersion:$toVersion -fromModel:$true -skipPreScripts:$skipPreScripts -skipPostScripts:$skipPostScripts

}else{
	Write-Host "Migrate from $fromVersion to $toVersion" -ForegroundColor:Yellow
	Write-Host
    # Actually perform the migration
    runMigration -fromVersion:$fromVersion -toVersion:$toVersion -skipPreScripts:$skipPreScripts -skipPostScripts:$skipPostScripts
}

# Dump out final state to console
@{
	PreScripts = (-not $skipPreScripts)
	PostScripts = (-not $skipPostScripts)
	FromVersion = $fromVersion
	ToVersion = $toVersion 
	ResultVersion = getCurrentSchemaVersion
}
