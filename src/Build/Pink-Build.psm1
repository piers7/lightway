
# begin Build-SSASProject.ps1

<#
.Synopsis
Builds a .dwproj into an .asdatabase

.Description
Builds a Visual Studio / BIDS Analysis Services project into a .asdatabase file,
as would happen in devenv during build time.

Based on SSASHelper code lifted from Analysis Services project on codeplex
http://sqlsrvanalysissrvcs.codeplex.com/SourceControl/latest#SsasHelper/SsasHelper/ProjectHelper.cs
Thanks DDarden - I was hoping it was wasn't that hard
#>
function Build-SSASProject {
[CmdLetBinding()]
param(
    [Parameter(Mandatory=$true)]
    $projectPath,
    # [Parameter(Mandatory=$true)]
    $outputDir,
    $version = '11.0.0.0'
)

$ErrorActionPreference = 'stop';
try{
    Add-Type -AssemblyName:"Microsoft.AnalysisServices, Version=$version, Culture=neutral, PublicKeyToken=89845dcd8080cc91" -ErrorAction:Stop;
}catch{
    Write-Warning "Failed to load SSAS assemblies - is AMO installed?"
    throw;
}

$ns = @{
    AS = 'http://schemas.microsoft.com/analysisservices/2003/engine';
}

$database = New-Object Microsoft.AnalysisServices.Database
$projectPath = (Resolve-Path $projectPath).Path;
$projectDir = Split-Path $projectPath -Parent;
$projectName = [IO.Path]::GetFileNameWithoutExtension($projectPath);
if(!$outputDir){
    $outputDir = Join-Path $projectDir 'bin';
}

Write-Host "Building $projectPath to $outputDir"

# Load the SSAS Project File
$projectXml = New-Object System.Xml.XmlDocument
$projectXml.Load($projectPath);

function DeserializeProjectItems($xpath, $objectType){
    Write-Verbose "Deserialise $objectType";
    Select-Xml -Xml:$projectXml -XPath:$xpath | % {
        $path = Join-Path $projectDir $_.Node.InnerText;
        DeserializePathAs $path $objectType; # returns item to pipeline
    }
}

function DeserializePathAs($path, $objectType){
    $reader = New-Object System.Xml.XmlTextReader $path;
    try{
        $majorObject = New-Object $objectType;
        [Microsoft.AnalysisServices.Utils]::Deserialize($reader, $majorObject); # returns item to pipeline
    }finally{
        $reader.Close();
    }
}

# Deserialize the Database file onto the Database object
$databaseRelPath = $projectXml.SelectSingleNode("//Database/FullPath").InnerText;
$databasePath = Join-Path $projectDir $databaseRelPath;
$reader = New-Object System.Xml.XmlTextReader $databasePath;
[void] [Microsoft.AnalysisServices.Utils]::Deserialize($reader, $database);

# And all the other project items
DeserializeProjectItems '//DataSources/ProjectItem/FullPath' 'Microsoft.AnalysisServices.RelationalDataSource' | % {
    [void] $database.DataSources.Add($_);
}
DeserializeProjectItems '//DataSourceViews/ProjectItem/FullPath' 'Microsoft.AnalysisServices.DataSourceView' | % {
    [void] $database.DataSourceViews.Add($_);
}
DeserializeProjectItems '//Roles/ProjectItem/FullPath' 'Microsoft.AnalysisServices.Role' | % {
    [void] $database.Roles.Add($_);
}
DeserializeProjectItems '//Dimensions/ProjectItem/FullPath' 'Microsoft.AnalysisServices.Dimension' | % {
    [void] $database.Dimensions.Add($_);
}
DeserializeProjectItems '//MiningModels/ProjectItem/FullPath' 'Microsoft.AnalysisServices.MiningModel' | % {
    [void] $database.MiningModels.Add($_);
}

# When deserializing cube we need to account for dependencies (partitions)
# This is cribbed this off of DDarden's code on codeplex
Write-Verbose "Deserialise Microsoft.AnalysisServices.Cube";
Select-Xml -Xml:$projectXml -XPath:'//Cubes/ProjectItem/FullPath' | % {
    $path = Join-Path $projectDir $_.Node.InnerText;

    $cube = DeserializePathAs $path 'Microsoft.AnalysisServices.Cube';
    [void] $database.Cubes.Add($cube);

    $dependencies = $_.Node.SelectNodes('../Dependencies/ProjectItem/FullPath');
    foreach($dependency in $dependencies){
        $path = Join-Path $projectDir $dependency.InnerText;
        $partitionXml = (Select-Xml -Path:$path -XPath:/).Node;

        # .partitions file as loaded doesn't have 'Name' node populated for MeasureGroup
        # need to fix that for deserialization to work
        # NB: don't think we care what name we use, so just use ID
        Select-Xml -Xml:$partitionXml -XPath://AS:MeasureGroup/AS:ID -Namespace:$ns |
            % { 
                $idNode = $_.Node;
                $nameNode = $idNode.ParentNode.ChildNodes | ? { $_.Name -eq 'Name' } | Select-Object -First:1;
                if(!$nameNode){
                    $nameNode = $idNode.OwnerDocument.CreateElement('Name', $ns.AS);
                    $nameNode.InnerText = $idNode.InnerText;
                    [void] $idNode.ParentNode.InsertAfter($nameNode, $idNode);
                }
            }

        # now we can deserialise this 'cube'
        $reader = New-Object System.Xml.XmlNodeReader $partitionXml;
        $tempCube = New-Object 'Microsoft.AnalysisServices.Cube';
        $tempCube = [Microsoft.AnalysisServices.Utils]::Deserialize($reader, $tempCube);

        # ..and then copy the partitions from this 'cube' into the original cube
        foreach($tempMeasureGroup in $tempCube.MeasureGroups){
            $measureGroup = $cube.MeasureGroups.Find($tempMeasureGroup.ID);
            $tempPartitions = @($tempMeasureGroup.Partitions);
            $tempPartitions | % { [void] $measureGroup.Partitions.Add($_) };
        }
    }
}

# finally, spit out the output .asdatabase etc...
if(!(Test-Path $outputDir)){
    [void] (mkdir $outputDir)
}
$outputDir = (Resolve-Path $outputDir).Path;

$writer = New-Object System.Xml.XmlTextWriter "$outputDir\$projectName.asdatabase",([System.Text.Encoding]::UTF8)
$writer.Formatting = 'Indented';
[Microsoft.AnalysisServices.Utils]::Serialize($writer, $database, $false);
$writer.Close();

# Also need to copy over 'Miscellaneous' project items into the output folder
# (basically treat them as 'Content' items would be for normal msbuild projects)
pushd $projectDir;
try{
    Select-Xml -Xml:$projectXml -XPath:'//Miscellaneous/ProjectItem' | % { 
        $source = Resolve-Path $_.Node.FullPath; # might be relative to project    
        Copy-Item $source $outputDir -Force -Verbose:($VerbosePreference -eq 'Continue');
    }
}finally{
    popd;
}

} # end Build-SSASProject
Export-ModuleMember -function Build-SSASProject;


