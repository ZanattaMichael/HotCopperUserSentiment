# Azure Functions profile.ps1
#
# This profile.ps1 will get executed every "cold start" of your Function App.
# "cold start" occurs when:
#
# * A Function App starts up for the very first time
# * A Function App starts up after being de-allocated due to inactivity
#
# You can define helper functions, run commands, or specify environment variables
# NOTE: any variables defined that are not environment variables will get reset after the first execution

# Authenticate with Azure PowerShell using MSI.
# Remove this if you are not planning on using MSI or Azure PowerShell.
#if ($env:MSI_SECRET -and (Get-Module -ListAvailable Az.Accounts)) {
#    Connect-AzAccount -Identity
#}

# Uncomment the next line to enable legacy AzureRm alias in Azure PowerShell.
# Enable-AzureRmAlias

# You can also define functions or aliases that can be referenced in any of your PowerShell functions.

#
# Add Dlls
#

# Get Location
$Location = Get-Location
$HTMLAgilityPackPath = [System.IO.Path]::Combine($Location.Path,"HTMLAgilityPack","HtmlAgilityPack.dll")

if (-not(Test-Path -LiteralPath $HTMLAgilityPackPath)) {
    Throw ("Cannot Find: $HTMLAgilityPackPath")
}

# Load the Assembly
Add-Type -LiteralPath $HTMLAgilityPackPath


#
# Classes
#
#region Classes

Class UserPost {
    [int]$Id
    [String]$Tag
    [String]$Subject
    [String]$URL
    [String]$Replies
    [String]$Views
    [String]$Likes
    [DateTime]$DatePosted
    [String[]]$MessageBody
    [System.Collections.Generic.List[Object]]$SentimentResults

    UserPost() {}
    UserPost([int]$id) {
        $this.id = $id
    }

    #region ConvertToUserPost
    Static [UserPost] ConvertToUserPost(
        [Object]$HtmlNode, 
        [Object]$HTMLDoc,
        [Int]$id) {

        $UserPost = [UserPost]::New($id)

        #
        # Within the HTML Node, extract the Subject, Tags, URL, Reply's (Count),
        # Views, Likes, Message Body and the Date Posted
        #

        try {

            $TagData = $HTMLDoc.DocumentNode.SelectNodes("{0}//*[@class='tag-type-symbol']" -f $HtmlNode.XPath)

            $SubjectElement = $HTMLDoc.DocumentNode.SelectNodes("{0}//*[@class='subject-a']" -f $HtmlNode.XPath)
            $SubjectValue = $SubjectElement.
                                        SelectNodes("{0}//*[@class='subject-a']" -f $HtmlNode.XPath).
                                        InnerHtml.Trim().Replace("   ","").Replace("`n","")

            $Responses = $HTMLDoc.DocumentNode.SelectSingleNode("{0}//*[starts-with(@class,'replies-td')]" -f $HtmlNode.XPath)
            $Stats = $HTMLDoc.DocumentNode.SelectNodes("{0}//*[starts-with(@class,'stats-td')]" -f $HtmlNode.XPath)

           

        } Catch {
            Write-Error $_
            return $UserPost;
        }

        $UserPost.Subject           = $SubjectValue
        $UserPost.Tag               = $TagData.InnerText 
        $UserPost.URL               = ($SubjectElement.Attributes.Where{$_.Name -eq "href"}).Value
        $UserPost.Replies           = $Responses.InnerText
        $UserPost.Views             = $Stats[0].InnerText
        $UserPost.Likes             = $Stats[1].InnerText
        $UserPost.MessageBody       = Get-PostContent -Url $UserPost.URL
        $UserPost.DatePosted        = Get-Date $Stats[2].InnerText
        $UserPost.SentimentResults  = [System.Collections.Generic.List[Object]]::New()
        return $UserPost
    }
    #endregion ConvertToUserPost

    AddResult([PSCustomObject]$Result) {
        $this.SentimentResults.Add($Result)
    }

}

Class User {
    [String]$UserName
    [DateTime]$FirstSeen
    [DateTime]$LastSeen
    [System.Collections.Generic.List[UserPost]]$Posts
    [User[]]$RelatedTo

    User() {}

    User([System.Collections.Generic.List[UserPost]]$posts, [String]$username) {
        $this.UserName = $username
        $this.Posts = $posts
        $this.FirstSeen = ($posts | Sort-Object -Property DatePosted)[0].DatePosted
        $this.LastSeen = ($posts | Sort-Object -Descending -Property DatePosted)[0].DatePosted
    }

}

#endregion Classes
#
# Functions
#
#region Functions

