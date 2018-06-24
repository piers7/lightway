[CmdLetBinding()]
param(
    [string[]] $taskList,
    $solution = $(Get-ChildItem "*.sln" | select-object -first:1),
    [int]$buildNumber = $(if ($env:BUILD_NUMBER) {$env:BUILD_NUMBER} else {0}),
    $preReleaseTag = $env:computername,
    $commit = '',
    [hashtable] $properties = @{}
)

$ErrorActionPreference = 'stop';
$scriptDir = $psScriptRoot # Split-Path $MyInvocation.MyCommand.Path;
$solutionDir = Split-Path $solution
$buildFile = Join-Path $scriptDir '.\build\build.psake.ps1'
$isVerbose = $VerbosePreference -ne 'SilentlyContinue'
$buildVerbosity = if ($isVerbose) { 'normal' } else { 'minimal'}

# Import PINK helper module (https://github.com/piers7/pink/)
import-module $scriptDir\build\pink-build.psm1

# .synopsis cleanup the tag name, removing branch paths, bad chars and truncating to x chars (on the right)
function cleanupTagName($length, $tagName){
    $tagName = $tagName -split '/' | select-object -last:1
    $tagName = $tagName -replace '-',''
    if($tagName.length -gt $length){
        $tagName = $tagName.Substring($tagName.length - $length, $length)
    }
    $tagName
}

# Determine version number
$storedVersion = `
    if(Test-Path $scriptDir\Version.txt){
        get-content $scriptDir\Version.txt
    }else{
        "0.0.0"
    }
$version = [Version]::Parse($storedVersion)
$version = new-object Version (
        $version.Major,
        $version.Minor,
        $version.Build,
        $buildNumber
    )
$semVer = `
    switch -wildcard ($preReleaseTag){
        "release/*" { $version.ToString(3)}
        "master" { $version.ToString(3) }
        "" { $version.ToString(3) }
        $null { $version.ToString(3) }
        default {
            # handle other branch names by appending into semver pre-release tag
            $preReleaseTag = switch ($preReleaseTag) {
                "develop" { "pre" }
                default { cleanupTagName 14 $preReleaseTag } # cleanup/handle branch paths nicely
            }
            "{0}-{1}_{2:00000}" -f ($version.ToString(3)),$preReleaseTag,$buildNumber
            break
        }
    }

Write-Host "Build $solution (v$semVer)"
Write-Host "##teamcity[buildNumber '$semVer']"
Set-TeamCityParameter -name:'version' -value:$version
Set-TeamCityParameter -name:'semVer' -value:$semVer

# Actually do the build
& "$scriptDir\build\psake-4.7.0\psake.ps1" -buildFile:$buildFile -nologo -taskList:$taskList -parameters:@{
    solution=$solution;
    outputDir=(Join-Path $solutionDir '..\bin');
    buildVerbosity = $buildVerbosity;

    version=$version;
    versionComment=$preReleaseTag;
    semVer=$semVer;
} -properties:$properties;

if(!$psake.build_success){
    $error[0].ScriptStackTrace
    throw 'Build failed';
}
