<#
.SYNOPSIS
  Packages the MapGit Openplanet plugin into a distributable .op file.

.EXAMPLE
  ./build.ps1              # -> dist/mapgit-<version>.op
  ./build.ps1 -Prerelease  # -> dist/mapgit-<version>-prerelease.op, shown as "MapGit (Prerelease)"
#>
param(
    [switch]$Prerelease
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$root = $PSScriptRoot
$src = Join-Path $root 'plugin/tm-mapgit'
$dist = Join-Path $root 'dist'
$infoPath = Join-Path $src 'info.toml'

$info = Get-Content $infoPath -Raw
$name = [regex]::Match($info, '(?m)^name\s*=\s*"([^"]+)"').Groups[1].Value
$version = [regex]::Match($info, '(?m)^version\s*=\s*"([^"]+)"').Groups[1].Value
if (-not $name -or -not $version) { throw "Could not read name/version from $infoPath" }

$slug = ($name.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
$suffix = if ($Prerelease) { '-prerelease' } else { '' }
$outFile = Join-Path $dist "$slug-$version$suffix.op"

New-Item -ItemType Directory -Force -Path $dist | Out-Null
if (Test-Path $outFile) { Remove-Item $outFile -Force }

$excluded = @('*_Test.as', '*_Tests.as', '*.disabled', '*.snippets')
$files = Get-ChildItem -Path $src -Recurse -File | Where-Object {
    $f = $_
    -not ($excluded | Where-Object { $f.Name -like $_ })
}

# Openplanet reads the .op as a zip with info.toml at its root; entry paths must use '/'.
$zip = [System.IO.Compression.ZipFile]::Open($outFile, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($file in $files) {
        $entryName = $file.FullName.Substring($src.Length).TrimStart('\', '/') -replace '\\', '/'
        if ($Prerelease -and $entryName -eq 'info.toml') {
            $text = (Get-Content $file.FullName -Raw) -replace '(?m)^(name\s*=\s*")([^"]+)"', '$1$2 (Prerelease)"'
            $entry = $zip.CreateEntry($entryName)
            $writer = New-Object System.IO.StreamWriter($entry.Open())
            try { $writer.Write($text) } finally { $writer.Dispose() }
        } else {
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $file.FullName, $entryName) | Out-Null
        }
    }
} finally {
    $zip.Dispose()
}

Write-Host "Built $name $version$suffix -> $outFile ($($files.Count) files)" -ForegroundColor Green
