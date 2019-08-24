<#
.SYNOPSIS
Attaches a file onto the Response for downloading.

.DESCRIPTION
Attaches a file from the "/public", and static Routes, onto the Response for downloading.

.PARAMETER Path
The Path to a static file relative to the "/public" directory, or a static Route.

If the supplied Path doesn't match any custom static Route, the Pode will look in the "/public" directory.

.EXAMPLE
Set-PodeResponseAttachment -Path 'downloads/installer.exe'
#>
function Set-PodeResponseAttachment
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]
        $Path
    )

    # only attach files from public/static-route directories when path is relative
    $Path = (Get-PodeStaticRoutePath -Route $Path).Path

    # test the file path, and set status accordingly
    if (!(Test-PodePath $Path)) {
        return
    }

    $filename = Get-PodeFileName -Path $Path
    $ext = Get-PodeFileExtension -Path $Path -TrimPeriod

    try {
        # setup the content type and disposition
        $WebEvent.Response.ContentType = (Get-PodeContentType -Extension $ext)
        Set-PodeHeader -Name 'Content-Disposition' -Value "attachment; filename=$($filename)"

        # if serverless, get the content raw and return
        if ($PodeContext.Server.IsServerless) {
            if (Test-IsPSCore) {
                $content = (Get-Content -Path $Path -Raw -AsByteStream)
            }
            else {
                $content = (Get-Content -Path $Path -Raw -Encoding byte)
            }

            $WebEvent.Response.Body = $content
        }

        # else if normal, stream the content back
        else {
            # setup the response details and headers
            $WebEvent.Response.ContentLength64 = $fs.Length
            $WebEvent.Response.SendChunked = $false

            # set file as an attachment on the response
            $buffer = [byte[]]::new(64 * 1024)
            $read = 0

            # open up the file as a stream
            $fs = (Get-Item $Path).OpenRead()

            while (($read = $fs.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $WebEvent.Response.OutputStream.Write($buffer, 0, $read)
            }
        }
    }
    finally {
        Close-PodeDisposable -Disposable $fs
    }
}

<#
.SYNOPSIS
Writes a String or a Byte[] to the Response.

.DESCRIPTION
Writes a String or a Byte[] to the Response, as some specified content type. This value can also be cached.

.PARAMETER Value
A String value to write.

.PARAMETER Bytes
An array of Bytes to write.

.PARAMETER ContentType
The content type of the data being written.

.PARAMETER MaxAge
The maximum age to cache the value on the browser, in seconds.

.PARAMETER Cache
Should the value be cached by browsers, or not?

.EXAMPLE
Write-PodeTextResponse -Value 'Leeeeeerrrooooy Jeeeenkiiins!'

.EXAMPLE
Write-PodeTextResponse -Value '{"name": "Rick"}' -ContentType 'application/json'

