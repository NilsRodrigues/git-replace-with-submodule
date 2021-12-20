# Script Replace_With_Git_Module
<# .SYNOPSIS
    Replaces a directory in a git repository with a submodule.
.DESCRIPTION
    Short:
        1. Creates a new repository from a subdirectory of an existing repository.
        2. Replaces existing subdirectory with new repository as submodule.
    Detailed:
        1. Creates a new respository to later add module content (module repo).
        2. Fresh clone of existing main repository (main repo).
        3. Removes everything that is not within selected directory.
        This operation preserves the version history of the files
        contained within the directory.
        4. Pushes result to new module repo.
        5. Removed local copy of module repo (previously main repo).
        6. Fresh clone of existing main repo.
        7. Copies existing directory to backup "~_old" within main repo.
        8. Adds module repo as submodule instead of previously existing directory.
        Submodule name is the same as the name of the new module repo.
        9. Removes backup directory "~old".
.NOTES
    Author: Nils Rodrigues
    E-Mail: nils.2011@gmx.com
#>

#Requires -Version 7
$ErrorActionPreference = 'STOP'

# variables set by user:

$githubserver = "https://github.com" # also works with instances of github enterprise
$githublogin = "john.doe@e-mail.com" # login name
$githubname = "JohnDoe" # public account name (prefix to all your repository urls)

$mainrepo = "user-adaptive-scatter-plots" # name of the existing main repo
$mainbranch = "master" # existing branch from which to extract new submodule
$modulepath = "eye tracking/data-collection-0/data" # path to directory that will turn into new submodule
$modulerepo = "task-inference-data" # name of new repository that will contain submodule content
$modulebranch = "main" # name of default branch for new module repo

# internal variables:

$mainrepourl = "$githubserver/$githubname/$mainrepo.git"
$modulerepourl = "$githubserver/$githubname/$modulerepo.git"
$githubpassfile = "githubpass.txt"

# additional info:
#   https://docs.github.com/en/get-started/using-git/splitting-a-subfolder-out-into-a-new-repository

# necessary tool:
#   https://github.com/newren/git-filter-repo
# easy install with python:
#   pip install git-filter-repo


#cd $PSScriptRoot

Function ForgetGitHubPassword {
    # clear old value from memory
    if (Test-Path variable:script:githubpass) {
        $script:githubpass = $null
        $script:githubcred = $null
        $script:githubAuthHeader = $null
    }
    # delete password cache file
    try {
        if (Test-Path $script:githubpassfile) {
            Remove-Item -Path $script:githubpassfile
        }
    }
    catch {
        Write-Warning "Couldn't delete cache file for github password."
        Write-Warning $_
    }
}
Function GitHubPassword {
    # try using previous value
    if (!(Test-Path variable:script:githubpass)) {
        $script:githubpass = $null
    }
    # try loading from cache file
    if (!$script:githubpass -or $script:githubpass.Length -eq 0) {
        try {
            if (Test-Path $script:githubpassfile) {
                $securePassString = Get-Content -Path $script:githubpassfile
                $script:githubpass = $securePassString | ConvertTo-SecureString
            }
        }
        catch {
            $script:githubpass = $null
            Write-Warning "Couldn't load github password from cache file."
            Write-Warning $_
        }
    }
    # read from console and store in cache file
    if (!$script:githubpass -or $script:githubpass.Length -eq 0) {
        $script:githubpass = Read-Host -Prompt "Enter GitHub password" -AsSecureString

        if ($script:githubpass.Length -gt 0) {
            try {
                $securePassString = $script:githubpass | ConvertFrom-SecureString
                Set-Content -Path $script:githubpassfile -Value $securePassString
            }
            catch {
                Write-Warning "Couldn't store github password in cache file."
                Write-Warning $_
            }
        }
    }

    # check if we got a password
    if (!$script:githubpass -or $script:githubpass.Length -eq 0) {
        throw "Can't run split script without github password."
    }

    return $script:githubpass
}
Function GitHubCredential {
    if (!(Test-Path variable:script:githubcred)) {
        $script:githubcred = $null
    }
    if (!$script:githubcred) {
        $githubpass = GitHubPassword
        $securePass = $githubpass
        $script:githubcred = New-Object System.Management.Automation.PSCredential($script:githublogin, $securePass)
    }

    return $script:githubcred
}
Function GitHubAuthHeader {
    if (!(Test-Path variable:script:githubAuthHeader)) {
        $script:githubAuthHeader = $null
    }
    if (!$script:githubAuthHeader) {
        $secureCred = GitHubCredential
        $networkCred = $secureCred.GetNetworkCredential()
        $userpw = $networkCred.UserName + ":" + $networkCred.Password

        $bytes = [System.Text.Encoding]::UTF8.GetBytes($userpw)
        $authToken = [System.Convert]::ToBase64String($bytes)
        $script:githubAuthHeader  = @{Authorization = "Basic $authToken"}
    }

    return $script:githubAuthHeader
}