Function Get-WebUserHistory() {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [String[]]
        $Links
    )

    begin {
        $list = New-Object "System.Collections.Generic.List[Microsoft.PowerShell.Commands.BasicHtmlWebResponseObject]"
    }

    process {

        $params = @{
            URI = "Https://hotcopper.com.au/{0}" -f $Links
            Method = "Get"
            UserAgent = [Microsoft.PowerShell.Commands.PSUserAgent]::FireFox            
        }

        # Log
        Write-Host ("Invoking Message Lookup: {0}" -f $params.URI)

        Try {
            $Result = Invoke-WebRequest @params
            $list.Add($Result)
        } Catch {
            Write-Warning $_
        }

    }

    end {
        Write-Output $list
    }

}

Function Get-Sentiment {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [User]
        $User
    )


    #
    # Convert the User Posts into Rest Requests
    $RestRequestUserPosts = $User.Posts | ConvertTo-RestBody

    #
    # Iterate throught each of the requests and send it to sentiment anaylsis

    ForEach($RestRequestUserPost in $RestRequestUserPosts) {

        $params = @{
            Uri = "https://powershellmichaelsentiment.cognitiveservices.azure.com/text/analytics/v3.0-preview.1/sentiment"
            Method = "POST"
            Headers = @{
                'Ocp-Apim-Subscription-Key' = "82611d0973094ab99f37e93877640281";
                'Content-Type' = "application/json";
            }
            Body = $RestRequestUserPost.RestBody | ConvertTo-Json
        }
        
        try {
            $results = Invoke-RestMethod @params
        } Catch {
            # Print the Error and Skip
            Write-Error $_
            return;
        }

        # If the Results are Null Skip
        if ($null -eq $results) {
            # Skip
            Return;
        }

        #
        # We need to join the data back up to the User Object
        #

        # Iterate through each of the items and join it back to user post.
        For ($index = 0; $index -ne $RestRequestUserPost.MessageID.Length; $index++) {

            # Match the Current Index to the User Post Index
            $UserPostIndex = @(0 .. $RestRequestUserPost.MessageID.Length).Where{
                $User.Posts[$_].Id -eq $index
            }

            # Match the Results ID against the Request ID. They are the same.
            $Result = $results.documents.Where{$_.id -eq $User.Posts[$UserPostIndex].id}

            # Now we have the value we can update the result
            $User.Posts[$UserPostIndex].AddResult($Result)
        }
    }
    
    return $User

}

Function Get-IndicesOf {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [String]
        $String,
        [Parameter(Mandatory)]
        [String]
        $Char
    )

    # Define an Array to Store the Result
    $arr = @()

    # Define a Counter
    $PreviousIndexValue = 0

    Do {

        $result = $String.IndexOf($Char, $PreviousIndexValue)
        if ($Result -ne -1) { 
            $arr += $result 
            $PreviousIndexValue = $result + 1
        }

    } Until ($Result -eq -1)

    if ($arr.Count -eq 0) { return -1 }
    return $arr
}

Function Split-Paragraph {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [String]
        [AllowEmptyString()]
        $Paragraph,
        [Parameter(Mandatory)]
        [String]
        $CharLimit
    )

    begin {
        $Paragraphs = [System.Collections.Generic.List[String]]::New() 
    }

    process {

        # If null return to the parent
        if ([String]::IsNullOrEmpty($Paragraph)) {
            return
        }

        # If it's less then the limit, return to the parent.
        if ($Paragraph.Length -lt $CharLimit) {
            $Paragraphs.Add($Paragraph)
            return
        }

        #
        # Over the Character Limit

        # We need to split at the end of the sentence.
        $Indices = $Paragraph | Get-IndicesOf -Char "."
        $MiddleOfParagraph = [Math]::Round($Paragraph.Length / 2)
        
        # Split either Using an Exact Match of the Closest Match
        $Middle = 0 .. $Indices.Length | Where-Object {
            # Exact Match
            ($Indices[$_] -eq $MiddleOfParagraph) -or 
            # Closest Match
            (
                (($_ -ne 0) -and (
                    ($Indices[$_ - 1] -lt $MiddleOfParagraph)
                )) -and 
                (($_ -ne $Indices.Length) -and (
                    ($Indices[$_ + 1] -gt $MiddleOfParagraph)        
                ))
            )
        }
        
        # If the sentence paragraph contains no full stops. Cut the string in half literally.
        if ($null -eq $Middle) {
            $params = @{
                CharValue = $MiddleOfParagraph
            }
        } else {
        # Otherwise Split the Paragraph on the Matched Index Value
            $params = @{
                CharValue = $Indices[$Middle[0]]
            }    
        }

        # Recurse and pipe into the output
        $Paragraph | Split-StringOnCharValue @params | Split-Paragraph -CharLimit $CharLimit | ForEach-Object {
            $Paragraphs.Add($_)
        }
    }

    End {
        Write-Output $Paragraphs
    }

}

Function Split-StringOnCharValue {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [String]
        $String,
        [Parameter(Mandatory)]
        [int]
        $CharValue
    )

    $arr = @(
        $String.Substring(0, $CharValue),
        $String.Substring($CharValue, ($String.Length - $CharValue))
    )

    return $arr

}