# begin Get-MsBuildPath.ps1

<#
.Synopsis
Locates the path to MSBuild, given a framework version (or uses the highest installed)

.Notes
As per VS 2013, MSBuild is be bundled with Visual Studio, not the .Net Framework.
See http://blogs.msdn.com/b/visualstudio/archive/2013/07/24/msbuild-is-now-part-of-visual-studio.aspx
However the ToolLocationHelper class (to find it) has *also* moved into VS2013
https://msdn.microsoft.com/en-us/library/microsoft.build.utilities.toollocationhelper(v=vs.121).aspx
... so bit of a chicken-and-egg issue

#>
function Get-MsBuildPath {
[CmdLetBinding()]
param(
    # Specify the framework version, or leave blank default to highest located
    $frameworkVersion, 

    # Force using 32 bit version of MSBuild
    [switch] $x86
)

# very simple implementation that just uses embedded version numbers
function NumericalSort(){
    $input | ? { $_ -match '^v(\d+(\.\d+))?' } | % { 
        New-Object -TypeName:PSObject -Property:@{
            SortKey = $Matches[1] -as [Float];
            Value = $_
        }
    } | Sort SortKey | Select-Object -ExpandProperty:Value
}

# Resolve framework directory (for MsBuild)
$frameworkKey = Get-Item "hklm:\software\microsoft\.netframework"
$frameworkDir = $frameworkKey.GetValue('InstallRoot');
if(!$frameworkVersion){
    $frameworkVersion = ($frameworkKey.GetSubKeyNames() | NumericalSort | Select-Object -Last:1).Substring(1);
}
if($x86){
    $frameworkDir = $frameworkDir -replace 'Framework64','Framework';
}
$msbuild = Resolve-Path "$frameworkDir\v$frameworkVersion\MSBuild.exe";

Write-Verbose "Using MsBuild from $msbuild";
$msbuild;

} # end Get-MsBuildPath
Export-ModuleMember -function Get-MsBuildPath;


# begin Get-TeamCityChanges.ps1

<#
.synopsis
Extracts checkin comments from TeamCity's REST api for a particular build (normally the current one)
#>
function Get-TeamCityChanges {
[CmdLetBinding()]
param(
    [Parameter(Mandatory=$true)]
    $buildId,
    [Parameter(Mandatory=$true)]
    $serverUri = 'http://teamcity:8070',
    [switch] $asMarkdown,
    [switch] $noProxy
)

function Load-Xml($uri){
    if(Get-Command Invoke-WebRequest -ErrorAction:SilentlyContinue){
        $response = Invoke-WebRequest -Uri:$uri;
        [xml]($response.Content);
    }else{
        # Invoke-WebRequest not available on PS 2
        $client = New-Object System.Net.WebClient
        if($noProxy){
	        $client.Proxy = $null;
        }
        if($client.Proxy){
	        Write-Verbose "Retrieving $uri using proxy $($client.Proxy.GetProxy($uri))";
        }else{
	        Write-Verbose "Retrieving $uri";
        }
        $response = $client.DownloadString($uri);
        [xml]$response;
    }
}

# Nice non-iterative version as per http://stackoverflow.com/a/25515487/26167
$changes = Load-Xml "$serverUri/guestAuth/app/rest/changes?locator=build:(id:$buildId)&fields=count,change:(version,date,username,comment)"
$changesParsed = $changes.SelectNodes('//change') | Select-Object Version,UserName,@{Name='date';Expression={[DateTime]::ParseExact($_.date, 'yyyyMMddTHHmmsszzzz', $null)}},Comment

if(!$asMarkdown){
    $changesParsed
}else{
    "# Release Notes";
    ""
    $changesParsed | % { "  - [{0:yyyyMMdd}] {1} ({2})" -f $_.date,$_.comment,$_.username }
    ""
    "[More Details]($serverUri/viewLog.html?buildId=$buildId)"
}

} # end Get-TeamCityChanges
Export-ModuleMember -function Get-TeamCityChanges;


