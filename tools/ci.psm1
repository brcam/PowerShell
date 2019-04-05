# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.

$ErrorActionPreference = 'continue'
$repoRoot = Join-Path $PSScriptRoot '..'
$script:administratorsGroupSID = "S-1-5-32-544"
$script:usersGroupSID = "S-1-5-32-545"

# set .NET path
$dotNetPath = "$env:USERPROFILE\Appdata\Local\Microsoft\dotnet"
if(Test-Path $dotNetPath)
{
    $env:PATH = $dotNetPath + ';' + $env:PATH
}

# import build into the global scope so it can be used by packaging
Import-Module (Join-Path $repoRoot 'build.psm1') -Scope Global
Import-Module (Join-Path $repoRoot 'tools\packaging') -scope Global

# import the windows specific functcion only in Windows PowerShell or on Windows
if($PSVersionTable.PSEdition -eq 'Desktop' -or $isWindows)
{
    Import-Module (Join-Path $PSScriptRoot 'WindowsCI.psm1') -scope Global
}

# tests if we should run a daily build
# returns true if the build is scheduled
# or is a pushed tag
Function Test-DailyBuild
{
    $trueString = 'True'
    if(($env:PS_DAILY_BUILD -eq $trueString) -or $env:BUILD_REASON -eq 'Schedule')
    {
        return $true
    }
    return $false
}

# Sets a build variable
Function Set-BuildVariable
{
    param(
        [Parameter(Mandatory=$true)]
        [string]
        $Name,

        [Parameter(Mandatory=$true)]
        [string]
        $Value
    )

    if($env:TF_BUILD)
    {
        # In VSTS
        Write-Host "##vso[task.setvariable variable=$Name;]$Value"
        # The variable will not show up until the next task.
        # Setting in the current session for the same behavior as the CI
        Set-Item env:/$name -Value $Value
    }
    else
    {
        Set-Item env:/$name -Value $Value
    }
}

# Emulates running all of CI but locally
function Invoke-CIFull
{
    param(
        [switch] $CleanRepo
    )
    if($CleanRepo)
    {
        Clear-PSRepo
    }

    Invoke-CIInstall
    Invoke-CIBuild
    Invoke-CITest -ErrorAction Continue
    Invoke-CIFinish
}

# Implements the CI 'build_script' step
function Invoke-CIBuild
{
    $releaseTag = Get-ReleaseTag
    # check to be sure our test tags are correct
    $result = Get-PesterTag
    if ( $result.Result -ne "Pass" )
    {
        $result.Warnings
        throw "Tags must be CI, Feature, Scenario, or Slow"
    }

    if(Test-DailyBuild)
    {
        Start-PSBuild -Configuration 'CodeCoverage' -PSModuleRestore -CI -ReleaseTag $releaseTag
    }

    Start-PSBuild -CrossGen -PSModuleRestore -Configuration 'Release' -CI -ReleaseTag $releaseTag
    Save-PSOptions

    $options = (Get-PSOptions)

    $path = split-path -path $options.Output

    $psOptionsPath = (Join-Path -Path $PSScriptRoot -ChildPath '../psoptions.json')
    $buildZipPath = (Join-Path -Path $PSScriptRoot -ChildPath '../build.zip')

    Compress-Archive -Path $path -DestinationPath $buildZipPath

    Push-Artifact -Path $psOptionsPath -Name 'build'
    Push-Artifact -Path $buildZipPath -Name 'build'
}