Function ConvertTo-RestBody {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory,ValueFromPipeline)]
        $UserPost
    )

    Begin {
        # Declare the Return Body
        $Body = [System.Collections.Generic.List[PSCustomObject]]::New()

        # Declare a Rest Body Array
        $RestBodyArr = @()
        
        # Declare some Constents
        $CharLimit = 5120 
        $SizeLimit = "1M"
        $RequestLimit = 1000

        # Need to Re-Declare the Object and id Counter
        $idCounter = 0

        # Declare the Rest Body
        $RestRequestUserPost = [PSCustomObject]@{
            MessageID = @()
            RestBody = @{
                documents = @() 
            }
        }

    }

    Process {

        # Read the User Post
       
        #
        # Rule 1: Match against char limit
        $Paragraphs = $UserPost.MessageBody | Split-Paragraph -CharLimit $CharLimit

        #
        # Different Item counts of the array will be behave differently.
        Switch ($Paragraphs.Count) {
            #
            # Empty Item. Skip.
            0 { return }

            #
            # Single Item
            1 {
                # Normal: Item get's added to the existing Rest Body.
                $Paragraphs | ForEach-Object {
                    $RestRequestUserPost.MessageID += $UserPost.Id
                    $RestRequestUserPost.RestBody.documents += @{
                        language = "en"
                        id = $idCounter++
                        text = $_
                    }
                } 
            }

            #
            # Multiple Items            
            {$_ -gt 1} {
                # Mulitple Requests: Items get's added to it's own rest body
                # Need to Re-declare the Body and Id Counter
                $idCounter = 0

                $RestRequestUserPost = [PSCustomObject]@{
                    MessageID = @()
                    RestBody = @{
                        documents = @() 
                    }
                }

                # Append the Items to the body.
                $Paragraphs | ForEach-Object {
                    $RestRequestUserPost.MessageID = $UserPost.Id
                    $RestRequestUserPost.RestBody.documents += @{
                        language = "en"
                        id = $idCounter++
                        text = $_
                    }
                }

                # Add the Object to the Array
                $RestBodyArr += $RestRequestUserPost

                # Need to Re-Declare the Object and id Counter
                $idCounter = 0
                $RestRequestUserPost = [PSCustomObject]@{
                    MessageID = @()
                    RestBody = @{
                        documents = @() 
                    }
                }

                # Skip to the Next Item
                return

            }
        }

        #
        # Rule 2: Size of Request

        #
        # Rule 3: Limit of the Request

        if ($idCounter -eq 999) {

            # Add the Object to the Array
            $RestBodyArr += $RestRequestUserPost            

            # Need to Re-Declare the Object and id Counter
            $idCounter = 0

            # Declare the Rest Body
            $RestRequestUserPost = [PSCustomObject]@{
                MessageID = @()
                RestBody = @{
                    documents = @() 
                }
            }

            # Skip to the Next Item
            return;
        }

    }

    End {

        #
        # Add the last output into the array
        $RestBodyArr += $RestRequestUserPost    

        # Return to the Pipeline
        Write-Output $RestBodyArr
    }
}

function Get-PostContent {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [AllowNull()]
        [String]
        $URL
    )

    # If null, return to the caller
    if ($null -eq $URL) { return $null }

    $params = @{
        URI = "Https://hotcopper.com.au{0}" -f $URL
        Method = "Get"
        UserAgent = [Microsoft.PowerShell.Commands.PSUserAgent]::FireFox            
    }

    # Log
    Write-Host ("Invoking Message Lookup: {0}" -f $params.URI)

    $HTMLDoc = [HtmlAgilityPack.HtmlDocument]::new()

    Try {
        # Invoke the Request
        $WebContent = Invoke-WebRequest @params

        # Parse the HTML Content into Html Agility Pack
        $HTMLDoc.LoadHtml($WebContent.Content)


        $MessageBox = $HTMLDoc.DocumentNode.SelectSingleNode("//*[starts-with(@class,'message-text')]")
        $div = $MessageBox.ChildNodes.Where{$_.Name -eq "#text"}
        $Content = ($div.Text.Trim()).Replace("  ","").Where{$_ -ne ""} -join "."

        # Convert to Unicode
        $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Content)
        $UnicodeByteArray = [System.Text.Encoding]::Convert([System.Text.Encoding]::UTF8, [System.Text.Encoding]::Unicode, $Bytes)
        # Create a Unicode String/ Removing all x00 Chars. Not the preferred way.
        # ($ConvertedContent -replace '[\x0A\x0D\x09]', "") is preferred however no luck with PWSH 6
        $ConvertedContent = [String]::New($UnicodeByteArray.Where{$_ -ne 0})

    } Catch {
        Write-Error $_
    } 

    Write-Output ($ConvertedContent)
}

#endregion Functions