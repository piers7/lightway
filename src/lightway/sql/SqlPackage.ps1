$programFiles32 = $env:ProgramFiles
if (Test-Path environment::"ProgramFiles(x86)") { $programFiles32 = (gi "Env:ProgramFiles(x86)").Value };

# .synopsis Locates sqlPackage.exe on the local machine (either in path, or well-known locations)
function Get-SqlPackageExe(){
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
			"$programFiles32\Microsoft Visual Studio\2017\*\Common7\IDE\Extensions\Microsoft\SQLDB\DAC\130\sqlPackage.exe"	,
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

# .synopsis Creates a new migration script, based on a source and destination dacpack
function Create-SqlPackageMigration($source, $target, $outputPath, $databaseName, $parameters){
	Write-Verbose "Create migration: $source -> $target => $outputPath"
	$sqlPackager = Get-SqlPackageExe
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

function Exec-SqlPackageDeployment($sourceModel, $sqlInstance, $databaseName, $parameters, $scriptTo, [switch]$force){
	Write-Verbose "Deploy database: $sourceModel -> $targetInstance $databaseName"
	$sqlPackager = Get-SqlPackageExe
	# See <https://msdn.microsoft.com/library/hh550080(vs.103).aspx#Script Parameters and Properties>

    if($scriptTo){
        $action = 'Script';
    }else{
        $action = 'Publish';
    }

    $sqlPackagerArgs = @(
        "/Action:$action"
        ,"/TargetServerName:$sqlInstance"
        ,"/TargetDatabaseName:$databaseName"
        ,"/SourceFile:$sourceModel"
        #,"/Profile:$profile"
        ,"/p:DeployDatabaseInSingleUserMode=False"
        ,"/p:CreateNewDatabase=$force"
        #,"/p:RegisterDataTierApplication=$false"
        #,"/p:BlockWhenDriftDetected=$blockDrift"
        ,"/p:UnmodifiableObjectWarnings=False"
    );

    if($scriptTo){
        $scriptFile = Join-Path $scriptDir ("{0}_{1}.sql" -f $sqlInstance,$databaseName);
        $sqlPackagerArgs = $sqlPackagerArgs + (,"/OutputPath:$scriptFile");
    }
   
	if($parameters){
		$extras = @(
			$parameters.GetEnumerator() |
			% { "/p:{0}={1}" -f $_.Key,$_.Value}
		)
		$sqlPackagerArgs += $extras		
	}

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