.EXAMPLE
Write-PodeTextResponse -Bytes (Get-Content -Path ./some/image.png -Raw -AsByteStream) -Cache -MaxAge 1800
#>
function Write-PodeTextResponse
{
    [CmdletBinding(DefaultParameterSetName='String')]
    param (
        [Parameter(ParameterSetName='String')]
        [string]
        $Value,

        [Parameter(ParameterSetName='Bytes')]
        [byte[]]
        $Bytes,

        [Parameter()]
        [string]
        $ContentType = 'text/plain',

        [Parameter()]
        [int]
        $MaxAge = 3600,

        [switch]
        $Cache
    )

    $isStringValue = ($PSCmdlet.ParameterSetName -ieq 'string')
    $isByteValue = ($PSCmdlet.ParameterSetName -ieq 'bytes')

    # if there's nothing to write, return
    if ($isStringValue -and [string]::IsNullOrWhiteSpace($Value)) {
        return
    }

    if ($isByteValue -and (($null -eq $Bytes) -or ($Bytes.Length -eq 0))) {
        return
    }

    # if the response stream isn't writable, return
    $res = $WebEvent.Response
    if (($null -eq $res) -or (!$PodeContext.Server.IsServerless -and (($null -eq $res.OutputStream) -or !$res.OutputStream.CanWrite))) {
        return
    }

    # set a cache value
    if ($Cache) {
        Set-PodeHeader -Name 'Cache-Control' -Value "max-age=$($MaxAge), must-revalidate"
        Set-PodeHeader -Name 'Expires' -Value ([datetime]::UtcNow.AddSeconds($MaxAge).ToString("ddd, dd MMM yyyy HH:mm:ss 'GMT'"))
    }

    # specify the content-type if supplied (adding utf-8 if missing)
    if (![string]::IsNullOrWhiteSpace($ContentType)) {
        $charset = 'charset=utf-8'
        if ($ContentType -inotcontains $charset) {
            $ContentType = "$($ContentType); $($charset)"
        }

        $res.ContentType = $ContentType
    }

    # if we're serverless, set the string as the body
    if ($PodeContext.Server.IsServerless) {
        if ($isStringValue) {
            $res.Body = $Value
        }
        else {
            $res.Body = $Bytes
        }
    }

    else {
        # convert string to bytes
        if ($isStringValue) {
            $Bytes = ConvertFrom-PodeValueToBytes -Value $Value
        }

        # write the content to the response stream
        $res.ContentLength64 = $Bytes.Length

        try {
            $ms = New-Object -TypeName System.IO.MemoryStream
            $ms.Write($Bytes, 0, $Bytes.Length)
            $ms.WriteTo($res.OutputStream)
        }
        catch {
            if ((Test-PodeValidNetworkFailure $_.Exception)) {
                return
            }

            $_ | Write-PodeErrorLog
            throw
        }
        finally {
            if ($null -ne $ms) {
                $ms.Close()
            }
        }
    }
}

<#
.SYNOPSIS
Renders the content of a static, or dynamic, file on the Response.

.DESCRIPTION
Renders the content of a static, or dynamic, file on the Response.
You can set browser's to cache the content, and also override the file's content type.

.PARAMETER Path
The path to a file.

.PARAMETER Data
A HashTable of dynamic data to supply to a dynamic file.

.PARAMETER ContentType
The content type of the file's contents - this overrides the file's extension.

.PARAMETER MaxAge
The maximum age to cache the file's content on the browser, in seconds.

.PARAMETER Cache
Should the file's content be cached by browsers, or not?

.EXAMPLE
Write-PodeFileResponse -Path 'C:/Files/Stuff.txt'

.EXAMPLE
Write-PodeFileResponse -Path 'C:/Files/Stuff.txt' -Cache -MaxAge 1800

.EXAMPLE
Write-PodeFileResponse -Path 'C:/Files/Stuff.txt' -ContentType 'application/json'

.EXAMPLE
Write-PodeFileResponse -Path 'C:/Views/Index.pode' -Data @{ Counter = 2 }
#>
function Write-PodeFileResponse
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        [string]
        $Path,

        [Parameter()]
        $Data = @{},

        [Parameter()]
        [string]
        $ContentType = $null,

        [Parameter()]
        [int]
        $MaxAge = 3600,

        [switch]
        $Cache
    )

    # resolve for relative path
    $Path = Get-PodeRelativePath -Path $Path -JoinRoot

    # test the file path, and set status accordingly
    if (!(Test-PodePath $Path -FailOnDirectory)) {
        return
    }

    # are we dealing with a dynamic file for the view engine? (ignore html)
    $mainExt = Get-PodeFileExtension -Path $Path -TrimPeriod

    # generate dynamic content
    if (![string]::IsNullOrWhiteSpace($mainExt) -and (($mainExt -ieq 'pode') -or ($mainExt -ieq $PodeContext.Server.ViewEngine.Extension))) {
        $content = Get-PodeFileContentUsingViewEngine -Path $Path -Data $Data

        # get the sub-file extension, if empty, use original
        $subExt = Get-PodeFileExtension -Path (Get-PodeFileName -Path $Path -WithoutExtension) -TrimPeriod
        $subExt = (Protect-PodeValue -Value $subExt -Default $mainExt)

        $ContentType = (Protect-PodeValue -Value $ContentType -Default (Get-PodeContentType -Extension $subExt))
        Write-PodeTextResponse -Value $content -ContentType $ContentType
    }

    # this is a static file
    else {
        if (Test-IsPSCore) {
            $content = (Get-Content -Path $Path -Raw -AsByteStream)
        }
        else {
            $content = (Get-Content -Path $Path -Raw -Encoding byte)
        }

        $ContentType = (Protect-PodeValue -Value $ContentType -Default (Get-PodeContentType -Extension $mainExt))
        Write-PodeTextResponse -Bytes $content -ContentType $ContentType -MaxAge $MaxAge -Cache:$Cache
    }
}

