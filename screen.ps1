# screen.ps1 — 屏幕视觉器官
#
# 把屏幕抓成 PNG，供 read_image 读取。静态帧，不是视频流。
#
# 用法：
#   .\screen.ps1                        # 主屏
#   .\screen.ps1 -All                   # 所有屏拼成一张
#   .\screen.ps1 -Monitor 2             # 第 N 块屏（1 起）
#   .\screen.ps1 -Region 100,200,800,600
#   .\screen.ps1 -MaxWidth 1280         # 缩放到指定宽度（减小体积，加快读取）
#   .\screen.ps1 -Foreground            # 只抓当前前台窗口
#   .\screen.ps1 -Out D:\shot.png
#
# 输出：一行 JSON，含路径、尺寸、缩放比、耗时。
#
# 注意：需要交互式桌面会话。锁屏或 RDP 断开时会抓到黑屏或失败。

[CmdletBinding()]
param(
  [switch]$All,
  [int]$Monitor = 0,
  [int[]]$Region = @(),
  [int]$MaxWidth = 0,
  [switch]$Foreground,
  [string]$Out = (Join-Path $env:TEMP 'dsh-screen.png')
)

$ErrorActionPreference = 'Stop'
$started = Get-Date
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 前台窗口的矩形，供 -Foreground 使用
if ($Foreground) {
  if (-not ('Win32Rect' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public class Win32Rect {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  public static int[] Get() {
    IntPtr h = GetForegroundWindow();
    RECT r;
    if (!GetWindowRect(h, out r)) throw new Exception("GetWindowRect failed");
    return new int[] { r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top };
  }
}
'@
  }
  $r = [Win32Rect]::Get()
  if ($r[2] -le 0 -or $r[3] -le 0) { throw '前台窗口矩形无效（可能已最小化）' }
  $Region = $r
}

# 计算采集区域
if ($Region.Count -eq 4) {
  $x = $Region[0]; $y = $Region[1]; $w = $Region[2]; $h = $Region[3]
  $scope = 'region'
}
elseif ($All) {
  $x = [System.Windows.Forms.SystemInformation]::VirtualScreen.X
  $y = [System.Windows.Forms.SystemInformation]::VirtualScreen.Y
  $w = [System.Windows.Forms.SystemInformation]::VirtualScreen.Width
  $h = [System.Windows.Forms.SystemInformation]::VirtualScreen.Height
  $scope = 'virtual-screen'
}
else {
  $screens = [System.Windows.Forms.Screen]::AllScreens
  $target = if ($Monitor -ge 1 -and $Monitor -le $screens.Count) { $screens[$Monitor - 1] } else { [System.Windows.Forms.Screen]::PrimaryScreen }
  $x = $target.Bounds.X; $y = $target.Bounds.Y
  $w = $target.Bounds.Width; $h = $target.Bounds.Height
  $scope = "monitor:$($target.DeviceName)"
}

if ($w -le 0 -or $h -le 0) { throw "采集区域无效：${w}x${h}" }

# 抓取
$bmp = New-Object System.Drawing.Bitmap($w, $h)
try {
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  try {
    $g.CopyFromScreen((New-Object System.Drawing.Point($x, $y)), [System.Drawing.Point]::Empty, (New-Object System.Drawing.Size($w, $h)))
  }
  finally { $g.Dispose() }

  $scale = 1.0
  $final = $bmp
  if ($MaxWidth -gt 0 -and $w -gt $MaxWidth) {
    $scale = $MaxWidth / $w
    $nw = [int][Math]::Round($w * $scale)
    $nh = [int][Math]::Round($h * $scale)
    $resized = New-Object System.Drawing.Bitmap($nw, $nh)
    $rg = [System.Drawing.Graphics]::FromImage($resized)
    try {
      $rg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
      $rg.DrawImage($bmp, 0, 0, $nw, $nh)
    }
    finally { $rg.Dispose() }
    $final = $resized
  }

  $dir = Split-Path -Parent $Out
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $final.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
  $outW = $final.Width; $outH = $final.Height
  if ($final -ne $bmp) { $final.Dispose() }
}
finally { $bmp.Dispose() }

$fi = Get-Item -LiteralPath $Out
$result = [ordered]@{
  path      = $fi.FullName
  scope     = $scope
  origin    = "$x,$y"
  captured  = "${w}x${h}"
  saved     = "${outW}x${outH}"
  scale     = [Math]::Round($scale, 3)
  bytes     = $fi.Length
  elapsedMs = [int]((Get-Date) - $started).TotalMilliseconds
}
$result | ConvertTo-Json -Compress
