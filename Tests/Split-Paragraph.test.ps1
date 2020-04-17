#
# Testing Split-Paragraph Functionality

Describe "Testing Split-Paragraph" -Tag Unit {

    BeforeAll {

        Set-Location ..

        # Dot Source in the Function
        . .\profile.ps1

        $CLIXML = Import-CliXML -Path Tests\Mocks\Post.clixml

        $VerbosePreference = "Continue"
    }

    $Counter = 0

    ForEach($Message in $CLIXML.MessageBody) {

        
        Context ("Testing Index: {0}" -f $Counter++ ) {
            
            #
            # Arrange
            
            #
            # Act
            $Result = Split-Paragraph -Paragraph $Message -Char 50 -ErrorAction Break

            $Result | ForEach-Object { Write-Verbose "$($_)" }

            #
            # Assert
            if ($Message.Length -ge 50) {
                it "Should Contain Mulitple Messages" {
                    $Result.Count | Should BeGreaterOrEqual 2
                }
            } elseif ($Message.Length -ne 0) {
                it "Should be a Single Message" {
                    $Result.Count | Should be 1
                }
            } else {
                it "Should be a Empty" {
                    $Result.Count | Should be 0
                }                
            }

        }

    }




}