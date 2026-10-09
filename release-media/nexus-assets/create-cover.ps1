Add-Type -AssemblyName System.Drawing
$bitmap = [Drawing.Bitmap]::new(1920, 1080)
$graphics = [Drawing.Graphics]::FromImage($bitmap)
$graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
$graphics.TextRenderingHint = [Drawing.Text.TextRenderingHint]::AntiAliasGridFit
$graphics.Clear([Drawing.ColorTranslator]::FromHtml('#111B20'))
$orange = [Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml('#FF713E'))
$white = [Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml('#F4F1E9'))
$muted = [Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml('#9FAFB4'))
$grid = [Drawing.Pen]::new([Drawing.ColorTranslator]::FromHtml('#24353D'), 2)
for ($x = 0; $x -lt 1920; $x += 80) { $graphics.DrawLine($grid, $x, 0, $x, 1080) }
for ($y = 0; $y -lt 1080; $y += 80) { $graphics.DrawLine($grid, 0, $y, 1920, $y) }
$graphics.FillRectangle($orange, 96, 92, 12, 60)
function Label([string]$Text, [float]$Size, [float]$X, [float]$Y, $Brush, [Drawing.FontStyle]$Style = [Drawing.FontStyle]::Regular) {
    $font = [Drawing.Font]::new('Bahnschrift', $Size, $Style, [Drawing.GraphicsUnit]::Pixel)
    try { $graphics.DrawString($Text, $font, $Brush, $X, $Y) } finally { $font.Dispose() }
}
Label 'WORLD WAR Z: AFTERMATH  /  UNOFFICIAL MOD' 31 135 99 $muted
Label 'ZEKE' 145 90 222 $white ([Drawing.FontStyle]::Bold)
Label 'SURGE' 145 90 364 $white ([Drawing.FontStyle]::Bold)
Label 'x90' 305 1130 238 $orange ([Drawing.FontStyle]::Bold)
Label 'REWARD SCALING' 43 1128 591 $white
$graphics.FillRectangle($orange, 100, 575, 610, 6)
Label 'SELECTED PVE + WEAPON REWARDS' 36 95 635 $white
Label 'INSTALL  /  VERIFY  /  RESTORE' 31 98 702 $muted
Label 'Effects vary by reward path.' 27 1129 658 $muted
$graphics.DrawLine($grid, 100, 865, 1820, 865)
Label 'V4.1' 37 98 915 $orange ([Drawing.FontStyle]::Bold)
Label 'STEAM BUILD 23892411' 32 280 920 $white
Label 'aeoux5 / kuma0128' 27 1500 925 $muted
$bitmap.Save((Join-Path $PSScriptRoot 'zeke-surge-cover.png'), [Drawing.Imaging.ImageFormat]::Png)
$grid.Dispose()
$orange.Dispose()
$white.Dispose()
$muted.Dispose()
$graphics.Dispose()
$bitmap.Dispose()