# Implements the CI 'install' step
function Invoke-CIInstall
{
    param(
        [switch]
        $SkipUser
    )
    # Make sure we have all the tags
    Sync-PSTags -AddRemoteIfMissing

    if(Test-DailyBuild)
    {
        if ($env:BUILD_REASON -eq 'Schedule')
        {
            Write-Host "##vso[build.updatebuildnumber]Daily-$env:BUILD_SOURCEBRANCHNAME-$env:BUILD_SOURCEVERSION-$((get-date).ToString("yyyyMMddhhss"))"
        }
    }

    if ($env:TF_BUILD -and !$SkipUser.IsPresent)
    {
        # Generate new credential for CI (only) remoting tests.
        Write-Verbose "Creating account for remoting tests in CI." -Verbose

        # Password
        $randomObj = [System.Random]::new()
        $password = ""
        1..(Get-Random -Minimum 15 -Maximum 126) | ForEach-Object { $password = $password + [char]$randomObj.next(45,126) }

        # Account
        $userName = 'ciRemote'
        New-LocalUser -username $userName -password $password
        Add-UserToGroup -username $userName -groupSid $script:administratorsGroupSID

        # Provide credentials globally for remote tests.
        $ss = ConvertTo-SecureString -String $password -AsPlainText -Force
        $ciRemoteCredential = [PSCredential]::new("$env:COMPUTERNAME\$userName", $ss)
        $ciRemoteCredential | Export-Clixml -Path "$env:TEMP\CIRemoteCred.xml" -Force

        # Check that LocalAccountTokenFilterPolicy policy is set, since it is needed for remoting
        # using above local admin account.
        Write-Log -Message "Checking for LocalAccountTokenFilterPolicy in the CI."
        $haveLocalAccountTokenFilterPolicy = $false
        try
        {
            $haveLocalAccountTokenFilterPolicy = ((Get-ItemPropertyValue -Path HKLM:SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System -Name LocalAccountTokenFilterPolicy) -eq 1)
        }
        # ignore if anything is caught:
        catch {}
        if (!$haveLocalAccountTokenFilterPolicy)
        {
            Write-Verbose "Setting the LocalAccountTokenFilterPolicy for remoting tests"
            Set-ItemProperty -Path HKLM:SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System -Name LocalAccountTokenFilterPolicy -Value 1
        }
    }

    Set-BuildVariable -Name TestPassed -Value False
    Start-PSBootstrap -Confirm:$false
}

function Invoke-CIxUnit
{
    param(
        [switch]
        $SkipFailing
    )
    $env:CoreOutput = Split-Path -Parent (Get-PSOutput -Options (Get-PSOptions))
    $path = "$env:CoreOutput\pwsh.exe"
    if($IsMacOS -or $IsLinux)
    {
        $path = "$env:CoreOutput\pwsh"
    }

    if(!(Test-Path $path))
    {
        throw "CoreCLR pwsh.exe was not built"
    }

    $xUnitTestResultsFile = Join-Path -Path $pwd -childpath "xUnitTestResults.xml"

    Start-PSxUnit -xUnitTestResultsFile $xUnitTestResultsFile
    Push-Artifact -Path $xUnitTestResultsFile -name xunit

    if(!$SkipFailing.IsPresent)
    {
        # Fail the build, if tests failed
        Test-XUnitTestResults -TestResultsFile $xUnitTestResultsFile
    }
}

