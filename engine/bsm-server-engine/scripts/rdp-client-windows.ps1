param(
  [string]$Hostname = "rdp.example.com",
  [int]$LocalPort = 13389
)
$ErrorActionPreference = "Stop"
if (-not (Get-Command cloudflared -ErrorAction SilentlyContinue)) {
  throw "cloudflared is not installed or is not in PATH."
}
Write-Host "Starting Cloudflare Access RDP tunnel on localhost:$LocalPort ..."
$proc = Start-Process -PassThru -WindowStyle Normal cloudflared `
  -ArgumentList @("access","rdp","--hostname",$Hostname,"--url","rdp://localhost:$LocalPort")
Start-Sleep -Seconds 3
Start-Process mstsc.exe -ArgumentList "/v:localhost:$LocalPort"
Write-Host "Keep cloudflared running while the RDP session is active."
