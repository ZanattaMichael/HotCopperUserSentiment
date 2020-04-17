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
# Let's scrape all that jucy data!

$UserPosts = [System.Collections.Generic.List[UserPost]]::New()

# Define the ID Counter
$idCounter = 0

# Iterate Though Each of the Requests
ForEach ($HTTPRequest in $HTTPRequests) {

    $HTMLDoc = [HtmlAgilityPack.HtmlDocument]::new()
    $HTMLDoc.LoadHtml($HTTPRequest)
    
    # Fetch the Posts Data Table Values, by searching for the user
    $UserNameField = $HTMLDoc.DocumentNode.SelectNodes("//*[normalize-space() = '$UserName']");
    # Exclude any objects that contains links (Less the 500 Chars) and no data.
    $Posts = $UserNameField.ParentNode.Where{$_.OuterHtml.Length -gt 500}
    
    ForEach ($Post in $Posts) {
        # Add them to an object
        $UserPosts.Add([UserPost]::ConvertToUserPost($Post, $HTMLDoc, $idCounter++))
    }
}

$Body = Get-Sentiment -User ([User]::New($UserPosts, $Username))

# Associate values to output bindings by calling 'Push-OutputBinding'.
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Body = $Body | ConvertTo-Json -Depth 7
})