# Implement CI 'Test_script'
function Invoke-CITest
{
    [CmdletBinding()]
    param(
        [ValidateSet('UnelevatedPesterTests', 'ElevatedPesterTests')]
        [string] $Purpose,
        [ValidateSet('CI', 'Others')]
        [string] $TagSet
    )

    # Pester doesn't allow Invoke-Pester -TagAll@('CI', 'RequireAdminOnWindows') currently
    # https://github.com/pester/Pester/issues/608
    # To work-around it, we exlude all categories, but 'CI' from the list
    switch ($TagSet) {
        'CI' {
            Write-Host -Foreground Green 'Running "CI" CoreCLR tests..'
            $ExcludeTag = @('Slow', 'Feature', 'Scenario')
        }
        'Others' {
            Write-Host -Foreground Green 'Running non-CI CoreCLR tests..'
            $ExcludeTag = @('CI')
        }
        Default {
            throw "Unknown TagSet: '$TagSet'"
        }
    }

    if($IsLinux -or $IsMacOS)
    {
        return Invoke-LinuxTestsCore -Purpose $Purpose -ExcludeTag $ExcludeTag -TagSet $TagSet
    }

    # CoreCLR

    $env:CoreOutput = Split-Path -Parent (Get-PSOutput -Options (Get-PSOptions))
    Write-Host -Foreground Green 'Run CoreCLR tests'
    $testResultsNonAdminFile = "$pwd\TestsResultsNonAdmin-$TagSet.xml"
    $testResultsAdminFile = "$pwd\TestsResultsAdmin-$TagSet.xml"
    if(!(Test-Path "$env:CoreOutput\pwsh.exe"))
    {
        throw "CoreCLR pwsh.exe was not built"
    }

    # Get the experimental feature names and the tests associated with them
    $ExperimentalFeatureTests = Get-ExperimentalFeatureTests

    if ($Purpose -eq 'UnelevatedPesterTests') {
        $arguments = @{
            Bindir = $env:CoreOutput
            OutputFile = $testResultsNonAdminFile
            Unelevate = $true
            Terse = $true
            Tag = @()
            ExcludeTag = $ExcludeTag + 'RequireAdminOnWindows'
        }

        Start-PSPester @arguments -Title "Pester Unelevated - $TagSet"
        # Fail the build, if tests failed
        Test-PSPesterResults -TestResultsFile $testResultsNonAdminFile

        # Run tests with specified experimental features enabled
        foreach ($entry in $ExperimentalFeatureTests.GetEnumerator())
        {
            $featureName = $entry.Key
            $testFiles = $entry.Value

            $expFeatureTestResultFile = "$pwd\TestsResultsNonAdmin.$featureName.xml"
            $arguments['OutputFile'] = $expFeatureTestResultFile
            $arguments['ExperimentalFeatureName'] = $featureName
            if ($testFiles.Count -eq 0) {
                # If an empty array is specified for the feature name, we run all tests with the feature enabled.
                # This allows us to prevent regressions to a critical engine experimental feature.
                $arguments.Remove('Path')
            } else {
                # If a non-empty string or array is specified for the feature name, we only run those test files.
                $arguments['Path'] = $testFiles
            }

            Start-PSPester @arguments -Title "Pester Experimental Unelevated - $featureName"

            # Fail the build, if tests failed
            Test-PSPesterResults -TestResultsFile $expFeatureTestResultFile
        }
    }

    if ($Purpose -eq 'ElevatedPesterTests') {
        $arguments = @{
            Terse = $true
            Bindir = $env:CoreOutput
            OutputFile = $testResultsAdminFile
            Tag = @('RequireAdminOnWindows')
            ExcludeTag = $ExcludeTag
        }

        Start-PSPester @arguments -Title "Pester Elevated - $TagSet"

        # Fail the build, if tests failed
        Test-PSPesterResults -TestResultsFile $testResultsAdminFile

        # Run tests with specified experimental features enabled
        foreach ($entry in $ExperimentalFeatureTests.GetEnumerator())
        {
            $featureName = $entry.Key
            $testFiles = $entry.Value

            $expFeatureTestResultFile = "$pwd\TestsResultsAdmin.$featureName.xml"
            $arguments['OutputFile'] = $expFeatureTestResultFile
            $arguments['ExperimentalFeatureName'] = $featureName
            if ($testFiles.Count -eq 0)
            {
                # If an empty array is specified for the feature name, we run all tests with the feature enabled.
                # This allows us to prevent regressions to a critical engine experimental feature.
                $arguments.Remove('Path')
            }
            else
            {
                # If a non-empty string or array is specified for the feature name, we only run those test files.
                $arguments['Path'] = $testFiles
            }
            Start-PSPester @arguments -Title "Pester Experimental Elevated - $featureName"

            # Fail the build, if tests failed
            Test-PSPesterResults -TestResultsFile $expFeatureTestResultFile
        }
    }

    Set-BuildVariable -Name TestPassed -Value True
}