# begin Get-TeamCityProperties.ps1

<#
.synopsis
Returns a hashtable of TeamCity system build properties for the current build

.description
Grabs build properties from the file specified by %TEAMCITY_BUILD_PROPERTIES_FILE%,
and returns them as a hashtable.
If not running under TeamCity an empty hashtable is returned.
#>
function Get-TeamCityProperties {
[CmdLetBinding()]
param(
    # Path to the .properties file for this build (determined automatically)
    $file = $env:TEAMCITY_BUILD_PROPERTIES_FILE,

    # Whether TeamCity properties should be resolved (eval'd) as powershell expressions if they start with $
    # This enables objects to be passed in (eg arrays) that would otherwise just be strings
    [switch] $resolveExpressions
)

$buildProperties = @{};
if($file){
    Write-Verbose "Loading TeamCity properties from $file"
    $file = (Resolve-Path $file).Path;

    if([IO.Path]::GetExtension($file) -eq '.xml'){
        $buildPropertiesXml = New-Object System.Xml.XmlDocument
        $buildPropertiesXml.XmlResolver = $null; # force the DTD not to be tested
        $buildPropertiesXml.Load($file);

        $buildPropertiesRaw = $buildPropertiesXml.SelectNodes("//entry") | Select-Object Key,@{Name='Value';Expression={$_.'#text'}}
    }else{
        # The XML file doesn't seem to have half the properties in it
        # so resorting to bludgery to get them out of the text file version
        $buildPropertiesRaw = Get-Content $file | % { 
            $parts = $_ -split '=',2;
            New-Object PSObject -Property:@{
                Key = $parts[0];
                Value = [Regex]::Unescape($parts[1]); # why everything is escaped in raw file I have no idea
            }
        }
    }

    foreach($entry in $buildPropertiesRaw){
        $key = $entry.key;
        $value = $entry.value;
        if($value -and $value.StartsWith('$') -and $resolveExpressions){
            # This allows us to use PowerShell expression syntax to get strong-types into PowerShell
            $value = Invoke-Expression $value;
        }

        Write-Verbose "`tLoaded $key = $value";
        $buildProperties[$key] = $value;
    }
}
$buildProperties;

} # end Get-TeamCityProperties
Export-ModuleMember -function Get-TeamCityProperties;


# begin Get-VSProjectDetails.ps1

<#
.synopsis
Get Visual Studio project metadata from one or more project files

.description
Takes an input stream of FileInfo's and returns a custom object with project metadata
Use this to easily extract lists of projects by version etc...
.Example
Get-VSProjectDetails | ? { $_.TargetFrameworkVersion -ne 'v3.5' }

#>
function Get-VSProjectDetails {
param(
    $buildConfig = 'Debug',
    $platformConfig = 'Any CPU',
    $project
)
begin {
    $ErrorActionPreference = 'stop';

    # Need to ensure this condition is treated literally
    $condition = '{0}|{1}' -f $buildConfig,($platformConfig -replace ' ','')
    $condition = [system.text.regularexpressions.regex]::Escape($condition)
    $projectXml = new-object system.xml.xmldocument;


    function process-item($item){
        if($item.FullName){
            $projectPath = $item.FullName;
        }else{
            $projectPath = $item;
        }
        $projectDir = Split-Path $projectPath;
		$projectName = [IO.Path]::GetFileNameWithoutExtension($projectPath);
        
		[void] $projectXml.Load($projectPath);
        
        $projectGlobals = $projectXml.SelectSingleNode('//*[local-name() = "PropertyGroup"]/*[local-name()="OutputType"]/..');

        $propertyGroups = $projectXml.SelectNodes("//*[local-name() = 'PropertyGroup']")
        $matchedConfig = ($propertyGroups | ? { $_.Condition -match $condition }) | Select-Object -First:1;
        if($matchedConfig){
            $outputRelPath = $matchedConfig.OutputPath
        }else{
            $outputRelPath = '??'
        }
        switch -wildcard ($projectGlobals.OutputType){
            '*exe' {
                $extension = '.exe';
                break;
             } 
             default {
                $extension = '.dll'
                break;
             }
        }
        $outputPath = join-path $projectDir $outputRelPath
        if($outputRelPath -match '\$\('){
            $outputPath = $outputRelPath
        }
        $outputItem = (join-path $outputPath $projectGlobals.AssemblyName) + $extension

        $projectDetails = New-Object PSObject -Property:@{
            ProjectName = $projectName;
            Directory = $projectDir;
            # Assembly = $projectGlobals.AssemblyName;
            # Namespace = $projectGlobals.RootNamespace;
            # TargetFrameworkVersion = $projectGlobals.TargetFrameworkVersion;
            FullName = $projectPath;
            OutputPath = $outputRelPath;
            TargetPath = $outputItem;
            Item = $projectXml;
        }
        
        # Add all child -elements- directly
        foreach($element in $projectGlobals.SelectNodes('*')){
            Add-Member -InputObject:$projectDetails -MemberType:NoteProperty -Name:$element.LocalName -Value:$element.InnerText;
        }
        
        # Output to pipeline
        $projectDetails;    
    }
}
process {
	if ($_){
        process-item $_;
	}
}
end{
    if($project){
        process-item $project;
    }
}

} # end Get-VSProjectDetails
Export-ModuleMember -function Get-VSProjectDetails;