<#
.SYNOPSIS
Writes CSV data to the Response.

.DESCRIPTION
Writes CSV data to the Response, setting the content type accordingly.

.PARAMETER Value
A String, PSObject, or HashTable value.

.PARAMETER Path
The path to a CSV file.

.EXAMPLE
Write-PodeCsvResponse -Value "Name`nRick"

.EXAMPLE
Write-PodeCsvResponse -Value @{ Name = 'Rick' }

.EXAMPLE
Write-PodeCsvResponse -Path 'E:/Files/Names.csv'
#>
function Write-PodeCsvResponse
{
    [CmdletBinding(DefaultParameterSetName='Value')]
    param (
        [Parameter(Mandatory=$true, ParameterSetName='Value')]
        $Value,

        [Parameter(Mandatory=$true, ParameterSetName='File')]
        [string]
        $Path
    )

    switch ($PSCmdlet.ParameterSetName.ToLowerInvariant()) {
        'file' {
            if (Test-PodePath $Path) {
                $Value = Get-PodeFileContent -Path $Path
            }
        }

        'value' {
            if ($Value -isnot [string]) {
                $Value = @(foreach ($v in $Value) {
                    New-Object psobject -Property $v
                })

                if (Test-IsPSCore) {
                    $Value = ($Value | ConvertTo-Csv -Delimiter ',' -IncludeTypeInformation:$false)
                }
                else {
                    $Value = ($Value | ConvertTo-Csv -Delimiter ',' -NoTypeInformation)
                }

                $Value = ($Value -join ([environment]::NewLine))
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($Value)) {
        $Value = [string]::Empty
    }

    Write-PodeTextResponse -Value $Value -ContentType 'text/csv'
}

<#
.SYNOPSIS
Writes HTML data to the Response.

.DESCRIPTION
Writes HTML data to the Response, setting the content type accordingly.

.PARAMETER Value
A String, PSObject, or HashTable value.

.PARAMETER Path
The path to a HTML file.

.EXAMPLE
Write-PodeHtmlResponse -Value '<html><body>Hello!</body></html>'

.EXAMPLE
Write-PodeHtmlResponse -Value @{ Message = 'Hello, all!' }

.EXAMPLE
Write-PodeHtmlResponse -Path 'E:/Site/About.html'
#>
function Write-PodeHtmlResponse
{
    [CmdletBinding(DefaultParameterSetName='Value')]
    param (
        [Parameter(Mandatory=$true, ParameterSetName='Value')]
        $Value,

        [Parameter(Mandatory=$true, ParameterSetName='File')]
        [string]
        $Path
    )

    switch ($PSCmdlet.ParameterSetName.ToLowerInvariant()) {
        'file' {
            if (Test-PodePath $Path) {
                $Value = Get-PodeFileContent -Path $Path
            }
        }

        'value' {
            if ($Value -isnot [string]) {
                $Value = ($Value | ConvertTo-Html)
                $Value = ($Value -join ([environment]::NewLine))
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($Value)) {
        $Value = [string]::Empty
    }

    Write-PodeTextResponse -Value $Value -ContentType 'text/html'
}

<#
.SYNOPSIS
Writes Markdown data to the Response.

.DESCRIPTION
Writes Markdown data to the Response, with the option to render it as HTML.

.PARAMETER Value
A String, PSObject, or HashTable value.

.PARAMETER Path
The path to a Markdown file.

.PARAMETER AsHtml
If supplied, the Markdown will be converted to HTML. (This is only supported in PS7+)

.EXAMPLE
Write-PodeMarkdownResponse -Value '# Hello, world!' -AsHtml

.EXAMPLE
Write-PodeMarkdownResponse -Path 'E:/Site/About.md'
#>
function Write-PodeMarkdownResponse
{
    [CmdletBinding(DefaultParameterSetName='Value')]
    param (
        [Parameter(Mandatory=$true, ParameterSetName='Value')]
        $Value,

        [Parameter(Mandatory=$true, ParameterSetName='File')]
        [string]
        $Path,

        [switch]
        $AsHtml
    )

    switch ($PSCmdlet.ParameterSetName.ToLowerInvariant()) {
        'file' {
            if (Test-PodePath $Path) {
                $Value = Get-PodeFileContent -Path $Path
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($Value)) {
        $Value = [string]::Empty
    }

    $mimeType = 'text/markdown'

    if ($AsHtml) {
        if ($PSVersionTable.PSVersion.Major -ge 7) {
            $mimeType = 'text/html'
            $Value = ($Value | ConvertFrom-Markdown).Html
        }
    }

    Write-PodeTextResponse -Value $Value -ContentType $mimeType
}

<#
.SYNOPSIS
Writes JSON data to the Response.

.DESCRIPTION
Writes JSON data to the Response, setting the content type accordingly.

.PARAMETER Value
A String, PSObject, or HashTable value.

.PARAMETER Path
The path to a JSON file.

.PARAMETER Depth
The Depth to generate the JSON document - the larger this value the worse performance gets.

.EXAMPLE
Write-PodeJsonResponse -Value '{"name": "Rick"}'

.EXAMPLE
Write-PodeJsonResponse -Value @{ Name = 'Rick' }

.EXAMPLE
Write-PodeJsonResponse -Path 'E:/Files/Names.json'
#>
function Write-PodeJsonResponse
{
    [CmdletBinding(DefaultParameterSetName='Value')]
    param (
        [Parameter(Mandatory=$true, ParameterSetName='Value')]
        $Value,

        [Parameter(Mandatory=$true, ParameterSetName='File')]
        [string]
        $Path,

        [Parameter()]
        [int]
        $Depth = 10
    )

    switch ($PSCmdlet.ParameterSetName.ToLowerInvariant()) {
        'file' {
            if (Test-PodePath $Path) {
                $Value = Get-PodeFileContent -Path $Path
            }
        }

        'value' {
            if ($Value -isnot [string]) {
                if ($Depth -le 0) {
                    $Value = ($Value | ConvertTo-Json -Compress)
                }
                else {
                    $Value = ($Value | ConvertTo-Json -Depth $Depth -Compress)
                }
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($Value)) {
        $Value = '{}'
    }

    Write-PodeTextResponse -Value $Value -ContentType 'application/json'
}

<#
.SYNOPSIS
Writes XML data to the Response.

.DESCRIPTION
Writes XML data to the Response, setting the content type accordingly.

.PARAMETER Value
A String, PSObject, or HashTable value.

.PARAMETER Path
The path to an XML file.

.EXAMPLE
Write-PodeXmlResponse -Value '<root><name>Rick</name></root>'

.EXAMPLE
Write-PodeXmlResponse -Value @{ Name = 'Rick' }

.EXAMPLE
Write-PodeXmlResponse -Path 'E:/Files/Names.xml'
#>
function Write-PodeXmlResponse
{
    [CmdletBinding(DefaultParameterSetName='Value')]
    param (
        [Parameter(Mandatory=$true, ParameterSetName='Value')]
        $Value,

        [Parameter(Mandatory=$true, ParameterSetName='File')]
        [string]
        $Path
    )

    switch ($PSCmdlet.ParameterSetName.ToLowerInvariant()) {
        'file' {
            if (Test-PodePath $Path) {
                $Value = Get-PodeFileContent -Path $Path
            }
        }

        'value' {
            if ($Value -isnot [string]) {
                $Value = @(foreach ($v in $Value) {
                    New-Object psobject -Property $v
                })
        
                $Value = ($Value | ConvertTo-Xml -Depth 10 -As String -NoTypeInformation)
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($Value)) {
        $Value = [string]::Empty
    }

    Write-PodeTextResponse -Value $Value -ContentType 'text/xml'
}

<#
.SYNOPSIS
Renders a dynamic, or static, View on the Response.

.DESCRIPTION
Renders a dynamic, or static, View on the Response; allowing for dynamic data to be supplied.

.PARAMETER Path
The path to a View, relative to the "/views" directory. (Extension is optional).

.PARAMETER Data
Any dynamic data to supply to a dynamic View.

.PARAMETER FlashMessages
Automatically supply all Flash messages in the current session to the View.

.EXAMPLE
Write-PodeViewResponse -Path 'index'

.EXAMPLE
Write-PodeViewResponse -Path 'accounts/profile_page' -Data @{ Username = 'Morty' }

.EXAMPLE
Write-PodeViewResponse -Path 'login' -FlashMessages
#>
function Write-PodeViewResponse
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]
        $Path,

        [Parameter()]
        [hashtable]
        $Data = @{},

        [switch]
        $FlashMessages
    )

    # default data if null
    if ($null -eq $Data) {
        $Data = @{}
    }

    # add path to data as "pagename" - unless key already exists
    if (!$Data.ContainsKey('pagename')) {
        $Data['pagename'] = $Path
    }

    # load all flash messages if needed
    if ($FlashMessages -and ($null -ne $WebEvent.Session.Data.Flash)) {
        $Data['flash'] = @{}

        foreach ($name in (Get-PodeFlashMessageNames)) {
            $Data.flash[$name] = (Get-PodeFlashMessage -Name $name)
        }
    }
    elseif ($null -eq $Data['flash']) {
        $Data['flash'] = @{}
    }

    # add view engine extension
    $ext = Get-PodeFileExtension -Path $Path
    if ([string]::IsNullOrWhiteSpace($ext)) {
        $Path += ".$($PodeContext.Server.ViewEngine.Extension)"
    }

    # only look in the view directory
    $Path = (Join-Path $PodeContext.Server.InbuiltDrives['views'] $Path)

    # test the file path, and set status accordingly
    if (!(Test-PodePath $Path)) {
        return
    }

    # run any engine logic and render it
    $engine = (Get-PodeViewEngineType -Path $Path)
    $value = (Get-PodeFileContentUsingViewEngine -Path $Path -Data $Data)

    switch ($engine.ToLowerInvariant()) {
        'md' {
            Write-PodeMarkdownResponse -Value $value -AsHtml
        }

        default {
            Write-PodeHtmlResponse -Value $value
        }
    }
}

<#
.SYNOPSIS
Sets the Status Code of the Response, and controls rendering error pages.

.DESCRIPTION
Sets the Status Code of the Response, and controls rendering error pages.

.PARAMETER Code
The Status Code to set on the Response.

.PARAMETER Description
An optional Status Description.

.PARAMETER Exception
An exception to use when detailing error information on error pages.

.PARAMETER ContentType
The content type of the error page to use.

.PARAMETER NoErrorPage
Don't render an error page when the Status Code is 400+.

.EXAMPLE
Set-PodeResponseStatus -Code 404

.EXAMPLE
Set-PodeResponseStatus -Code 500 -Exception $_.Exception

.EXAMPLE
Set-PodeResponseStatus -Code 500 -Exception $_.Exception -ContentType 'application/json'
#>
function Set-PodeResponseStatus
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [int]
        $Code,

        [Parameter()]
        [string]
        $Description,

        [Parameter()]
        $Exception,

        [Parameter()]
        [string]
        $ContentType = $null,

        [switch]
        $NoErrorPage
    )

    # set the code
    $WebEvent.Response.StatusCode = $Code

    # set an appropriate description (mapping if supplied is blank)
    if ([string]::IsNullOrWhiteSpace($Description)) {
        $Description = (Get-PodeStatusDescription -StatusCode $Code)
    }

    if (!$PodeContext.Server.IsServerless -and ![string]::IsNullOrWhiteSpace($Description)) {
        $WebEvent.Response.StatusDescription = $Description
    }

    # if the status code is >=400 then attempt to load error page
    if (!$NoErrorPage -and ($Code -ge 400)) {
        Show-PodeErrorPage -Code $Code -Description $Description -Exception $Exception -ContentType $ContentType
    }
}

<#
.SYNOPSIS
Redirecting a user to a new URL.

.DESCRIPTION
Redirecting a user to a new URL, or the same URL as the Request but a different Protocol - or other components.

.PARAMETER Url
Redirect the user to a new URL, or a relative path.

.PARAMETER Port
Change the port of the current Request before redirecting.

.PARAMETER Protocol
Change the protocol of the current Request before redirecting.

.PARAMETER Domain
Change the domain name of the current Request before redirecting.

.PARAMETER Moved
Set the Status Code as "301 Moved", rather than "302 Redirect".

.EXAMPLE
Move-PodeResponseUrl -Url 'https://google.com'

.EXAMPLE
Move-PodeResponseUrl -Url '/about'

.EXAMPLE
Move-PodeResponseUrl -Protocol HTTPS

.EXAMPLE
Move-PodeResponseUrl -Port 9000 -Moved
#>
function Move-PodeResponseUrl
{
    [CmdletBinding(DefaultParameterSetName='Url')]
    param (
        [Parameter(Mandatory=$true, ParameterSetName='Url')]
        [string]
        $Url,

        [Parameter(ParameterSetName='Components')]
        [int]
        $Port = 0,

        [Parameter(ParameterSetName='Components')]
        [ValidateSet('', 'Http', 'Https')]
        [string]
        $Protocol,

        [Parameter(ParameterSetName='Components')]
        [string]
        $Domain,

        [switch]
        $Moved
    )

    if ($PSCmdlet.ParameterSetName -ieq 'components') {
        $uri = $WebEvent.Request.Url

        # set the protocol
        $Protocol = $Protocol.ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($Protocol)) {
            $Protocol = $uri.Scheme
        }

        # set the domain
        if ([string]::IsNullOrWhiteSpace($Domain)) {
            $Domain = $uri.Host
        }

        # set the port
        if ($Port -le 0) {
            $Port = $uri.Port
        }

        $PortStr = [string]::Empty
        if (@(80, 443) -notcontains $Port) {
            $PortStr = ":$($Port)"
        }

        # combine to form the url
        $Url = "$($Protocol)://$($Domain)$($PortStr)$($uri.PathAndQuery)"
    }

    Set-PodeHeader -Name 'Location' -Value $Url

    if ($Moved) {
        Set-PodeResponseStatus -Code 301 -Description 'Moved'
    }
    else {
        Set-PodeResponseStatus -Code 302 -Description 'Redirect'
    }
}

<#
.SYNOPSIS
Writes data to a TCP Client stream.

.DESCRIPTION
Writes data to a TCP Client stream.

.PARAMETER Message
Parameter description

.PARAMETER Client
An optional TcpClient to write data.

.EXAMPLE
Write-PodeTcpClient -Message '250 OK'
#>
function Write-PodeTcpClient
{
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $Message,

        [Parameter()]
        $Client
    )

    # error if serverless
    Test-PodeIsServerless -FunctionName 'Write-PodeTcpClient' -ThrowError

    # use the main client if one isn't supplied
    if ($null -eq $Client) {
        $Client = $TcpEvent.Client
    }

    $encoder = New-Object System.Text.ASCIIEncoding
    $buffer = $encoder.GetBytes("$($Message)`r`n")
    $stream = $Client.GetStream()
    Wait-PodeTask -Task $stream.WriteAsync($buffer, 0, $buffer.Length)
    $stream.Flush()
}

<#
.SYNOPSIS
Reads data from a TCP Client stream.

.DESCRIPTION
Reads data from a TCP Client stream.

.PARAMETER Client
An optional TcpClient from which to read data.

.EXAMPLE
$data = Read-PodeTcpClient
#>
function Read-PodeTcpClient
{
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter()]
        $Client
    )

    # error if serverless
    Test-PodeIsServerless -FunctionName 'Read-PodeTcpClient' -ThrowError

    # use the main client if one isn't supplied
    if ($null -eq $Client) {
        $Client = $TcpEvent.Client
    }

    $bytes = New-Object byte[] 8192
    $encoder = New-Object System.Text.ASCIIEncoding
    $stream = $Client.GetStream()
    $bytesRead = (Wait-PodeTask -Task $stream.ReadAsync($bytes, 0, 8192))
    return $encoder.GetString($bytes, 0, $bytesRead)
}

<#
.SYNOPSIS
Saves an uploaded file on the Request to the File System.

.DESCRIPTION
Saves an uploaded file on the Request to the File System.

.PARAMETER Key
The name of the key within the web event's Data HashTable that stores the file's name.

.PARAMETER Path
The path to save files.

.EXAMPLE
Save-PodeRequestFile -Key 'avatar'

.EXAMPLE
Save-PodeRequestFile -Key 'avatar' -Path 'F:/Images'
#>
function Save-PodeRequestFile
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]
        $Key,

        [Parameter()]
        [string]
        $Path = '.'
    )

    # if path is '.', replace with server root
    $Path = Get-PodeRelativePath -Path $Path -JoinRoot

    # ensure the parameter name exists in data
    $fileName = $WebEvent.Data[$Key]
    if ([string]::IsNullOrWhiteSpace($fileName)) {
        throw "A parameter called '$($Key)' was not supplied in the request"
    }

    # ensure the file data exists
    if (!$WebEvent.Files.ContainsKey($fileName)) {
        throw "No data for file '$($fileName)' was uploaded in the request"
    }

    # if the path is a directory, add the filename
    if (Test-PodePathIsDirectory -Path $Path) {
        $Path = Join-Path $Path $fileName
    }

    # save the file
    [System.IO.File]::WriteAllBytes($Path, $WebEvent.Files[$fileName].Bytes)
}

