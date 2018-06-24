<#
The following variables are required as *parameters* into this script

$solution
$outputDir
$buildVerbosity
$version
$versionComment (prerelease tag)
$semVer
#>

# These are the *properties* of the build (can be overridden, but have a default)
properties {
    $solutionDir = Split-Path $solution;
    $solutionName = [IO.Path]::GetFileNameWithoutExtension($solution);
    $buildConfig = 'Debug';
    $buildTarget = 'Rebuild';
    $inTeamCity = ![String]::IsNullOrEmpty($env:TEAMCITY_VERSION);

    $programFiles32 = $env:ProgramFiles
    if (Test-Path environment::"ProgramFiles(x86)") { $programFiles32 = (gi "Env:ProgramFiles(x86)").Value };
}

TaskSetup {
    if($inTeamCity){
        "##teamcity[blockOpened name='$taskName']"
    }else{
        Write-Host "===================="
    }
}

TaskTearDown{
    if($inTeamCity){
        "##teamcity[blockClosed name='$taskName']"
    }else{
        Write-Host "--"
        Write-Host
    }
}

function EnsureFolderExists($path, [switch] $clean){
    if($clean -and (Test-Path $path)){
        Remove-Item $path -Force -Recurse;
        [void] (mkdir $path);    
    }elseif(!(Test-Path $path)){
        [void] (mkdir $path);    
    }
}

task Clean {
    EnsureFolderExists $outputDir -clean
}

task Build {
    Write-Host "$($buildTarget)ing $solution as $buildConfig"
    exec {
        # msbuild $solution /nologo /t:$buildTarget /p:DacVersion=$version /v:$buildVerbosity /p:Configuration=$buildConfig "/p:PackageSources=`"$nugetPackageSource`""
        msbuild $solution /t:$buildTarget /p:DacVersion=$version /v:$buildVerbosity /p:Configuration=$buildConfig /p:VisualStudioVersion=14.0
    }
}

task Test {

}

function Zip($source, $destination){
    Remove-Item $destination -ErrorAction:silentlycontinue
    [io.compression.zipfile]::CreateFromDirectory($source, $destination) 
}

task PackDatabaseProjects {
    Add-Type -assembly "system.io.compression.filesystem"
    $dbProjects = `
        Get-VsSolutionProjects $solution |
        ? { $_.FullName.EndsWith(".sqlproj") } |
        select-object -expandProperty:FullName

    foreach($projectPath in $dbProjects){
        # Assume default output directory conventions have not been fiddled with
        $projectDir = Split-Path $projectPath
        $projectName = [IO.Path]::GetFileNameWithoutExtension($projectPath)
        $projectOutDir = Join-Path $projectDir "bin\$buildConfig"
        $projectArtefactsPattern = "$projectOutDir\$projectName.*"
        $destinationPath = "$outputDir\$projectName"

        Write-Host "Packing $projectName"
        Write-Host "Pack $projectArtefactsPattern"
        EnsureFolderExists -clean "$outputDir\$projectName"
        copy $projectArtefactsPattern $destinationPath

        # Zip the output folder
        Zip $destinationPath "$outputDir\$projectName.zip"

        # Zip the migrations
        if(Test-Path "$projectDir\migrations"){
            Zip $projectDir\migrations "$outputDir\$projectName.migrations.zip"
        }
    }
}

task Pack -depends:PackDatabaseProjects {
    # remember to use $semVer for pack operation
}

task CI -depends:Clean,Build,Test,Pack
task default -depends:CI
task full -depends:CI # for now