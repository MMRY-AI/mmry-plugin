@echo off
rem #31245 QA round 2/3: THIS UNINSTALLER IS CLAUDE CODE'S, AND SAYS SO RATHER THAN GUESSING.
rem
rem Everything below names ~/.claude: the credential, the state directory, the plugin cache, the
rem settings file, and the closing line telling the customer to restart Claude Code.
rem session-init.sh copies setup/*.bat into the host MMRY directory, so on Windows Codex a copy of
rem this file lands under the Codex home - where running it would uninstall the OTHER product and
rem leave the Codex install untouched. It refuses instead of doing that quietly.
rem
rem ROUND 3 ADDED THE FIRST TWO TESTS. The third - a literal ".codex" in the path - is the only one
rem that existed, and a customer who relocated their Codex home has no such segment: the guard did
rem not fire and the full Claude uninstall proceeded. The marker file is written by session-init.sh
rem beside the handlers it installs and is the only signal that survives a relocated home with
rem nothing exported; CODEX_HOME covers the case where the variable IS present.
set "MMRY_SELF_DIR=%~dp0"

rem 1. The marker the install wrote about itself, at <state-dir>\.mmry-host. %~dp0 ends with a
rem    backslash, so this resolves to the parent of setup\.
if exist "%~dp0..\.mmry-host" (
  findstr /i /l /c:"codex" "%~dp0..\.mmry-host" >nul
  if not errorlevel 1 goto :codex_install
)

rem 2. A CODEX_HOME this copy sits inside. Skipped when the variable is empty - findstr with an
rem    empty pattern matches everything, which would refuse on every machine.
rem
rem    THE TRAILING BACKSLASH IS STRIPPED FIRST (#31245 QA round 4). This is the same defect the
rem    comment under test 3 below documents for the literal pattern, and it was never applied
rem    here: with CODEX_HOME=C:\Users\x\.codex\ the expansion ends ...\.codex\", the \" escapes
rem    the closing quote, and findstr receives a pattern that can never match. The guard silently
rem    did nothing and the full CLAUDE uninstall proceeded on a Codex machine. A trailing
rem    backslash is what tab-completion in cmd hands you, so this is a common spelling rather
rem    than an exotic one. The loop strips repeats and will not strip the value away to nothing.
set "MMRY_CODEX_HOME=%CODEX_HOME%"
:strip_codex_home_sep
if not defined MMRY_CODEX_HOME goto :done_strip_codex_home
if "%MMRY_CODEX_HOME%"=="\" goto :done_strip_codex_home
if "%MMRY_CODEX_HOME:~-1%"=="\" (
  set "MMRY_CODEX_HOME=%MMRY_CODEX_HOME:~0,-1%"
  goto :strip_codex_home_sep
)
if "%MMRY_CODEX_HOME:~-1%"=="/" (
  set "MMRY_CODEX_HOME=%MMRY_CODEX_HOME:~0,-1%"
  goto :strip_codex_home_sep
)
:done_strip_codex_home
if defined MMRY_CODEX_HOME (
  echo "%MMRY_SELF_DIR%" | findstr /i /l /c:"%MMRY_CODEX_HOME%" >nul
  if not errorlevel 1 goto :codex_install
)

rem 3. The default Codex home, and any path segment that is literally ".codex".
rem The pattern deliberately has no TRAILING backslash: in a cmd string, \" escapes the quote,
rem and findstr then receives a pattern that never matches - which is how the first version of
rem this guard silently did nothing. /l keeps it a literal, not a regex.
echo "%MMRY_SELF_DIR%" | findstr /i /l /c:"\.codex" >nul
if %ERRORLEVEL% EQU 0 goto :codex_install

powershell.exe -ExecutionPolicy Bypass -Command ^
  "$settingsPath = Join-Path $env:USERPROFILE '.claude\settings.json';" ^
  "$configPath = Join-Path $env:USERPROFILE '.claude\mmry-config.json';" ^
  "$pluginNames = @('mmry@mmry-plugin', 'mmry@internal-plugins');" ^
  "$marketplaceNames = @('mmry-plugin', 'internal-plugins');" ^
  "$mmryPerms = @(" ^
  "  'Bash(*save-memory.sh*)'," ^
  "  'Bash(*reinforce-memory.sh*)'," ^
  "  'Bash(*deactivate-memory.sh*)'," ^
  "  'Bash(*link-memories.sh*)'," ^
  "  'Bash(*search-memories.sh*)'," ^
  "  'Bash(*mmry-client.sh*)'" ^
  ");" ^
  "" ^
  "Write-Host ''; Write-Host '=== MMRY AI Uninstall ===' -ForegroundColor Cyan; Write-Host '';" ^
  "" ^
  "# Remove config file" ^
  "if (Test-Path $configPath) {" ^
  "  Remove-Item $configPath -Force;" ^
  "  Write-Host '  Removed mmry-config.json'" ^
  "} else {" ^
  "  Write-Host '  No config file found (already removed).'" ^
  "}" ^
  "" ^
  "# Clean settings.json" ^
  "if (-not (Test-Path $settingsPath)) {" ^
  "  Write-Host '  No settings.json found.'" ^
  "} else {" ^
  "  $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json;" ^
  "  $changed = $false;" ^
  "" ^
  "  # Remove plugin entries" ^
  "  foreach ($name in $pluginNames) {" ^
  "    if ($settings.PSObject.Properties['enabledPlugins'] -and $settings.enabledPlugins.PSObject.Properties[$name]) {" ^
  "      $settings.enabledPlugins.PSObject.Properties.Remove($name);" ^
  "      $changed = $true" ^
  "    }" ^
  "  }" ^
  "  if ($settings.PSObject.Properties['enabledPlugins'] -and $settings.enabledPlugins.PSObject.Properties.Count -eq 0) {" ^
  "    $settings.PSObject.Properties.Remove('enabledPlugins')" ^
  "  }" ^
  "" ^
  "  # Remove marketplace entries" ^
  "  foreach ($name in $marketplaceNames) {" ^
  "    if ($settings.PSObject.Properties['extraKnownMarketplaces'] -and $settings.extraKnownMarketplaces.PSObject.Properties[$name]) {" ^
  "      $settings.extraKnownMarketplaces.PSObject.Properties.Remove($name);" ^
  "      $changed = $true" ^
  "    }" ^
  "  }" ^
  "  if ($settings.PSObject.Properties['extraKnownMarketplaces'] -and $settings.extraKnownMarketplaces.PSObject.Properties.Count -eq 0) {" ^
  "    $settings.PSObject.Properties.Remove('extraKnownMarketplaces')" ^
  "  }" ^
  "" ^
  "  # Re-enable built-in auto memory" ^
  "  if ($settings.PSObject.Properties['autoMemoryEnabled']) {" ^
  "    $settings.PSObject.Properties.Remove('autoMemoryEnabled');" ^
  "    $changed = $true" ^
  "  }" ^
  "" ^
  "  # Remove MMRY AI permissions" ^
  "  if ($settings.PSObject.Properties['permissions'] -and $settings.permissions.PSObject.Properties['allow']) {" ^
  "    $settings.permissions.allow = @($settings.permissions.allow | Where-Object { $_ -notin $mmryPerms });" ^
  "    $changed = $true;" ^
  "    if ($settings.permissions.allow.Count -eq 0) {" ^
  "      $settings.permissions.PSObject.Properties.Remove('allow')" ^
  "    }" ^
  "    if ($settings.permissions.PSObject.Properties.Count -eq 0) {" ^
  "      $settings.PSObject.Properties.Remove('permissions')" ^
  "    }" ^
  "  }" ^
  "" ^
  "  if ($changed) {" ^
  "    $settings | ConvertTo-Json -Depth 10 | Set-Content $settingsPath -Encoding UTF8;" ^
  "    Write-Host '  Cleaned settings.json (plugin, marketplace, permissions)'" ^
  "  } else {" ^
  "    Write-Host '  No MMRY AI entries found in settings.json.'" ^
  "  }" ^
  "}" ^
  "" ^
  "# Remove stable hooks directory" ^
  "$mmryDir = Join-Path $env:USERPROFILE '.claude\mmry';" ^
  "if (Test-Path $mmryDir) {" ^
  "  Remove-Item $mmryDir -Recurse -Force;" ^
  "  Write-Host '  Removed ~/.claude/mmry/'" ^
  "}" ^
  "" ^
  "# Clear plugin cache" ^
  "foreach ($cacheName in @('mmry-plugin', 'internal-plugins')) {" ^
  "  $cacheDir = Join-Path $env:USERPROFILE \".claude\\plugins\\cache\\$cacheName\\mmry\";" ^
  "  if (Test-Path $cacheDir) {" ^
  "    Remove-Item $cacheDir -Recurse -Force;" ^
  "    Write-Host \"  Cleared plugin cache ($cacheName)\"" ^
  "  }" ^
  "}" ^
  "" ^
  "Write-Host '';" ^
  "Write-Host 'MMRY AI uninstalled.' -ForegroundColor Green;" ^
  "Write-Host 'Restart Claude Code to take effect.';" ^
  "Write-Host ''"

exit /b 0

:codex_install
echo.
echo MMRY AI: this script uninstalls the CLAUDE CODE installation, and you are running the copy
echo that was placed in your Codex directory. It has changed nothing.
echo.
echo To remove MMRY from Codex: remove the plugin through Codex, then delete the mmry-config.json
echo and mmry directory inside your Codex home (%%CODEX_HOME%%, or %USERPROFILE%\.codex).
echo.
exit /b 1
