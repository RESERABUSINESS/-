# صاحي — يمنع جهاز ويندوز من النوم (حتى مع إغلاق الغطاء)
# يعيش في شريط المهام بجانب الساعة. شغّله عبر Sahi.bat
# المتطلبات: Windows 10/11، PowerShell 5.1 (موجود افتراضياً)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------- واجهة Win32 لمنع النوم ----------
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Power {
    [DllImport("kernel32.dll")]
    public static extern uint SetThreadExecutionState(uint esFlags);
    public const uint ES_CONTINUOUS        = 0x80000000;
    public const uint ES_SYSTEM_REQUIRED   = 0x00000001;
    public const uint ES_DISPLAY_REQUIRED  = 0x00000002;
    public const uint ES_AWAYMODE_REQUIRED = 0x00000040;
}
"@

$StateDir   = Join-Path $env:APPDATA "Sahi"
$BackupFile = Join-Path $StateDir "lid-backup.json"
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

# GUIDs ثابتة في ويندوز: قسم أزرار الطاقة، وإعداد «عند إغلاق الغطاء»
$SUB_BUTTONS = "4f971e89-eebd-4455-a8de-9e59040e7347"
$LIDACTION   = "5ca83367-6e45-459f-a27b-476b1d01c936"

function Get-LidAction([string]$kind) {
    # kind = AC أو DC ؛ يرجع 0 لا شيء، 1 سكون، 2 إسبات، 3 إيقاف
    $out = powercfg /query SCHEME_CURRENT $SUB_BUTTONS $LIDACTION 2>$null
    $label = if ($kind -eq "AC") { "AC Power Setting Index" } else { "DC Power Setting Index" }
    $line = $out | Where-Object { $_ -match $label } | Select-Object -First 1
    if ($line -match "0x([0-9a-fA-F]+)") { return [Convert]::ToInt32($Matches[1], 16) }
    return 1
}

function Set-LidAction([int]$ac, [int]$dc) {
    powercfg /setacvalueindex SCHEME_CURRENT $SUB_BUTTONS $LIDACTION $ac | Out-Null
    powercfg /setdcvalueindex SCHEME_CURRENT $SUB_BUTTONS $LIDACTION $dc | Out-Null
    powercfg /setactive SCHEME_CURRENT | Out-Null
}

function Restore-Lid {
    if (Test-Path $BackupFile) {
        try {
            $b = Get-Content $BackupFile -Raw | ConvertFrom-Json
            Set-LidAction $b.ac $b.dc
        } catch {}
        Remove-Item $BackupFile -Force -ErrorAction SilentlyContinue
    }
}

# تعافٍ ذاتي: لو انقفل التطبيق فجأة المرة الماضية، رجّع إعداد الغطاء
Restore-Lid

# ---------- الحالة ----------
$script:Mode    = "off"      # off | awake | lid | timer
$script:EndTime = $null

function Apply-State {
    switch ($script:Mode) {
        "off" {
            [Power]::SetThreadExecutionState([Power]::ES_CONTINUOUS) | Out-Null
            Restore-Lid
        }
        "awake" {
            Restore-Lid
            [Power]::SetThreadExecutionState([Power]::ES_CONTINUOUS -bor [Power]::ES_SYSTEM_REQUIRED -bor [Power]::ES_DISPLAY_REQUIRED) | Out-Null
        }
        "timer" {
            Restore-Lid
            [Power]::SetThreadExecutionState([Power]::ES_CONTINUOUS -bor [Power]::ES_SYSTEM_REQUIRED -bor [Power]::ES_DISPLAY_REQUIRED) | Out-Null
        }
        "lid" {
            if (-not (Test-Path $BackupFile)) {
                @{ ac = (Get-LidAction "AC"); dc = (Get-LidAction "DC") } | ConvertTo-Json | Set-Content $BackupFile
            }
            Set-LidAction 0 0   # 0 = لا تفعل شيئاً عند إغلاق الغطاء
            [Power]::SetThreadExecutionState([Power]::ES_CONTINUOUS -bor [Power]::ES_SYSTEM_REQUIRED -bor [Power]::ES_AWAYMODE_REQUIRED) | Out-Null
        }
    }
    Update-Ui
}

# ---------- أيقونة: كوب يمتلئ ----------
function New-CupIcon([double]$fill) {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = "AntiAlias"
    $g.Clear([System.Drawing.Color]::Transparent)
    $outline = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 245, 235, 220)), 2.5
    $coffee  = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 214, 168, 92))
    # جسم الكوب
    $cup = New-Object System.Drawing.Rectangle 5, 9, 18, 18
    if ($fill -gt 0) {
        $h = [int](16 * $fill)
        $g.FillRectangle($coffee, 6, 26 - $h, 16, $h)
    }
    $g.DrawRectangle($outline, $cup)
    # المقبض
    $g.DrawArc($outline, 20, 12, 8, 10, -90, 180)
    # بخار عند التشغيل
    if ($fill -gt 0) {
        $g.DrawBezier($outline, 10, 7, 8, 5, 12, 3, 10, 1)
        $g.DrawBezier($outline, 16, 7, 14, 5, 18, 3, 16, 1)
    }
    $g.Dispose()
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

