# Auto-install libraries for MoonLoader (mimgui and SAMP.Lua)
$libPath = "G:\gta\moonloader\lib"

Write-Host "Creating lib directory..."
New-Item -ItemType Directory -Force -Path $libPath

# 1. Download and install mimgui
Write-Host "Downloading mimgui..."
$mimguiUrl = "https://github.com/THE-FYP/mimgui/releases/download/v1.7.0/mimgui-v1.7.0.zip"
$mimguiZip = "$env:TEMP\mimgui.zip"
Invoke-WebRequest -Uri $mimguiUrl -OutFile $mimguiZip

Write-Host "Extracting mimgui..."
$mimguiTemp = "$env:TEMP\mimgui_extracted"
Expand-Archive -Path $mimguiZip -DestinationPath $mimguiTemp -Force
Copy-Item -Path "$mimguiTemp\mimgui" -Destination $libPath -Recurse -Force
Copy-Item -Path "$mimguiTemp\mimgui.dll" -Destination $libPath -Force

# 2. Download and install SAMP.Lua
Write-Host "Downloading SAMP.Lua..."
$sampLuaUrl = "https://github.com/THE-FYP/SAMP.Lua/archive/refs/heads/master.zip"
$sampLuaZip = "$env:TEMP\samplua.zip"
Invoke-WebRequest -Uri $sampLuaUrl -OutFile $sampLuaZip

Write-Host "Extracting SAMP.Lua..."
$sampLuaTemp = "$env:TEMP\samplua_extracted"
Expand-Archive -Path $sampLuaZip -DestinationPath $sampLuaTemp -Force
Copy-Item -Path "$sampLuaTemp\SAMP.Lua-master\samp" -Destination $libPath -Recurse -Force

# Cleanup
Write-Host "Cleaning up temp files..."
Remove-Item $mimguiZip -Force
Remove-Item $mimguiTemp -Recurse -Force
Remove-Item $sampLuaZip -Force
Remove-Item $sampLuaTemp -Recurse -Force

Write-Host "All libraries installed successfully!"
