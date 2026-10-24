# Builds guide.html (the public "guide book" page) from the markdown notes in ../reports.
# The tab list lives in guide_docs.json so this script stays ASCII (PowerShell 5.1 misreads
# BOM-less UTF-8 scripts). Blocks wrapped in <!-- PRIVATE_OPEN --> ... <!-- PRIVATE_CLOSE -->
# (written in Japanese in the notes) are removed before publishing.
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$reports = Join-Path (Split-Path $here -Parent) 'reports'
$utf8 = New-Object System.Text.UTF8Encoding($false)

$private = [string]::Concat([char]0x975E, [char]0x516C, [char]0x958B)
$privateBlock = '(?s)<!--\s*' + $private + '\s*-->.*?<!--\s*/' + $private + '\s*-->\r?\n?'

$config = Get-Content -LiteralPath (Join-Path $here 'guide_docs.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$docs = @()
foreach ($c in $config) {
    $path = Join-Path $reports $c.path
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing note: $path" }
    $md = [System.IO.File]::ReadAllText($path, $utf8)
    $md = [regex]::Replace($md, $privateBlock, '')
    # Safety net: never publish local paths or an unclosed private block.
    if ($md -match '[A-Za-z]:\\Users\\' -or $md -match ('<!--\s*/?' + $private)) { throw "Private content left in $($c.path)" }
    $docs += [ordered]@{ id = $c.id; tab = $c.tab; title = $c.title; file = (Split-Path $c.path -Leaf); md = $md }
}

$data = [ordered]@{ built = (Get-Date -Format 'yyyy-MM-dd HH:mm'); docs = $docs }
# ConvertTo-Json escapes < > & as < etc., so the payload cannot close the script tag.
$json = $data | ConvertTo-Json -Depth 4 -Compress

$template = [System.IO.File]::ReadAllText((Join-Path $here 'guide_template.html'), $utf8)
$placeholder = '/*__GUIDE_DATA__*/{"built":"","docs":[]}'
if (-not $template.Contains($placeholder)) { throw 'Placeholder not found in guide_template.html' }
$html = $template.Replace($placeholder, $json)
[System.IO.File]::WriteAllText((Join-Path $here 'guide.html'), $html, $utf8)
"guide.html: $($docs.Count) notes, $([math]::Round($html.Length / 1024)) KB"