$IconOff  = New-CupIcon 0
$IconHalf = New-CupIcon 0.5
$IconFull = New-CupIcon 1

# ---------- القائمة ----------
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Visible = $true
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.RightToLeft = "Yes"

$miStatus = $menu.Items.Add("الجهاز يقدر ينام")
$miStatus.Enabled = $false
$menu.Items.Add("-") | Out-Null

$miAwake = $menu.Items.Add("صاحي — ما ينام والغطاء مفتوح")
$miLid   = $menu.Items.Add("سهران — ما ينام حتى لو سكّرت الغطاء")
$miTimer = New-Object System.Windows.Forms.ToolStripMenuItem "صاحي لمدة…"
$menu.Items.Add($miTimer) | Out-Null
foreach ($m in 15, 30, 60, 180) {
    $label = switch ($m) { 15 {"ربع ساعة"} 30 {"نص ساعة"} 60 {"ساعة"} 180 {"ثلاث ساعات"} }
    $item = $miTimer.DropDownItems.Add($label)
    $item.Tag = $m
    $item.Add_Click({
        $script:Mode = "timer"
        $script:EndTime = (Get-Date).AddMinutes($this.Tag)
        Apply-State
    })
}
$miOff = $menu.Items.Add("خلّه ينام")
$menu.Items.Add("-") | Out-Null

$StartupLnk = Join-Path ([Environment]::GetFolderPath("Startup")) "Sahi.lnk"
$miStartup = New-Object System.Windows.Forms.ToolStripMenuItem "يشتغل مع ويندوز"
$miStartup.Checked = Test-Path $StartupLnk
$menu.Items.Add($miStartup) | Out-Null
$miQuit = $menu.Items.Add("خروج")

$tray.ContextMenuStrip = $menu
$tray.Add_MouseClick({ if ($_.Button -eq "Left") { $menu.Show([System.Windows.Forms.Cursor]::Position) } })

function Update-Ui {
    switch ($script:Mode) {
        "off"   { $tray.Icon = $IconOff;  $t = "الجهاز يقدر ينام" }
        "awake" { $tray.Icon = $IconFull; $t = "صاحي — والغطاء مفتوح" }
        "lid"   { $tray.Icon = $IconFull; $t = "سهران — حتى مع إغلاق الغطاء" }
        "timer" {
            $tray.Icon = $IconHalf
            $left = [int][Math]::Ceiling(($script:EndTime - (Get-Date)).TotalMinutes)
            $t = "صاحي — باقي $left دقيقة"
        }
    }
    $miStatus.Text = $t
    $tray.Text = "صاحي: " + $t
    $miAwake.Checked = ($script:Mode -eq "awake")
    $miLid.Checked   = ($script:Mode -eq "lid")
    $miTimer.Checked = ($script:Mode -eq "timer")
    $miOff.Checked   = ($script:Mode -eq "off")
}

$miAwake.Add_Click({ $script:Mode = "awake"; Apply-State })
$miLid.Add_Click({
    $script:Mode = "lid"; Apply-State
    $tray.ShowBalloonTip(4000, "صاحي", "تقدر تسكّر الغطاء والجهاز يكمّل شغله. تأكد إن الشاحن موصول والجهاز مو داخل شنطة مقفلة.", "Info")
})
$miOff.Add_Click({ $script:Mode = "off"; Apply-State })
$miStartup.Add_Click({
    if (Test-Path $StartupLnk) {
        Remove-Item $StartupLnk -Force
    } else {
        $ws = New-Object -ComObject WScript.Shell
        $lnk = $ws.CreateShortcut($StartupLnk)
        $lnk.TargetPath = "powershell.exe"
        $lnk.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        $lnk.Save()
    }
    $miStartup.Checked = Test-Path $StartupLnk
})
$miQuit.Add_Click({
    $script:Mode = "off"; Apply-State
    $tray.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})

# مؤقت: ينهي «صاحي لمدة» ويجدد طلب اليقظة كل 30 ثانية
$tick = New-Object System.Windows.Forms.Timer
$tick.Interval = 30000
$tick.Add_Tick({
    if ($script:Mode -eq "timer" -and (Get-Date) -ge $script:EndTime) {
        $script:Mode = "off"
        $tray.ShowBalloonTip(3000, "صاحي", "خلص الوقت، الجهاز يقدر ينام الحين.", "Info")
    }
    Apply-State
})
$tick.Start()

# لو انطفى ويندوز أو سجّلت خروج: رجّع الإعدادات
[System.AppDomain]::CurrentDomain.Add_ProcessExit({ Restore-Lid })

Apply-State
[System.Windows.Forms.Application]::Run()