# begin Get-VSProjectItems.ps1

<#
.synopsis
Enumerates the items within a Visual Studio project file, and provides their full path

.description
TODO: Not sure why this isn't using Select-Xml
#> 
function Get-VSProjectItems {
param(
    [Parameter(Mandatory=$true)] $project,
    [string]$xpath = "//ProjectItem"
)

$ErrorActionPreference = 'stop';

$projXml = new-object system.xml.xmldocument
$projXml.Load($project);
$projectPath = Split-Path $project

$projXml.SelectNodes($xpath) |
    % { 
        $projectItem = $_;
        $fullName = join-path $projectPath $projectItem.Name;
        Add-Member -InputObject:$projectItem -PassThru -Name:FullPath -Value:$fullName -MemberType:NoteProperty -Force;
    }

} # end Get-VSProjectItems
Export-ModuleMember -function Get-VSProjectItems;


# begin Get-VSSolutionProjects.ps1

<#
.Synopsis
Extracts the project-type items from a Visual Studio solution file (.sln)
#>
function Get-VSSolutionProjects {
param(
    [Parameter(Mandatory=$true)] $solution,
    [string]$name, # optional filter parameter
    [string]$type, # optional filter parameter
    [string]$kind  # optional filter parameter
)

$ErrorActionPreference = 'stop';

$projectNodeGuid = '{FAE04EC0-301F-11D3-BF4B-00C04F79EFBC}';
$projectItemPattern = 'Project\("([^"]+)"\)\s*=\s*"([^"]+)"\s*,\s*"([^"]+)"\s*,\s*"([^"]+)"';
$solutionDir = Split-Path $solution;

if($kind -and $kind[0] -ne '{'){
    # Ensure that GUIDS passed on the command line are handled appropriately
    # (PowerShell turns these into strings but doesn't include the {} )
    $kind = "{$kind}";
}

Get-Content $solution | % {
    $line = $_;
    $matches = [System.Text.RegularExpressions.Regex]::Matches($line, $projectItemPattern);
    foreach($match in $matches){
        Write-Verbose $match.Value;
        
        $projectKind = $match.Groups[1].Value;
        $projectType = & {
            switch($projectKind) {
                '{FAE04EC0-301F-11D3-BF4B-00C04F79EFBC}' { 'C#'; break; };     
            }
        }
               
        New-Object PSObject -Property:@{
            Name = $match.Groups[2].Value;
            Kind = $projectKind;
            Guid = $match.Groups[4].Value;
            RelPath = $match.Groups[3].Value;
            FullName = (Join-Path $solutionDir ($match.Groups[3].Value));
            Type = $projectType;
        }
    }
} | ? { 
    # Filter output if required
    if($name -and $name -ne $_.Name){
        $false;
    }elseif($type -and $type -ne $_.Type){
        $false;
    }elseif($kind -and $kind -ne $_.Kind){
        $false;    
    }else{
        $true;
    }
}

} # end Get-VSSolutionProjects
Export-ModuleMember -function Get-VSSolutionProjects;


# begin Pack-SSRSProject.ps1