enum GitHubResponseHandling {
    None
    Raw
    Text
    Json
}

Function GitHubApi_old {
    Param(
        [Parameter(Mandatory=$false)][Microsoft.PowerShell.Commands.WebRequestMethod] $method = [Microsoft.PowerShell.Commands.WebRequestMethod]::Get,
        [Parameter(Mandatory=$true)][Uri] $uri,
        [Parameter(Mandatory=$false)][AllowNull()][hashtable] $data = $null,
        [Parameter(Mandatory=$false)][GitHubResponseHandling] $responseHandling = [GitHubResponseHandling]::None
    )

    try
    {
        $auth = GitHubAuthHeader
        if ($data)
        {
            $jsondata = ConvertTo-Json $data
            #$response = Invoke-WebRequest -Method $method -Uri $uri -Credential $cred -Authentication Basic -Body $jsondata
            $response = Invoke-WebRequest -Method $method -Uri $uri -Headers $auth -Body $jsondata
        }
        else
        {
            #$response = Invoke-WebRequest -Method $method -Uri $uri -Credential $cred -Authentication Basic
            $response = Invoke-WebRequest -Method $method -Uri $uri -Headers $auth
        }
        
        switch ($responseHandling) {
            [GitHubResponseHandling]::Raw {
                return $response
            }
            "Text" {
                $responseText = $response.Content
                return $responseText
            }
            "Json" {
                $responseData = $response | ConvertFrom-Json
                return $responseData
            }
        }
    }
    catch [System.Net.WebException], [System.Net.Http.HttpRequestException], [Microsoft.PowerShell.Commands.HttpResponseException] {
        $exception = $_.Exception
        Write-Warning $exception
        $response = $exception.Response
        
        # if unauthorized acces: ask for password again
        if ($response.StatusCode -eq [System.Net.HttpStatusCode]::Unauthorized) {
            #ForgetGitHubPassword
        }
        
        # print response
        if ($_.ErrorDetails.Message.Length -gt 0) {
            Write-Warning $_.ErrorDetails.Message
        }
    }
    catch
    {
        Write-Host $_.Exception
        throw
    }
}

Function GitHubApi {
    Param(
        [Parameter(Mandatory=$false)][Microsoft.PowerShell.Commands.WebRequestMethod] $method = [Microsoft.PowerShell.Commands.WebRequestMethod]::Get,
        [Parameter(Mandatory=$true)][Uri] $uri,
        [Parameter(Mandatory=$false)][AllowNull()][hashtable] $data = $null
    )

    while($true)
    {
        try
        {
            #$cred = GitHubCredential
            $auth = GitHubAuthHeader
            if ($data)
            {
                $jsondata = ConvertTo-Json $data
                $responsedata = Invoke-RestMethod -Method $method -Uri $uri -Headers $auth -Body $jsondata
            }
            else
            {
                $responsedata = Invoke-WebRequest -Method $method -Uri $uri -Headers $auth
            }
            
            return $responsedata
        }
        catch [Microsoft.PowerShell.Commands.HttpResponseException] {
            $exception = $_.Exception
            Write-Warning $exception
            $response = $exception.Response
        
            # print response
            if ($_.ErrorDetails.Message.Length -gt 0) {
                Write-Warning $_.ErrorDetails.Message
            }
            
            # if unauthorized acces: ask for password again
            if ($response.StatusCode -eq [System.Net.HttpStatusCode]::Unauthorized) {
                ForgetGitHubPassword
            }
            else {
                throw
            }
        }
        catch
        {
            Write-Host $_.Exception
            throw
        }
    }
}

