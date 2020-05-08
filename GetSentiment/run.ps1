using namespace System;
using namespace System.XML;
using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

# Write to the Azure Functions log stream.
Write-Host "PowerShell HTTP trigger function processed a request."

# Interact with query parameters or the body of the request.
$UserName = $Request.Query.UserName

# Return if the Username dosen't exist
if (-not($UserName)) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body = @{ Error = "Missing Username"}
    })
    return;     
}

$HTTPRequests = [System.Collections.Generic.List[Microsoft.PowerShell.Commands.BasicHtmlWebResponseObject]]::New()

#
# Build the Int
$params = @{
    Uri = "https://hotcopper.com.au/search/search?type=post&users={0}" -f $UserName
    Method = "Get"
    SessionVariable = 'WebSession' 
    UserAgent = [Microsoft.PowerShell.Commands.PSUserAgent]::InternetExplorer
}

$HTTPRequest = Invoke-WebRequest @params
$HTTPRequests.Add($HTTPRequest)

$HTMLWeb = [HtmlAgilityPack.HtmlWeb]::New()

#
# Look for more pages

$PageNumber = 2
$PageExpirey = $false

Do {

    $match = $HTTPRequests.Links.href.Where{$_ -match ("(page={0})" -f $PageNumber)} | Select-Object -Unique
    
    if ([String]::IsNullOrEmpty($match)) {
        $PageExpirey = $true
    } else {
        $HTTPRequests.Add(($match | Get-WebUserHistory))
        $PageNumber++

    }
    
} Until ($PageExpirey)


#
# Enumerate all Classes and Functions into a ScriptBlock that can be invoked when running a PowerShell

$PreInitializationCode = {
    # Get Location
    $Location = Get-Location
    $HTMLAgilityPackPath = [System.IO.Path]::Combine($Location.Path,"HTMLAgilityPack","HtmlAgilityPack.dll")

    # Test if the Path Exists
    if (-not(Test-Path -LiteralPath $HTMLAgilityPackPath)) {
        Throw ("Cannot Find: $HTMLAgilityPackPath")
    }
    # Load the Assembly
    Add-Type -LiteralPath $HTMLAgilityPackPath    
}.ToString()

# Enumerate all the Functions that are not loaded from a module. This will include alias functions as well.
(Get-Item "Function:*").Where{$_.Source -eq "" -and $_.CommandType -eq "Function"} | ForEach-Object { $PreInitializationCode += [String]"Function $($_.Name) { $($_.ScriptBlock) };" }

# Build out a scriptblock of the functions
$PreInitializationCodeScriptBlock = [scriptblock]::Create($PreInitializationCode)

#
# Let's scrape all that jucy data!

$UserPosts = [System.Collections.Generic.List[UserPost]]::New()

# Define the ID Counter
$idCounter = 0

# PowerShell Job Limit
$PowerShellJobLimit = 10

# Iterate Though Each of the Requests
ForEach ($HTTPRequest in $HTTPRequests) {

    $HTMLDoc = [HtmlAgilityPack.HtmlDocument]::new()
    $HTMLDoc.LoadHtml($HTTPRequest)
    
    # Fetch the Posts Data Table Values, by searching for the user
    $UserNameField = $HTMLDoc.DocumentNode.SelectNodes("//*[normalize-space() = '$UserName']");
    
    # Exclude any objects that contains links (Less the 500 Chars) and no data.
    $Posts = $UserNameField.ParentNode.Where{$_.OuterHtml.Length -gt 500}
    
    # Iterate through each of the Posts
    ForEach ($Post in $Posts) {

        #
        # Basic PowerShell Job Manager

        $job = $null
        Do {

            $CompletedJobs = Get-Job -State Completed

            if ($CompletedJobs.Count -le $PowerShellJobLimit) {

                $job = Start-Job -InitializationScript $PreInitializationCodeScriptBlock -ScriptBlock {
                    param (
                        [Object]$HtmlNode,
                        [Object]$HTMLDoc,
                        [Int]$id
                    )
                    
                    ConvertTo-UserPost $HtmlNode, $HTMLDoc, $id
                } -ArgumentList $Post, $HTMLDoc, $idCounter++

            }
        } Until ($null -ne $job)

    }

    Get-Job -State Completed | ForEach-Object {
        $_ | Receive-Job

        
    }

}

$Body = Get-Sentiment -User ([User]::New($UserPosts, $Username))

# Associate values to output bindings by calling 'Push-OutputBinding'.
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Body = $Body | ConvertTo-Json -Depth 7
})