<#
.synopsis
Packs a SSRS project using xcopy / Octopus Deploy conventions
#>
function Pack-SSRSProject {
[CmdLetBinding()]
param(
    [Parameter(Mandatory=$true)]
    $projectPath,
    [Parameter(Mandatory=$true)]
    $outputDir,
    [Parameter(Mandatory=$true)]
    $semVer,

    $nugetExe = '..\.nuget\nuget.exe',
    $nuspec,
    [switch] $forceUseConventions
)

$ErrorActionPreference = 'stop';


function Add-ChildElement($parent, $name, [hashtable]$attributes){
    $child = $parent.OwnerDocument.CreateElement($name);
    foreach($item in $attributes.GetEnumerator()){
        $child.SetAttribute($item.Key, $item.Value);
    }
    $parent.AppendChild($child);
}

function nuget-pack($nuspec, $outputDir, $semVer, $baseDir, [hashtable]$properties){
    $propertiesString = '';
    if($properties){
        $propertiesString = ($properties.GetEnumerator() | % { '{0}={1}' -f $_.Key,$_.Value }) -join ';'
    }
    & $nugetexe pack $nuspec -o $outputDir -Version $semVer -basePath $baseDir -NoPackageAnalysis -NonInteractive -Properties $propertiesString
    if($LASTEXITCODE -gt 0){
        throw "Failed with exit code $LASTEXITCODE";
    }
}


$outputDir = (Resolve-Path $outputDir).Path;
$projectPath = (Resolve-Path $projectPath).Path;
$nugetExe = (Resolve-Path $nugetExe).Path;

if(-not $nuspec){
    $nuspec = [io.path]::ChangeExtension($projectPath, '.nuspec');
    Write-Verbose "Inferring nuget spec through convention at '$nuspec'"
}else{
    $nuspec = (Resolve-Path $nuspec).Path;
}

$projectDir = Split-Path $projectPath;
$projectName = [IO.Path]::GetFileNameWithoutExtension($projectPath);
$nugetProperties = @{
    id = $projectName;
    description = 'SSRS project'
};

Write-Host "Packing SSRS project '$projectName'";
Write-Host "... Using $nuspec";

$specXml = New-Object System.Xml.XmlDocument
$specXml.Load($nuspec)
$files = $specXml.SelectSingleNode("//files");

if($files -and !$forceUseConventions){
    # just pack what's there
    $baseDir = Split-Path $nuspec;
    nuget-pack $nuspec $outputDir $semVer $projectDir;
    return;
}elseif($files){
    Write-Host "... Content conventions will be applied, existing FILES element will be ignored"
    $files.ParentNode.RemoveChild($files);
}else{
    Write-Host "... Content conventions will be applied - nuspec lists no files"
}
$files = $specXml.DocumentElement.AppendChild($specXml.CreateElement('files'));

# Create files element and populate from project 'Content' items
Select-Xml -Path:$projectPath -XPath:'//*[self::ProjectItem or self::ProjectResourceItem]' |
    Select-Object -ExpandProperty:Node |
    % {
        $contentSrc = $_.FullPath;
        $target = ".\" + (Split-Path $contentSrc);
        Write-Verbose "Adding content file $contentSrc"
        [void]( Add-ChildElement $files 'file' @{ src=$contentSrc; target=$target } )
    }

$tempSpec = [io.Path]::ChangeExtension($nuspec, '.generated.nuspec');
$specXml.Save($tempSpec);

nuget-pack $tempSpec $outputDir $semVer $projectDir -properties:$nugetProperties;

} # end Pack-SSRSProject
Export-ModuleMember -function Pack-SSRSProject;


# begin Pack-VSProject.ps1

<#
.synopsis
Packs a Visual Studio Project to a xcopy / Octopus Deploy style nuget