# Implement CI 'after_test' phase
function Invoke-CIAfterTest
{
    [CmdletBinding()]
    param()

    if (Test-DailyBuild)
    {
        Start-PSBuild -Configuration 'CodeCoverage' -Clean

        $codeCoverageOutput = Split-Path -Parent (Get-PSOutput)
        $codeCoverageArtifacts = Compress-CoverageArtifacts -CodeCoverageOutput $codeCoverageOutput

        $destBasePath = if ($env:TF_BUILD) {
            $env:BUILD_ARTIFACTSTAGINGDIRECTORY
        } else {
            Join-Path (Get-Location).Path "out"
        }

        if (-not (Test-Path $destBasePath))
        {
            $null = New-Item -ItemType Directory -Path $destBasePath
        }

        Write-Host -ForegroundColor Green 'Upload CodeCoverage artifacts'
        $codeCoverageArtifacts | ForEach-Object {
            Copy-Item -Path $_ -Destination $destBasePath
            $newPath = Join-Path $destBasePath (Split-Path $_ -Leaf)
            Push-Artifact -Path $newPath -Name 'CodeCoverage'
        }

        New-TestPackage -Destination $destBasePath
        $testPackageFullName = Join-Path $destBasePath 'TestPackage.zip'
        Write-Verbose "Created TestPackage.zip" -Verbose
        Write-Host -ForegroundColor Green 'Upload test package'
        Push-Artifact $testPackageFullName -Name 'CodeCoverage'
    }
}

# Wrapper to push artifact
function Push-Artifact
{
    param(
        [Parameter(Mandatory)]
        [ValidateScript({Test-Path -Path $_})]
        $Path,
        [string]
        $Name
    )

    if(!$Name)
    {
        $artifactName = [system.io.path]::GetFileName($Path)
    }
    else
    {
        $artifactName = $Name
    }

    if ($env:TF_BUILD) {
        # In Azure DevOps
        Write-Host "##vso[artifact.upload containerfolder=$artifactName;artifactname=$artifactName;]$Path"
    }
}

function Compress-CoverageArtifacts
{
    param([string] $CodeCoverageOutput)

    # Create archive for test content, OpenCover module and CodeCoverage build
    $artifacts = New-Object System.Collections.ArrayList

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath((Join-Path $PSScriptRoot '..\test\tools\OpenCover'))
    $zipOpenCoverPath = Join-Path $pwd 'OpenCover.zip'
    [System.IO.Compression.ZipFile]::CreateFromDirectory($resolvedPath, $zipOpenCoverPath)
    $null = $artifacts.Add($zipOpenCoverPath)

    $zipCodeCoveragePath = Join-Path $pwd "CodeCoverage.zip"
    Write-Verbose "Zipping ${CodeCoverageOutput} into $zipCodeCoveragePath" -verbose
    [System.IO.Compression.ZipFile]::CreateFromDirectory($CodeCoverageOutput, $zipCodeCoveragePath)
    $null = $artifacts.Add($zipCodeCoveragePath)

    return $artifacts
}

function Get-ReleaseTag
{
    $metaDataPath = Join-Path -Path $PSScriptRoot -ChildPath 'metadata.json'
    $metaData = Get-Content $metaDataPath | ConvertFrom-Json
    $releaseTag = $metadata.PreviewReleaseTag
    if($env:BUILD_BUILID)
    {
        $releaseTag = $releaseTag.split('.')[0..2] -join '.'
        $releaseTag = $releaseTag + '.' + $env:BUILD_BUILID
    }
    return $releaseTag
}