<#
.SYNOPSIS
Short description

.DESCRIPTION
Long description

.PARAMETER Type
The type name of the view engine (inbuilt types are: Pode and HTML).

.PARAMETER ScriptBlock
A ScriptBlock for specifying custom view engine rendering rules.

.PARAMETER Extension
A custom extension for the engine's files.

.EXAMPLE
Set-PodeViewEngine -Type HTML

.EXAMPLE
Set-PodeViewEngine -Type Markdown

.EXAMPLE
Set-PodeViewEngine -Type PSHTML -Extension PS1 -ScriptBlock { param($path, $data) /* logic */ }
#>
function Set-PodeViewEngine
{
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $Type,

        [Parameter()]
        [scriptblock]
        $ScriptBlock = $null,

        [Parameter()]
        [string]
        $Extension
    )

    # truncate markdown
    if ($Type -ieq 'Markdown') {
        $Type = 'md'
    }

    # override extension with type
    if ([string]::IsNullOrWhiteSpace($Extension)) {
        $Extension = $Type.ToLowerInvariant()
    }

    # setup view engine config
    $PodeContext.Server.ViewEngine.Type = $Type.ToLowerInvariant()
    $PodeContext.Server.ViewEngine.Extension = $Extension
    $PodeContext.Server.ViewEngine.Script = $ScriptBlock
    $PodeContext.Server.ViewEngine.IsDynamic = (@('html', 'md') -inotcontains $Type)
}

<#
.SYNOPSIS
Includes the contents of a partial View into another dynamic View.

.DESCRIPTION
Includes the contents of a partial View into another dynamic View. The partial View can be static or dynamic.

.PARAMETER Path
The path to a partial View, relative to the "/views" directory. (Extension is optional).

.PARAMETER Data
Any dynamic data to supply to a dynamic partial View.

.EXAMPLE
Use-PodePartialView -Path 'shared/footer'
#>
function Use-PodePartialView
{
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory=$true)]
        [string]
        $Path,

        [Parameter()]
        $Data = @{}
    )

    # default data if null
    if ($null -eq $Data) {
        $Data = @{}
    }

    # add view engine extension
    $ext = Get-PodeFileExtension -Path $Path
    if ([string]::IsNullOrWhiteSpace($ext)) {
        $Path += ".$($PodeContext.Server.ViewEngine.Extension)"
    }

    # only look in the view directory
    $Path = (Join-Path $PodeContext.Server.InbuiltDrives['views'] $Path)

    # test the file path, and set status accordingly
    if (!(Test-PodePath $Path -NoStatus)) {
        throw "File not found at path: $($Path)"
    }

    # run any engine logic
    return (Get-PodeFileContentUsingViewEngine -Path $Path -Data $Data)
}