.description
It's easier to use OctoPack, but that doesn't support many BI project types
#>
function Pack-VSProject {
[CmdLetBinding()]
param(
    [Parameter(Mandatory=$true)]
    $projectPath,
    [Parameter(Mandatory=$true)]
    $outputDir,
    [Parameter(Mandatory=$true)]
    $semVer,

    $nugetExe = '..\.nuget\nuget.exe',
    $nuspec
)

$ErrorActionPreference = 'stop';


function Add-ChildElement($parent, $name, [hashtable]$attributes){
    $child = $parent.OwnerDocument.CreateElement($name);
    foreach($item in $attributes.GetEnumerator()){
        $child.SetAttribute($item.Key, $item.Value);
    }
    $parent.AppendChild($child);
}

# .synopsis
# Packs a website using xcopy / Octopus Deploy conventions
# For this we re-write the spec file on the fly to include project Content
# if the Files element doesn't already exist
function Pack-Website($projectPath, $nuspec, [switch] $forceUseConventions, [switch] $ignoreWebTransforms){
    $projectName = $(Split-Path -Leaf $projectPath);
    $projectDir = Split-Path $projectPath;

    Write-Host "Packing $projectName as Website";
    $specXml = New-Object System.Xml.XmlDocument
    $specXml.Load($nuspec)
    $files = $specXml.SelectSingleNode("//files");

    if($files -and !$forceUseConventions){
        # just pack what's there
        nuget-pack $nuspec $outputDir $semVer $projectDir;
        return;
    }elseif($files){
        $files.ParentNode.RemoveChild($files);
    }

    # Create files element and populate from project 'Content' items
    Write-Verbose "Using project-content based convention for $projectName"
    $files = $specXml.DocumentElement.AppendChild($specXml.CreateElement('files'));
    $ns = @{
        msb = 'http://schemas.microsoft.com/developer/msbuild/2003';
    }
    Select-Xml -Path:$projectPath -XPath:'//msb:Content' -Namespace:$ns | 
        % {
            $contentSrc = $_.Node.GetAttribute('Include');
            $target = ".\" + (Split-Path $contentSrc);
            Write-Verbose "Adding content file $contentSrc"
            [void]( Add-ChildElement $files 'file' @{ src=$contentSrc; target=$target } )
        }

    [void]( Add-ChildElement $files 'file' @{ src="bin\**\*"; target=".\bin" } )
    if(!$ignoreWebTransforms){
        [void]( Add-ChildElement $files 'file' @{ src="Web.*.config"; target=".\" } )
    }

    $tempSpec = [io.Path]::ChangeExtension($nuspec, '.generated.nuspec');
    $specXml.Save($tempSpec);

    nuget-pack $tempSpec $outputDir $semVer $projectDir;
}

function Pack-ProjectDefault($projectPath, $nuspec){
    # Default behaviour is to just pack the spec as-is
    Write-Host "Packing $(Split-Path -Leaf $projectPath) as default";
    $baseDir = Split-Path $nuspec;

    nuget-pack $nuspec $outputDir $semVer $baseDir;
}


function nuget-pack($nuspec, $outputDir, $semVer, $baseDir, [hashtable]$properties){
    if($properties){
        $propertiesString = ($properties.GetEnumerator() | % { '{0}={1}' -f $_.Key,$_.Value }) -join ';'
    }else{
        $propertiesString = "Foo=Bar"
    }
    & $nugetexe pack $nuspec -o $outputDir -Version $semVer -basePath $baseDir -NoPackageAnalysis -NonInteractive -Properties $propertiesString
    if($LASTEXITCODE -gt 0){
        throw "Failed with exit code $LASTEXITCODE";
    }
}


$outputDir = (Resolve-Path $outputDir).Path;
$projectPath = (Resolve-Path $projectPath).Path;
$nugetExe = (Resolve-Path $nugetExe).Path;

if(-not $nuspec){
    $nuspec = [io.path]::ChangeExtension($projectPath, '.nuspec');
    Write-Verbose "Inferring nuget spec through convention at '$nuspec'"
}else{
    $nuspec = (Resolve-Path $nuspec).Path;
}

$projectDir = Split-Path $projectPath;
if(Test-Path "$projectDir\web.config"){
    Pack-Website $projectPath $nuspec;
}else{
    Pack-ProjectDefault $projectPath $nuspec;
}

} # end Pack-VSProject
Export-ModuleMember -function Pack-VSProject;


# begin Pack-VSWebSite.ps1

<#
.synopsis
Packs a Visual Studio Web Site project to a xcopy / Octopus Deploy style nuget.

.description
If <files> element present in nuspec is missing (or -forceUseConventions is passed)
then conventions are used to add all project Content to the nuget.
#>
function Pack-VSWebSite {
[CmdLetBinding()]
param(
    [Parameter(Mandatory=$true)]
    $projectPath,
    [Parameter(Mandatory=$true)]
    $outputDir,
    [Parameter(Mandatory=$true)]
    $semVer,

    $nugetExe = '..\.nuget\nuget.exe',

    # Path to the nuspec if not in default location (next to project file)
    $nuspec,

    # Forces ignoring existing content in nuspec, and using conventions from project file instead
    [switch]$forceUseConventions,
    # If set, web config transform files are excluded
    [switch]$ignoreWebTransforms
)

$ErrorActionPreference = 'stop';


function Add-ChildElement($parent, $name, [hashtable]$attributes){
    $child = $parent.OwnerDocument.CreateElement($name);
    foreach($item in $attributes.GetEnumerator()){
        $child.SetAttribute($item.Key, $item.Value);
    }
    $parent.AppendChild($child);
}

function nuget-pack($nuspec, $outputDir, $semVer, $baseDir, [hashtable]$properties){
    if($properties){
        $propertiesString = ($properties.GetEnumerator() | % { '{0}={1}' -f $_.Key,$_.Value }) -join ';'
    }else{
        $propertiesString = "Foo=Bar"
    }
    & $nugetexe pack $nuspec -o $outputDir -Version $semVer -basePath $baseDir -NoPackageAnalysis -NonInteractive -Properties $propertiesString
    if($LASTEXITCODE -gt 0){
        throw "Failed with exit code $LASTEXITCODE";
    }
}


$outputDir = (Resolve-Path $outputDir).Path;
$projectPath = (Resolve-Path $projectPath).Path;
$nugetExe = (Resolve-Path $nugetExe).Path;

if(-not $nuspec){
    $nuspec = [io.path]::ChangeExtension($projectPath, '.nuspec');
    Write-Verbose "Inferring nuget spec through convention at '$nuspec'"
}else{
    $nuspec = (Resolve-Path $nuspec).Path;
}

$projectName = $(Split-Path -Leaf $projectPath);
$projectDir = Split-Path $projectPath;

Write-Host "Packing $projectName as Website";
$specXml = New-Object System.Xml.XmlDocument
$specXml.Load($nuspec)
$files = $specXml.SelectSingleNode("//files");

if($files -and !$forceUseConventions){
    # just pack what's there
    nuget-pack $nuspec $outputDir $semVer $projectDir;
    return;
}elseif($files){
    $files.ParentNode.RemoveChild($files);
}

# Create files element and populate from project 'Content' items
Write-Verbose "Using project-content based convention for $projectName"
$files = $specXml.DocumentElement.AppendChild($specXml.CreateElement('files'));
$ns = @{
    msb = 'http://schemas.microsoft.com/developer/msbuild/2003';
}
Select-Xml -Path:$projectPath -XPath:'//msb:Content' -Namespace:$ns | 
    % {
        $contentSrc = $_.Node.GetAttribute('Include');
        $target = ".\" + (Split-Path $contentSrc);
        Write-Verbose "Adding content file $contentSrc"
        [void]( Add-ChildElement $files 'file' @{ src=$contentSrc; target=$target } )
    }

[void]( Add-ChildElement $files 'file' @{ src="bin\**\*"; target=".\bin" } )
if(!$ignoreWebTransforms){
    [void]( Add-ChildElement $files 'file' @{ src="Web.*.config"; target=".\" } )
}

$tempSpec = [io.Path]::ChangeExtension($nuspec, '.generated.nuspec');
$specXml.Save($tempSpec);

nuget-pack $tempSpec $outputDir $semVer $projectDir;

} # end Pack-VSWebSite
Export-ModuleMember -function Pack-VSWebSite;


# begin Set-VersionNumber.ps1

<#
.synopsis
Stamps a version number into the input files suppled on the pipeline.

.description
The version number is stamped in in different ways depending on the file type
(wix, nuspec, assemblyinfo etc...)
Since System.Version can't handle wildcards, no validation on the version string
is performed. It is your responsibility to provide a valid version string for the file types provided.

Read-only files are ignored, unless force is specified. If operating under TFS, check the files out first
#>
function Set-VersionNumber {
param(
    [Parameter(Mandatory=$true)] [string]
    $version,

    $fileVersion = $version,
    $informationalVersion = $version,

    [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
    [IO.FileInfo[]] $files,

    [switch] $force # if set, version numbers will be set in read-only files. For TFS, checkout first instead of this
)

$programFiles32 = $env:ProgramFiles
if (test-path environment::"ProgramFiles(x86)") { $programFiles32 = (gi "Env:ProgramFiles(x86)").Value };

$ErrorActionPreference = "stop";
# $scriptDir = if($PSScriptRoot) { $PSScriptRoot } else { Split-Path (Convert-Path $myinvocation.MyCommand.Path) };

function EnsureWritable([io.fileinfo]$file){
    if(!$file.IsReadOnly) { return $true; }
    if($force){
        $file.IsReadOnly = $false;
        return $true;
    }else{
        write-warning "Skipping $file as write protected";
        return $false;
    }
}

# .Synopsis
# Sets the version number within an assemblyinfo file
function Set-AssemblyInfoVersion($file, $version)
{
    if(!(EnsureWritable $file)){ return;}
    
    write-verbose "Set version number in $file"
    $contents = gc $file | ? { -not ($_ -match 'Version\(') }
    $contents += '[assembly: AssemblyVersion("{0}")]' -f $version;
    $contents += '[assembly: AssemblyFileVersion("{0}")]' -f ($fileVersion.Replace('*','0'));
    $contents += '[assembly: AssemblyInformationalVersion("{0}")]' -f $semVer;
    $contents | out-file $file -Encoding:ASCII
    
    # Revert afterwards? Seems like this might just cause even more problems with TFS
    # if($wasReadOnly){ $file.IsReadOnly = $true; }
}

function ProcessItem($file, [scriptblock] $exec){
    if(!(EnsureWritable $file)){ return;}

    Write-Verbose "Set version number in $file"
    & $exec;
}

function ProcessXmlItem($file, [scriptblock] $exec){
    if(!(EnsureWritable $file)){ return;}
    
    Write-Verbose "Set version number in $file"
    $xml = new-object system.xml.xmldocument
    $xml.Load($file.FullName);
    & $exec $xml;
    $xml.Save($file.FullName);
}

# Loop over all the files specified
foreach($file in $files){
    if(!$file.Exists) { continue; }
    switch -Regex ($file.Name){
        '\.nuspec$' {
            # Update a version number in a nuspec
            # Better to just use the -version command line parameter on nuget.exe in most cases
            ProcessXmlItem $file {
                param($xml)
                $xml.package.metadata.version = $version;
            }
            break;
        }
        '\.wxs$' {
            # Update a version number embedded in a Wix setup project
            ProcessXmlItem $file {
                param($xml)
                $xml.Wix.Product.Version = $version;
            }
            break;    
        }
        '\.psd1$' {
            # Update a version number in a PowerShell manifest
            ProcessItem $file {
                $contents = Get-Content $file | % { 
                    $_ -replace "ModuleVersion\s*=\s*'[\d\.]+'","ModuleVersion = '$version'"
                }
                Set-Content -Value:$contents -Path:$file;
            }
        }
        'Assembly\w*Info.cs$' {
            ProcessItem $file {
                Set-AssemblyInfoVersion $file $version;
            }
        }
        default {
            Write-Verbose "Ignoring $_ as no handler setup for that file type";
        }
    }
}

} # end Set-VersionNumber
Export-ModuleMember -function Set-VersionNumber;


# begin TeamCityFunctions.ps1

<#
.synopsis
A series of utility functions for writing TeamCity Service Messages
This script should be dot-sourced into the caller's scope
Functions can be called outside of TeamCity (eg for local testing) and just write to Output
#>

# .synopsis
# Escapes characters for TeamCity messages
# See https://confluence.jetbrains.com/display/TCD65/Build+Script+Interaction+with+TeamCity
function TeamCity-Escape([string]$message){
    if([string]::IsNullOrEmpty($message)) { return $message; }

    # Replace all banned characters with the same character preceeded by a |
    # This list actually missing some high characters just now
    # oh, and Regex::Escape doesn't actually escape the closing brackets for you (mental)
    # http://msdn.microsoft.com/en-us/library/system.text.regularexpressions.regex.escape%28v=vs.110%29.aspx
    # currently escaping ' | `n `r [ ]

    return [Regex]::Replace($message, '[''\|\n\r\[\]]', '|$0');
}

function Start-TeamCityBlock($taskName){
    if($env:TEAMCITY_VERSION){
        Write-Host "##teamcity[blockOpened name='$taskName']";
    }else{
        Write-Host "$taskName start";
    }
}

function End-TeamCityBlock($taskName){
    if($env:TEAMCITY_VERSION){
        Write-Host "##teamcity[blockClosed name='$taskName']";
    }else{
        Write-Host "$taskName end";
        Write-Host;
    }
}

function Write-TeamCityProgress($message){
    if($env:TEAMCITY_VERSION){
        $message = TeamCity-Escape $message;
        Write-Host "##teamcity[progressMessage '$message']";
    }else{
        Write-Host $message -ForegroundColor:Yellow;
    }
}

function Start-TeamCityProgress($message){
    if($env:TEAMCITY_VERSION){
        $message = TeamCity-Escape $message;
        Write-Host "##teamcity[progressStart '$message']";
    }else{
        Write-Host $message;
    }
}

function End-TeamCityProgress($message){
    if($env:TEAMCITY_VERSION){
        $message = TeamCity-Escape $message;
        Write-Host "##teamcity[progressFinish '$message']";
    }else{
        # Write-Host $message
        Write-Host;
    }
}

function Set-TeamCityParameter($name, $value){
    Write-Host ("##teamcity[setParameter name='{0}' value='{1}']" -f (TeamCity-Escape $name),(TeamCity-Escape $value));
}

function Set-TeamCityStatistic($name, $value){
    Write-Host ("##teamcity[buildStatisticValue key='{0}' value='{1}']" -f (TeamCity-Escape $name),(TeamCity-Escape $value));
}

function Write-TeamCityBuildError($message){
    $fullMessage = $message -f $args;
    if($env:TEAMCITY_VERSION){
        $fullMessage = TeamCity-Escape $fullMessage;
        Write-Host "##teamcity[message status='ERROR' text='$fullMessage']";
    }else{
        Write-Warning $fullMessage;
    }
}

function Write-TeamCityBuildFailure($message){
    $fullMessage = $message -f $args;
    if($env:TEAMCITY_VERSION){
        $fullMessage = TeamCity-Escape $fullMessage;
        Write-Host "##teamcity[buildStatus status='FAILURE' text='{build.status.text} $fullMessage']";
    }else{
        Write-Error $fullMessage;
    }
}

$parentInvocation = (Get-Variable -Scope:1 -Name:MyInvocation -ValueOnly);
if($MyInvocation.MyCommand.Name.EndsWith('.psm1') -or $parentInvocation.MyCommand -match 'Import-Module'){
    Export-ModuleMember -Function:*-TeamCity*
}

# end TeamCityFunctions.ps1


# begin Update-VersionNumber.ps1

function Update-VersionNumber {
param(
    [Parameter(Mandatory=$true)] [string] $version,
    $versionNumberPattern = "#.#.+1.0"
)

$oldVersion = $version;
Write-Verbose "Old version was $oldVersion";

$oldVersionParts = $oldVersion.Split('.');
$patternParts = $versionNumberPattern.Split('.');

$newVersionParts = [int[]]0,0,0,0;
for($i = 0; $i -lt 4; $i++){
    $patternPart = $patternParts[$i];
    Write-Verbose "Part $i is $patternPart";
    if($patternPart.StartsWith('+')){
        $eval = "$($oldVersionParts[$i]) $patternPart";
        Write-Verbose "  Eval $eval";
        $newVersionParts[$i] = Invoke-Expression $eval;
    }elseif($patternPart.StartsWith('#')){
        $newVersionParts[$i] = $oldVersionParts[$i];
    }else{
        $newVersionParts[$i] = $patternPart;
    }
}

$newVersion = $newVersionParts -join '.';
Write-Verbose "New version is $newVersion";
$newVersion;

} # end Update-VersionNumber
Export-ModuleMember -function Update-VersionNumber;


