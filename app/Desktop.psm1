Set-StrictMode -Version 2.0

function Assert-RebeccaOutputRoot {
    param([Parameter(Mandatory=$true)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if ([IO.Path]::GetPathRoot($full) -ine 'D:\') { throw 'Rebecca runtime output must be on D:.' }
    return $full
}

function New-RebeccaUnavailable {
    param([string]$Mode, [string]$Message, [string]$State = 'offline')
    return [pscustomobject]@{
        schema_version = 1; observed_at = [DateTimeOffset]::UtcNow.ToString('o')
        mode = $Mode; state = $State; message = $Message
        source = [pscustomobject]@{kind='desktop'; version=''; health='error'}
        counts = [pscustomobject]@{working=0; waiting_user=0; pending=0; failed=0}
        event = $null
    }
}

function Get-RebeccaSnapshot {
    param([string]$Path, [double]$PollSeconds = 2, [ValidateSet('live','demo')][string]$Mode = 'live', [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow)
    if (-not [IO.File]::Exists($Path)) { return New-RebeccaUnavailable $Mode '正在等待状态采集器…' }
    $stream = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        if ($stream.Length -gt 65536 -or $stream.Length -lt 2) { throw 'Invalid snapshot length.' }
        # Bound the actual read too: another writer could grow a file after the length check.
        $bytes=New-Object byte[] 65537; $total=0
        while($total -lt $bytes.Length){$read=$stream.Read($bytes,$total,$bytes.Length-$total);if($read -eq 0){break};$total+=$read}
        if($total -gt 65536){throw 'Invalid snapshot length.'}
        $utf8=New-Object Text.UTF8Encoding($false,$true)
        $text=$utf8.GetString($bytes,0,$total).TrimStart([char]0xFEFF)
        $snapshot = $text | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $snapshot -or $snapshot -is [array]) { throw 'Expected snapshot object.' }
        if (($snapshot.schema_version -isnot [int] -and $snapshot.schema_version -isnot [long]) -or $snapshot.schema_version -ne 1) { throw 'Unsupported schema.' }
        if ($snapshot.mode -isnot [string] -or $snapshot.mode -cne $Mode) { throw 'Wrong snapshot mode.' }
        if ($snapshot.state -isnot [string] -or $snapshot.state -cnotin @('idle','working','attention','success','error','stopped','offline','incompatible')) { throw 'Unknown state.' }
        if ($snapshot.message -isnot [string] -or $snapshot.message.Length -gt 240) { throw 'Invalid message.' }
        if ($snapshot.source.kind -isnot [string] -or $snapshot.source.kind.Length -gt 80) { throw 'Invalid source.' }
        if ($snapshot.source.version -isnot [string] -or $snapshot.source.version.Length -gt 80) { throw 'Invalid source version.' }
        if ($snapshot.source.health -cnotin @('connected','disconnected','error','incompatible')) { throw 'Invalid source health.' }
        foreach ($key in @('working','waiting_user','pending','failed')) {
            $count = $snapshot.counts.$key
            if (($count -isnot [int] -and $count -isnot [long]) -or $count -lt 0 -or $count -gt 100000) { throw 'Invalid count.' }
        }
        if ($snapshot.observed_at -isnot [string] -or $snapshot.observed_at -notmatch '(Z|[+-]\d\d:\d\d)$') { throw 'Invalid timestamp.' }
        $stamp = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse($snapshot.observed_at, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$stamp)) { throw 'Invalid timestamp.' }
        $age = ($Now - $stamp).TotalSeconds
        if ($age -lt -30) { throw 'Snapshot is from the future.' }
        if ($age -gt [Math]::Max(10, 3 * $PollSeconds)) { return New-RebeccaUnavailable $Mode '状态已过期，采集器可能已停止。' }
        if ($snapshot.source.health -ne 'connected' -and $snapshot.state -cnotin @('offline','incompatible','error')) { throw 'Inconsistent source health.' }
        if ($null -ne $snapshot.event) {
            if ($snapshot.event.id -isnot [string] -or $snapshot.event.id.Length -gt 256 -or $snapshot.event.kind -isnot [string]) { throw 'Invalid event.' }
        }
        $snapshot.message = [regex]::Replace($snapshot.message, '[\x00-\x08\x0B\x0C\x0E-\x1F]', '')
        return $snapshot
    } catch [IO.IOException] {
        return New-RebeccaUnavailable $Mode '暂时无法读取状态，正在重试。'
    } catch [UnauthorizedAccessException] {
        return New-RebeccaUnavailable $Mode '无法访问状态文件，请检查项目权限。'
    } catch {
        return New-RebeccaUnavailable $Mode '状态格式不兼容，等待有效数据。' 'incompatible'
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Read-RebeccaConfig {
    param([string]$Root, [string]$ConfigPath = '')
    $parent = Split-Path -Parent $Root
    $config = @{
        python_path = (Join-Path $parent '.venv\Scripts\python.exe')
        t3_home = (Join-Path $parent 'tools\T3CodeData\Home')
        poll_seconds = 2.0; project_ids = @(); scale = 1.0; topmost = $true
    }
    if ($env:T3CODE_HOME) { $config.t3_home = $env:T3CODE_HOME }
    if (-not $ConfigPath) { $ConfigPath = Join-Path $Root 'config.local.json' }
    if ([IO.File]::Exists($ConfigPath)) {
        if ((Get-Item -LiteralPath $ConfigPath).Length -gt 16384) { throw 'Configuration is too large.' }
        $custom = [IO.File]::ReadAllText($ConfigPath, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $custom -or $custom -is [array]) { throw 'Configuration must be an object.' }
        foreach ($property in $custom.PSObject.Properties) {
            if (-not $config.ContainsKey($property.Name)) { throw ('Unknown configuration key: ' + $property.Name) }
            $config[$property.Name] = $property.Value
        }
    }
    if ($config.python_path -isnot [string] -or -not [IO.Path]::IsPathRooted($config.python_path) -or -not [IO.File]::Exists($config.python_path)) { throw 'Configure python_path in config.local.json with an existing Python 3.12+ executable.' }
    if ($config.t3_home -isnot [string] -or -not [IO.Path]::IsPathRooted($config.t3_home)) { throw 't3_home must be an absolute directory path.' }
    if ($config.poll_seconds -is [string] -or $config.poll_seconds -is [bool] -or $config.poll_seconds -lt 0.5 -or $config.poll_seconds -gt 30) { throw 'poll_seconds must be a number between 0.5 and 30.' }
    if ($config.scale -is [string] -or $config.scale -is [bool] -or $config.scale -lt 0.6 -or $config.scale -gt 1.6) { throw 'scale must be a number between 0.6 and 1.6.' }
    if ($config.topmost -isnot [bool]) { throw 'topmost must be true or false.' }
    if ($config.project_ids -isnot [array]) { throw 'project_ids must be an array.' }
    foreach ($id in $config.project_ids) { if ($id -isnot [string] -or $id -notmatch '^[A-Za-z0-9:_-]{1,128}$') { throw 'Invalid project_ids entry.' } }
    return $config
}

function Read-RebeccaGifAnimation {
    param([string]$Path)
    # Only independent full-canvas frames are supported. Delta GIFs need a
    # compositor; reject those rather than showing fragments or stale pixels.
    $stream=$null
    try {
        if (-not [IO.File]::Exists($Path)) { return $null }
        $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        if ($stream.Length -lt 13 -or $stream.Length -gt 16777216) { return $null }
        $header=New-Object byte[] 13
        if ($stream.Read($header,0,13) -ne 13) { return $null }
        $signature=[Text.Encoding]::ASCII.GetString($header,0,6)
        if ($signature -notin @('GIF87a','GIF89a')) { return $null }
        $width=[int]$header[6]+256*[int]$header[7]
        $height=[int]$header[8]+256*[int]$header[9]
        if ($width -lt 1 -or $height -lt 1 -or $width -gt 2048 -or $height -gt 2048) { return $null }
        $stream.Position=0
        $decoder=New-Object Windows.Media.Imaging.GifBitmapDecoder($stream,[Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,[Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
        if ($decoder.Frames.Count -lt 2 -or $decoder.Frames.Count -gt 64 -or [long]$width*$height*$decoder.Frames.Count -gt 33554432) { return $null }
        $frames=New-Object 'Collections.Generic.List[Windows.Media.Imaging.BitmapSource]'
        $durations=New-Object 'Collections.Generic.List[int]'
        $timeline=New-Object Windows.Media.Animation.ObjectAnimationUsingKeyFrames
        $elapsed=0
        foreach ($frame in $decoder.Frames) {
            if ($frame.PixelWidth -ne $width -or $frame.PixelHeight -ne $height) { return $null }
            $metadata=$frame.Metadata
            $left=[int]$metadata.GetQuery('/imgdesc/Left'); $top=[int]$metadata.GetQuery('/imgdesc/Top')
            if ($left -ne 0 -or $top -ne 0) { return $null }
            $delay=[int]$metadata.GetQuery('/grctlext/Delay')
            if ($delay -lt 0 -or $delay -gt 1000) { return $null }
            # Missing/zero delays are common; normalize them to a gentle 10 fps.
            if ($delay -lt 2) { $delay=10 }
            $milliseconds=$delay*10
            $frame.Freeze(); $frames.Add($frame); $durations.Add($milliseconds)
            $keyframe=New-Object Windows.Media.Animation.DiscreteObjectKeyFrame
            $keyframe.KeyTime=[Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds($elapsed))
            $keyframe.Value=$frame; $timeline.KeyFrames.Add($keyframe)|Out-Null
            $elapsed+=$milliseconds
        }
        $timeline.Duration=[TimeSpan]::FromMilliseconds($elapsed)
        $timeline.RepeatBehavior=[Windows.Media.Animation.RepeatBehavior]::Forever
        $timeline.Freeze()
        return [pscustomobject]@{Frames=$frames.ToArray();DurationsMs=$durations.ToArray();DurationMs=$elapsed;Timeline=$timeline}
    } catch {
        # Animation is optional: malformed assets must not stop status display.
        return $null
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function New-RebeccaView {
    param([string]$Root, [hashtable]$Config, [ValidateSet('live','demo')][string]$Mode='live')
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    $atlasPath = Join-Path $Root 'assets\rebecca-atlas.png'
    if (-not [IO.File]::Exists($atlasPath)) { throw 'Character asset is missing: assets/rebecca-atlas.png' }
    $bitmap = New-Object Windows.Media.Imaging.BitmapImage
    $bitmap.BeginInit(); $bitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bitmap.UriSource = New-Object Uri($atlasPath); $bitmap.EndInit(); $bitmap.Freeze()
    if ($bitmap.PixelWidth % 3 -ne 0 -or $bitmap.PixelHeight % 2 -ne 0) { throw 'Character atlas must contain a 3 by 2 equal-cell grid.' }
    $frames = @{}
    $states = @('idle','working','attention','success','error','offline')
    $cellW = [int]($bitmap.PixelWidth/3); $cellH = [int]($bitmap.PixelHeight/2)
    for ($i=0; $i -lt 6; $i++) {
        $cellX=($i%3)*$cellW; $cellY=[int][Math]::Floor($i/3)*$cellH
        $rectangle = New-Object Windows.Int32Rect($cellX, $cellY, $cellW, $cellH)
        $crop = New-Object Windows.Media.Imaging.CroppedBitmap($bitmap, $rectangle); $crop.Freeze(); $frames[$states[$i]] = $crop
    }
    foreach ($pose in @('idle','working')) {
        $posePath = Join-Path $Root ('assets\rebecca-'+$pose+'-seated.png')
        if (-not [IO.File]::Exists($posePath)) { throw ('Character asset is missing: assets/rebecca-'+$pose+'-seated.png') }
        $seated = New-Object Windows.Media.Imaging.BitmapImage
        $seated.BeginInit(); $seated.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $seated.UriSource = New-Object Uri($posePath); $seated.EndInit(); $seated.Freeze()
        $frames[$pose] = $seated
    }
    [xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Rebecca · T3 Pet" WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="NoResize" ShowInTaskbar="False" ShowActivated="False" Width="320" Height="385" Topmost="True">
  <Grid>
    <Grid.RowDefinitions><RowDefinition Height="100"/><RowDefinition Height="*"/></Grid.RowDefinitions>
    <Border x:Name="Badge" Margin="16,2,16,5" Padding="12,8" Background="#F020263A" BorderBrush="#665CE6C2" BorderThickness="1" CornerRadius="12" VerticalAlignment="Bottom">
      <StackPanel>
        <DockPanel><TextBlock x:Name="ModeLabel" Text="T3 · LIVE" FontFamily="Segoe UI" FontSize="10" Foreground="#8BE6CC"/><TextBlock x:Name="StateLabel" Text="连接中" HorizontalAlignment="Right" FontSize="11" Foreground="#DBE8FC"/></DockPanel>
        <TextBlock x:Name="Message" Text="正在读取 T3 状态…" Margin="0,4,0,2" Foreground="#F3F7FF" FontFamily="Microsoft YaHei UI" FontSize="13" TextWrapping="Wrap" MaxHeight="42" TextTrimming="CharacterEllipsis"/>
        <TextBlock x:Name="Counts" Text="" FontSize="10" Foreground="#B4C2D9"/>
      </StackPanel>
    </Border>
    <Image x:Name="Character" Grid.Row="1" Stretch="Uniform" HorizontalAlignment="Center" VerticalAlignment="Top" Cursor="Hand" RenderTransformOrigin="0.5,0.85" RenderOptions.BitmapScalingMode="HighQuality">
      <Image.RenderTransform><TransformGroup><RotateTransform/><TranslateTransform/></TransformGroup></Image.RenderTransform>
    </Image>
  </Grid>
</Window>
'@
    $reader = New-Object Xml.XmlNodeReader($xaml)
    $window = [Windows.Markup.XamlReader]::Load($reader); $reader.Close()
    $context = [pscustomobject]@{
        Window=$window; Character=$window.FindName('Character'); Badge=$window.FindName('Badge')
        ModeLabel=$window.FindName('ModeLabel'); StateLabel=$window.FindName('StateLabel')
        Message=$window.FindName('Message'); Counts=$window.FindName('Counts')
        Frames=$frames; State=''; Snapshot=$null; Mode=$Mode; Paused=$false
        WorkingAnimation=(Read-RebeccaGifAnimation (Join-Path $Root 'assets\rebecca-working-typing.gif'))
        WorkingClock=$null; IsClosed=$false
        Scale=[double]$Config.scale; Config=$Config; LastPosition=$null
    }
    $context.Window.Add_Closed({$context.IsClosed=$true;Stop-RebeccaAnimation $context}.GetNewClosure())
    $context.Window.Topmost = $Config.topmost
    if ($Mode -eq 'demo') { $context.ModeLabel.Text='演示 · 模拟状态'; $context.ModeLabel.Foreground='#FFCF75' }
    if ($Config.project_ids.Count -gt 0) { $context.ModeLabel.Text += ' · 指定项目' }
    Set-RebeccaSize $context $context.Scale
    Reset-RebeccaPosition $context
    Set-RebeccaVisual $context (New-RebeccaUnavailable $Mode '正在等待状态采集器…')
    return $context
}

function Set-RebeccaSize {
    param($Context, [double]$Scale)
    $Context.Scale = [Math]::Max(0.6, [Math]::Min(1.6, $Scale))
    $size = 270 * $Context.Scale
    $Context.Character.Width=$size; $Context.Character.Height=$size
    $Context.Window.Width=[Math]::Max(320, $size+24); $Context.Window.Height=110+$size
}

function Reset-RebeccaPosition {
    param($Context)
    $work = [Windows.SystemParameters]::WorkArea
    $Context.Window.Left=$work.Right-$Context.Window.Width-18
    $Context.Window.Top=$work.Bottom-$Context.Window.Height-12
}

function Set-RebeccaVisual {
    param($Context, $Snapshot)
    $Context.Snapshot=$Snapshot
    $Context.Message.Text=$Snapshot.message
    $Context.Counts.Text=('运行 {0}  ·  待处理 {1}  ·  需回应 {2}' -f $Snapshot.counts.working,$Snapshot.counts.pending,$Snapshot.counts.waiting_user)
    $labels=@{idle='待机';working='工作中';attention='需要你';success='已完成';error='异常';stopped='已停止';offline='未连接';incompatible='不兼容'}
    $Context.StateLabel.Text=$labels[$Snapshot.state]
    $Context.Message.ToolTip=$Snapshot.message
    if ($Context.State -ceq $Snapshot.state) { return }
    $Context.State=$Snapshot.state
    $frame=$Snapshot.state
    if ($frame -in @('stopped','incompatible')) { $frame='offline' }
    $Context.Character.Source=$Context.Frames[$frame]
    Set-RebeccaAnimation $Context
}

function Stop-RebeccaAnimation {
    param($Context)
    $Context.Character.ApplyAnimationClock([Windows.Controls.Image]::SourceProperty,$null)
    if ($null -ne $Context.WorkingClock) {
        $Context.WorkingClock.Controller.Remove()
        $Context.WorkingClock=$null
    }
    $rotation=$Context.Character.RenderTransform.Children[0]
    $translation=$Context.Character.RenderTransform.Children[1]
    $rotation.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty,$null)
    $translation.BeginAnimation([Windows.Media.TranslateTransform]::YProperty,$null)
    $rotation.Angle=0; $translation.Y=0
}

function Set-RebeccaAnimation {
    param($Context)
    Stop-RebeccaAnimation $Context
    if ($Context.IsClosed -or $Context.Paused -or $Context.State -in @('offline','incompatible','stopped')) { return }
    if ($Context.State -eq 'working' -and $null -ne $Context.WorkingAnimation) {
        $Context.WorkingClock=$Context.WorkingAnimation.Timeline.CreateClock($true)
        $Context.Character.ApplyAnimationClock([Windows.Controls.Image]::SourceProperty,$Context.WorkingClock)
        $Context.WorkingClock.Controller.Begin()
        return
    }
    $translation=$Context.Character.RenderTransform.Children[1]
    $amplitude=3.0; $seconds=1.8
    if ($Context.State -eq 'working') { $amplitude=2.0; $seconds=0.7 }
    if ($Context.State -eq 'success') { $amplitude=8.0; $seconds=0.45 }
    if ($Context.State -eq 'attention') { $amplitude=4.0; $seconds=0.8 }
    $animation=New-Object Windows.Media.Animation.DoubleAnimation
    $animation.From=0; $animation.To=-$amplitude; $animation.Duration=[TimeSpan]::FromSeconds($seconds)
    $animation.AutoReverse=$true; $animation.RepeatBehavior=[Windows.Media.Animation.RepeatBehavior]::Forever
    $ease=New-Object Windows.Media.Animation.SineEase; $ease.EasingMode='EaseInOut'; $animation.EasingFunction=$ease
    $translation.BeginAnimation([Windows.Media.TranslateTransform]::YProperty,$animation)
}

function Save-RebeccaViewState {
    param($Context, [string]$Path)
    $settings=@{left=$Context.Window.Left;top=$Context.Window.Top;scale=$Context.Scale;paused=$Context.Paused;topmost=$Context.Window.Topmost}
    [IO.File]::WriteAllText($Path, ($settings|ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
}

function Restore-RebeccaViewState {
    param($Context, [string]$Path)
    try {
        if (-not [IO.File]::Exists($Path) -or (Get-Item -LiteralPath $Path).Length -gt 4096) { return }
        $settings=[IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8)|ConvertFrom-Json -ErrorAction Stop
        if ($settings.scale -is [string] -or $settings.scale -is [bool] -or $settings.scale -lt 0.6 -or $settings.scale -gt 1.6) { return }
        if ($settings.paused -isnot [bool] -or $settings.topmost -isnot [bool]) { return }
        $left=[double]$settings.left; $top=[double]$settings.top
        if ([double]::IsNaN($left) -or [double]::IsInfinity($left) -or [double]::IsNaN($top) -or [double]::IsInfinity($top)) { return }
        Set-RebeccaSize $Context ([double]$settings.scale)
        $Context.Paused=$settings.paused; $Context.Window.Topmost=$settings.topmost
        # SystemParameters are WPF DIPs; never mix these with WinForms physical pixels.
        $virtual=New-Object Windows.Rect([Windows.SystemParameters]::VirtualScreenLeft,[Windows.SystemParameters]::VirtualScreenTop,[Windows.SystemParameters]::VirtualScreenWidth,[Windows.SystemParameters]::VirtualScreenHeight)
        $candidate=New-Object Windows.Rect($left,$top,$Context.Window.Width,$Context.Window.Height)
        $intersection=[Windows.Rect]::Intersect($virtual,$candidate)
        if ($intersection.Width -ge 100 -and $intersection.Height -ge 100) { $Context.Window.Left=$left; $Context.Window.Top=$top } else { Reset-RebeccaPosition $Context }
        Set-RebeccaAnimation $Context
    } catch { Reset-RebeccaPosition $Context }
}

Export-ModuleMember -Function *-Rebecca*