Function GitProcess {
    Param(
        [AllowNull()][String[]] $arguments = $null
    )
    
    # enquote arguments
    Function PassThrough {
        param ($argument)
        return $argument
    }
    for($i=0; $i -lt $arguments.Length; $i++) {
        $singleArg = $arguments[$i]
        $arguments[$i] = PassThrough `"$singleArg`"
    }

    # call git with given arguments
    try {
        $proc = Start-Process -FilePath "git" -ArgumentList $arguments -WorkingDirectory $pwd -PassThru -Wait -NoNewWindow 2>&1

        if ($proc.ExitCode -ne 0) {
            throw "Process exited with code $($proc.ExitCode)."
        }
    }
    catch {
        Write-Host $_
        throw
    }
}

Function PushMain {
    GitProcess "push", "origin", $mainbranch
}

Function ExtractNewGitModule {
    # create new repo for submodule
    $data = @{
        name = $modulerepo;
        private = $true;
        description = "Submodule extracted from directory '$modulepath' in original repository '$githubname/$mainrepo'.";
    }
    $newRepo = GitHubApi -method POST -uri "$githubserver/api/v3/user/repos" -data $data
    Write-Host $newRepo

    # get existing main repo
    GitProcess "clone", "--branch", $mainbranch, $mainrepourl
    Push-Location $mainrepo

    # remove stuff that is not part of the submodule
    GitProcess "filter-repo", "--path", $modulepath

    # upload to new module repo
    GitProcess "remote", "add", "origin", $modulerepourl
    PushMain

    # move module content to root level
    $modulecontent = Get-ChildItem "./$modulepath/*"
    foreach ($f in $modulecontent) {
        $fname = [System.IO.Path]::GetFileName($f)
        GitProcess "mv", $f, $fname
    }
    GitProcess "commit", "-m", "relocate submodule content to root"
    PushMain

    Pop-Location

    # rename module branch, e.g., from "master" to "main"
    if ($mainbranch -ne $modulebranch) {
        $data = @{ new_name = $modulebranch; }
        $renamedRepo = GitHubApi -method POST -uri "$githubserver/api/v3/repos/$githubname/$modulerepo/branches/$mainbranch/rename" -data $data
        Write-Host $renamedRepo
    }
}

Function ReplaceWithModule {
    # get existing main repo
    GitProcess "clone", "--depth", "1", "--branch", $mainbranch, $mainrepourl

    Push-Location $mainrepo

    # create backup of module content
    $modulebackup = $modulepath+"_old"
    GitProcess "mv", $modulepath, $modulebackup
    GitProcess "commit", "-m", "created backup of submodule content"
    PushMain

    # add module
    GitProcess "submodule", "add", "--name", $modulerepo, $modulerepourl, $modulepath
    GitProcess "commit", "-m", "added submodule"
    PushMain

    # remove backup of module content
    GitProcess "rm", "-r", $modulebackup
    GitProcess "commit", "-m", "removed backup of submodule content"
    PushMain

    Pop-Location
}

# extract module from directory
ExtractNewGitModule

# cleanup
Remove-Item -Path $mainrepo -Recurse -Force

# replace directory with module
ReplaceWithModule

# cleanup
Remove-Item -Path $mainrepo -Recurse -Force
Remove-Item -Path $githubpassfile