# Implements CI 'on_finish' step
function Invoke-CIFinish
{
    param(
        [string] $NuGetKey
    )

    if($IsLinux -or $IsMacOS)
    {
        return New-LinuxPackage -NugetKey $NugetKey
    }

    try {
        $releaseTag = Get-ReleaseTag

        $previewVersion = $releaseTag.Split('-')
        $previewPrefix = $previewVersion[0]
        $previewLabel = $previewVersion[1].replace('.','')

        if(Test-DailyBuild)
        {
            $previewLabel= "daily{0}" -f $previewLabel
        }

        $preReleaseVersion = "$previewPrefix-$previewLabel.$env:BUILD_BUILDID"

        # Build clean before backing to remove files from testing
        Start-PSBuild -CrossGen -PSModuleRestore -Configuration 'Release' -ReleaseTag $preReleaseVersion -Clean

        # Build packages
        $packages = Start-PSPackage -Type msi,nupkg,zip -ReleaseTag $preReleaseVersion -SkipReleaseChecks

        $artifacts = New-Object System.Collections.ArrayList
        foreach ($package in $packages) {
            if (Test-Path $package)
            {
	            Write-Log "Package found: $package"
            }
	        else
            {
                Write-Warning -Message "Package NOT found: $package"
            }

            if($package -is [string])
            {
                $null = $artifacts.Add($package)
            }
            elseif($package -is [pscustomobject] -and $package.msi)
            {
                $null = $artifacts.Add($package.msi)
                $null = $artifacts.Add($package.wixpdb)
            }
        }

        # the packaging tests find the MSI package using env:PSMsiX64Path
        $env:PSMsiX64Path = $artifacts | Where-Object { $_.EndsWith(".msi")}

        # Install the latest Pester and import it
        Install-Module Pester -Force -SkipPublisherCheck
        Import-Module Pester -Force

        # start the packaging tests and get the results
        $packagingTestResult = Invoke-Pester -Script (Join-Path $repoRoot '.\test\packaging\windows\') -PassThru

        # fail the CI job if the tests failed, or nothing passed
        if($packagingTestResult.FailedCount -ne 0 -or !$packagingTestResult.PassedCount)
        {
            throw "Packaging tests failed ($($packagingTestResult.FailedCount) failed/$($packagingTestResult.PassedCount) passed)"
        }

        # only publish assembly nuget packages if it is a daily build and tests passed
        if(Test-DailyBuild)
        {
            $nugetArtifacts = Get-ChildItem $PSScriptRoot\packaging\nugetOutput -ErrorAction SilentlyContinue -Filter *.nupkg | Select-Object -ExpandProperty FullName
            if($nugetArtifacts)
            {
                $artifacts.AddRange(@($nugetArtifacts))
            }
        }

        # produce win-arm and win-arm64 packages if it is a daily build
        Start-PSBuild -Restore -Runtime win-arm -PSModuleRestore -Configuration 'Release' -ReleaseTag $releaseTag
        $arm32Package = Start-PSPackage -Type zip -WindowsRuntime win-arm -ReleaseTag $releaseTag -SkipReleaseChecks
        $artifacts.Add($arm32Package)

        Start-PSBuild -Restore -Runtime win-arm64 -PSModuleRestore -Configuration 'Release' -ReleaseTag $releaseTag
        $arm64Package = Start-PSPackage -Type zip -WindowsRuntime win-arm64 -ReleaseTag $releaseTag -SkipReleaseChecks
        $artifacts.Add($arm64Package)

        $pushedAllArtifacts = $true

        $artifacts | ForEach-Object {
            Write-Log -Message "Pushing $_ as CI artifact"
            if(Test-Path $_)
            {
                Push-Artifact -Path $_ -Name 'artifacts'
            }
            else
            {
                $pushedAllArtifacts = $false
                Write-Warning "Artifact $_ does not exist."
            }

            if($NuGetKey -and $env:NUGET_URL -and [system.io.path]::GetExtension($_) -ieq '.nupkg')
            {
                Write-Log "pushing $_ to $env:NUGET_URL"
                Start-NativeExecution -sb {dotnet nuget push $_ --api-key $NuGetKey --source "$env:NUGET_URL/api/v2/package"} -IgnoreExitcode
            }
        }
        if(!$pushedAllArtifacts)
        {
            throw "Some artifacts did not exist!"
        }
    }
    catch
    {
        Write-Host -Foreground Red $_
        Write-Host -Foreground Red $_.ScriptStackTrace
        throw $_
    }
}

# Bootstrap script for Linux and macOS
function Invoke-BootstrapStage
{
    $createPackages = Test-DailyBuild
    Write-Log -Message "Executing ci.psm1 Bootstrap Stage"
    # Make sure we have all the tags
    Sync-PSTags -AddRemoteIfMissing
    Start-PSBootstrap -Package:$createPackages
}

# Run pester tests for Linux and macOS
function Invoke-LinuxTestsCore
{
    [CmdletBinding()]
    param(
        [ValidateSet('UnelevatedPesterTests', 'ElevatedPesterTests', 'All')]
        [string] $Purpose = 'All',
        [string[]] $ExcludeTag = @('Slow', 'Feature', 'Scenario'),
        [string] $TagSet = 'CI'
    )

    $output = Split-Path -Parent (Get-PSOutput -Options (Get-PSOptions))
    $testResultsNoSudo = "$pwd/TestResultsNoSudo.xml"
    $testResultsSudo = "$pwd/TestResultsSudo.xml"
    $testExcludeTag = $ExcludeTag + 'RequireSudoOnUnix'

    $noSudoPesterParam = @{
        'BinDir'     = $output
        'PassThru'   = $true
        'Terse'      = $true
        'Tag'        = @()
        'ExcludeTag' = $testExcludeTag
        'OutputFile' = $testResultsNoSudo
    }

    # Get the experimental feature names and the tests associated with them
    $ExperimentalFeatureTests = Get-ExperimentalFeatureTests

    # Running tests which do not require sudo.
    if($Purpose -eq 'UnelevatedPesterTests' -or $Purpose -eq 'All')
    {
        $pesterPassThruNoSudoObject = Start-PSPester @noSudoPesterParam -Title "Pester No Sudo - $TagSet"

        # Running tests that do not require sudo, with specified experimental features enabled
        $noSudoResultsWithExpFeatures = @()
        foreach ($entry in $ExperimentalFeatureTests.GetEnumerator()) {
            $featureName = $entry.Key
            $testFiles = $entry.Value

            $expFeatureTestResultFile = "$pwd\TestResultsNoSudo.$featureName.xml"
            $noSudoPesterParam['OutputFile'] = $expFeatureTestResultFile
            $noSudoPesterParam['ExperimentalFeatureName'] = $featureName
            if ($testFiles.Count -eq 0) {
                # If an empty array is specified for the feature name, we run all tests with the feature enabled.
                # This allows us to prevent regressions to a critical engine experimental feature.
                $noSudoPesterParam.Remove('Path')
            }
            else
            {
                # If a non-empty string or array is specified for the feature name, we only run those test files.
                $noSudoPesterParam['Path'] = $testFiles
            }
            $passThruResult = Start-PSPester @noSudoPesterParam -Title "Pester Experimental No Sudo - $featureName - $TagSet"
            $noSudoResultsWithExpFeatures += $passThruResult
        }
    }

    # Running tests, which require sudo.
    if($Purpose -eq 'ElevatedPesterTests' -or $Purpose -eq 'All')
    {
        $sudoPesterParam = $noSudoPesterParam.Clone()
        $sudoPesterParam.Remove('Path')
        $sudoPesterParam['Tag'] = @('RequireSudoOnUnix')
        $sudoPesterParam['ExcludeTag'] = $ExcludeTag
        $sudoPesterParam['Sudo'] = $true
        $sudoPesterParam['OutputFile'] = $testResultsSudo
        $pesterPassThruSudoObject = Start-PSPester @sudoPesterParam -Title "Pester Sudo - $TagSet"

        # Running tests that require sudo, with specified experimental features enabled
        $sudoResultsWithExpFeatures = @()
        foreach ($entry in $ExperimentalFeatureTests.GetEnumerator()) {
            $featureName = $entry.Key
            $testFiles = $entry.Value

            $expFeatureTestResultFile = "$pwd\TestResultsSudo.$featureName.xml"
            $sudoPesterParam['OutputFile'] = $expFeatureTestResultFile
            $sudoPesterParam['ExperimentalFeatureName'] = $featureName
            if ($testFiles.Count -eq 0)
            {
                # If an empty array is specified for the feature name, we run all tests with the feature enabled.
                # This allows us to prevent regressions to a critical engine experimental feature.
                $sudoPesterParam.Remove('Path')
            }
            else
            {
                # If a non-empty string or array is specified for the feature name, we only run those test files.
                $sudoPesterParam['Path'] = $testFiles
            }
            $passThruResult = Start-PSPester @sudoPesterParam -Title "Pester Experimental Sudo - $featureName - $TagSet"
            $sudoResultsWithExpFeatures += $passThruResult
        }
    }

    # Determine whether the build passed
    try {
        $allTestResultsWithNoExpFeature = @($pesterPassThruNoSudoObject, $pesterPassThruSudoObject)
        $allTestResultsWithExpFeatures = @($noSudoResultsWithExpFeatures, $sudoResultsWithExpFeatures)
        # This throws if there was an error:
        $allTestResultsWithNoExpFeature | ForEach-Object { Test-PSPesterResults -ResultObject $_ }
        $allTestResultsWithExpFeatures  | ForEach-Object { Test-PSPesterResults -ResultObject $_ -CanHaveNoResult }
        $result = "PASS"
    } catch {
        # The build failed, set the result:
        $resultError = $_
        $result = "FAIL"
    }

    # If the tests did not pass, throw the reason why
    if ( $result -eq "FAIL" )
    {
        Write-Warning "Tests failed. See the issue below."
        Throw $resultError
    }
    else
    {
        Write-Verbose "Tests did not fail! Nice job!"
    }
}

function New-LinuxPackage
{
    param(
        [string]
        $NugetKey
    )

    $isFullBuild = Test-DailyBuild
    $releaseTag = Get-ReleaseTag
    $packageParams = @{}
    $packageParams += @{ReleaseTag=$releaseTag}

    # Only build packages for PowerShell/PowerShell repository
    # branches, not pull requests
    $packages = @(Start-PSPackage @packageParams -SkipReleaseChecks)
    foreach($package in $packages)
    {
        if (Test-Path $package)
        {
            Write-Log "Package found: $package"
        }
        else
        {
            Write-Error -Message "Package NOT found: $package"
        }

        # Publish the packages to the nuget feed if:
        # 1 - It's a Daily build (already checked, for not a PR)
        # 2 - We have the info to publish (NUGET_KEY and NUGET_URL)
        # 3 - it's a nupkg file
        if($isFullBuild -and $NugetKey -and $env:NUGET_URL -and [system.io.path]::GetExtension($package) -ieq '.nupkg')
        {
            Write-Log "pushing $package to $env:NUGET_URL"
            Start-NativeExecution -sb {dotnet nuget push $package --api-key $NugetKey --source "$env:NUGET_URL/api/v2/package"} -IgnoreExitcode
        }

        if($isFullBuild)
        {
            if ($package -isnot [System.IO.FileInfo])
            {
                 $packageObj = Get-Item $package
                 Write-Error -Message "The PACKAGE is not a FileInfo object"
            }
            else
            {
                    $packageObj = $package
            }

            Write-Log -message "Artifacts directory: ${env:BUILD_ARTIFACTSTAGINGDIRECTORY}"
            Copy-Item $packageObj.FullName -Destination "${env:BUILD_ARTIFACTSTAGINGDIRECTORY}" -Force
        }
    }

    if ($IsLinux)
    {
        # Create and package Raspbian .tgz
        Start-PSBuild -PSModuleRestore -Clean -Runtime linux-arm -Configuration 'Release'
        $armPackage = Start-PSPackage @packageParams -Type tar-arm -SkipReleaseChecks
        Copy-Item $armPackage -Destination "${env:BUILD_ARTIFACTSTAGINGDIRECTORY}" -Force
    }

    if ($isFullBuild)
    {
        New-TestPackage -Destination "${env:SYSTEM_ARTIFACTSDIRECTORY}"
    }
}
