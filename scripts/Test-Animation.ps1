param([string]$OutputDirectory='',[switch]$PassThru)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'app\Desktop.psm1') -Force
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
if(-not $OutputDirectory){$OutputDirectory=Join-Path $root ('tmp\animation-smoke-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))}
$OutputDirectory=Assert-RebeccaOutputRoot $OutputDirectory
[IO.Directory]::CreateDirectory($OutputDirectory)|Out-Null
$env:TEMP=$OutputDirectory;$env:TMP=$OutputDirectory
$script:animationChecks=0
function Assert-Animation([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message};$script:animationChecks++}
function Write-TestGif([string]$Path,[int[]]$Delays,[switch]$Partial){
    $encoder=New-Object Windows.Media.Imaging.GifBitmapEncoder
    for($index=0;$index -lt $Delays.Length;$index++){
        $size=2;if($Partial -and $index -gt 0){$size=1}
        $pixels=New-Object byte[] ($size*$size*4)
        for($offset=0;$offset -lt $pixels.Length;$offset+=4){$pixels[$offset+3]=255;if($index%2 -eq 0){$pixels[$offset+2]=255}else{$pixels[$offset+1]=255}}
        $bitmap=[Windows.Media.Imaging.BitmapSource]::Create($size,$size,96,96,[Windows.Media.PixelFormats]::Bgra32,$null,$pixels,($size*4))
        $metadata=New-Object Windows.Media.Imaging.BitmapMetadata('gif')
        $metadata.SetQuery('/grctlext/Delay',[uint16]$Delays[$index])
        $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap,$null,$metadata,$null))
    }
    $stream=[IO.File]::Create($Path);try{$encoder.Save($stream)}finally{$stream.Dispose()}
    # This Windows WIC encoder emits zero delays despite frame metadata. Patch
    # the known tiny fixture's GCEs so the reader test uses genuine 120/180 ms.
    $bytes=[IO.File]::ReadAllBytes($Path);$frameIndex=0
    for($offset=0;$offset -lt $bytes.Length-7;$offset++){
        if($bytes[$offset] -eq 33 -and $bytes[$offset+1] -eq 249 -and $bytes[$offset+2] -eq 4){
            $bytes[$offset+4]=[byte]($Delays[$frameIndex] -band 255)
            $bytes[$offset+5]=[byte](($Delays[$frameIndex] -shr 8) -band 255)
            $frameIndex++
        }
    }
    if($frameIndex -ne $Delays.Length){throw 'Synthetic GIF fixture did not contain expected GCE blocks.'}
    [IO.File]::WriteAllBytes($Path,$bytes)
}
function Read-TestPixel($Source){
    $converted=New-Object Windows.Media.Imaging.FormatConvertedBitmap($Source,[Windows.Media.PixelFormats]::Bgra32,$null,0)
    $bytes=New-Object byte[] ($converted.PixelWidth*$converted.PixelHeight*4)
    $converted.CopyPixels($bytes,($converted.PixelWidth*4),0)
    return ,$bytes
}
function New-AnimationSnapshot([string]$State){
    return [pscustomobject]@{state=$State;message='Animation fixture';source=[pscustomobject]@{kind='fixture';version='';health='connected'};counts=[pscustomobject]@{working=0;waiting_user=0;pending=0;failed=0}}
}
function Pump-AnimationDispatcher([int]$Milliseconds){
    $frame=New-Object Windows.Threading.DispatcherFrame
    $timer=New-Object Windows.Threading.DispatcherTimer
    $timer.Interval=[TimeSpan]::FromMilliseconds($Milliseconds)
    $handler=[EventHandler]{param($sender,$eventArgs) $sender.Stop();$frame.Continue=$false}.GetNewClosure()
    $timer.Add_Tick($handler)
    try{$timer.Start();[Windows.Threading.Dispatcher]::PushFrame($frame)}finally{$timer.Stop();$timer.Remove_Tick($handler)}
}

$gifPath=Join-Path $OutputDirectory 'two-frame.gif'
Write-TestGif $gifPath @(12,18)
$animation=Read-RebeccaGifAnimation $gifPath
Assert-Animation ($null -ne $animation -and $animation.Frames.Count -eq 2) 'Two full GIF frames did not decode.'
Assert-Animation ($animation.DurationsMs[0] -eq 120 -and $animation.DurationsMs[1] -eq 180 -and $animation.DurationMs -eq 300) 'GIF frame timing was not preserved.'
Assert-Animation ($animation.Frames[0].IsFrozen -and $animation.Frames[1].IsFrozen -and $animation.Timeline.IsFrozen) 'GIF frames/timeline were not frozen.'
Assert-Animation ($animation.Timeline.RepeatBehavior -eq [Windows.Media.Animation.RepeatBehavior]::Forever) 'Working animation does not loop.'
$exclusive=[IO.File]::Open($gifPath,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try{Assert-Animation $true 'GIF remained locked after loading.'}finally{$exclusive.Dispose()}
Assert-Animation ($null -eq (Read-RebeccaGifAnimation (Join-Path $OutputDirectory 'missing.gif'))) 'Missing GIF did not fall back.'
$badPath=Join-Path $OutputDirectory 'bad.gif';[IO.File]::WriteAllText($badPath,'not a GIF')
Assert-Animation ($null -eq (Read-RebeccaGifAnimation $badPath)) 'Broken GIF did not fall back.'
$singlePath=Join-Path $OutputDirectory 'single.gif';Write-TestGif $singlePath @(12)
Assert-Animation ($null -eq (Read-RebeccaGifAnimation $singlePath)) 'Single-frame GIF should use static fallback.'
$partialPath=Join-Path $OutputDirectory 'partial.gif';Write-TestGif $partialPath @(12,18) -Partial
Assert-Animation ($null -eq (Read-RebeccaGifAnimation $partialPath)) 'Delta/partial GIF was accepted without compositing.'
$zeroPath=Join-Path $OutputDirectory 'zero-delay.gif';Write-TestGif $zeroPath @(0,0)
$zero=Read-RebeccaGifAnimation $zeroPath
Assert-Animation ($null -ne $zero -and $zero.DurationMs -eq 200) 'Zero delays were not normalized.'
$longPath=Join-Path $OutputDirectory 'long-delay.gif';Write-TestGif $longPath @(12,65535)
Assert-Animation ($null -eq (Read-RebeccaGifAnimation $longPath)) 'Unbounded frame delay was accepted.'
$largePath=Join-Path $OutputDirectory 'oversize-header.gif'
$bytes=[IO.File]::ReadAllBytes($gifPath);$bytes[6]=255;$bytes[7]=255;[IO.File]::WriteAllBytes($largePath,$bytes)
Assert-Animation ($null -eq (Read-RebeccaGifAnimation $largePath)) 'Oversize GIF canvas was accepted.'
$manyPath=Join-Path $OutputDirectory 'many-frames.gif';Write-TestGif $manyPath (New-Object int[] 65)
Assert-Animation ($null -eq (Read-RebeccaGifAnimation $manyPath)) 'Too many frames were accepted.'

$view=New-RebeccaView $root @{scale=1.0;topmost=$false;project_ids=@()} 'demo'
try {
    if([IO.File]::Exists((Join-Path $root 'assets\rebecca-working-typing.gif'))){
        Assert-Animation ($null -ne $view.WorkingAnimation -and $view.WorkingAnimation.Frames.Count -ge 2) 'Packaged working GIF failed validation and silently fell back.'
    }
    $view.WorkingAnimation=$animation
    $view.Window.Left=-10000;$view.Window.Top=-10000;$view.Window.Show()
    Set-RebeccaVisual $view (New-AnimationSnapshot 'working')
    Assert-Animation ($null -ne $view.WorkingClock) 'Working did not create its GIF animation clock.'
    Pump-AnimationDispatcher 80
    Assert-Animation ($null -ne $view.WorkingClock.CurrentTime -and $view.WorkingClock.CurrentTime.TotalMilliseconds -gt 0) 'GIF clock did not advance through the normal WPF dispatcher.'
    $view.WorkingClock.Controller.SeekAlignedToLastTick([TimeSpan]::FromMilliseconds(50),[Windows.Media.Animation.TimeSeekOrigin]::BeginTime)
    Assert-Animation ($null -ne $view.WorkingClock -and [Windows.DependencyPropertyHelper]::GetValueSource($view.Character,[Windows.Controls.Image]::SourceProperty).IsAnimated) 'Working did not animate Image.Source.'
    Assert-Animation (-not [Windows.DependencyPropertyHelper]::GetValueSource($view.Character.RenderTransform.Children[1],[Windows.Media.TranslateTransform]::YProperty).IsAnimated) 'Working GIF also applied whole-body bouncing.'
    $red=Read-TestPixel $view.Character.Source
    $view.WorkingClock.Controller.SeekAlignedToLastTick([TimeSpan]::FromMilliseconds(150),[Windows.Media.Animation.TimeSeekOrigin]::BeginTime)
    $green=Read-TestPixel $view.Character.Source
    Assert-Animation ($red[2] -eq 255 -and $red[1] -eq 0 -and $green[1] -eq 255 -and $green[2] -eq 0) 'Displayed pixels did not advance to the second GIF frame.'
    $view.WorkingClock.Controller.SeekAlignedToLastTick([TimeSpan]::FromMilliseconds(350),[Windows.Media.Animation.TimeSeekOrigin]::BeginTime)
    $loop=Read-TestPixel $view.Character.Source
    Assert-Animation ($loop[2] -eq 255 -and $loop[1] -eq 0) 'Displayed animation did not loop.'
    $clock=$view.WorkingClock
    Set-RebeccaVisual $view (New-AnimationSnapshot 'working')
    Assert-Animation ([object]::ReferenceEquals($clock,$view.WorkingClock)) 'Repeated status polls restarted GIF playback.'
    $view.Paused=$true;Set-RebeccaAnimation $view
    Assert-Animation ($null -eq $view.WorkingClock -and -not [Windows.DependencyPropertyHelper]::GetValueSource($view.Character,[Windows.Controls.Image]::SourceProperty).IsAnimated -and [object]::ReferenceEquals($view.Character.Source,$view.Frames['working'])) 'Pause did not restore the static working sprite.'
    $view.Paused=$false;Set-RebeccaAnimation $view
    Assert-Animation ($null -ne $view.WorkingClock) 'Unpause did not resume working animation.'
    Set-RebeccaVisual $view (New-AnimationSnapshot 'idle')
    Assert-Animation ($null -eq $view.WorkingClock -and -not [Windows.DependencyPropertyHelper]::GetValueSource($view.Character,[Windows.Controls.Image]::SourceProperty).IsAnimated -and [object]::ReferenceEquals($view.Character.Source,$view.Frames['idle'])) 'Changing to idle left GIF frames active.'
    $view.WorkingAnimation=$null
    Set-RebeccaVisual $view (New-AnimationSnapshot 'working')
    Assert-Animation ($null -eq $view.WorkingClock -and [object]::ReferenceEquals($view.Character.Source,$view.Frames['working'])) 'Optional GIF fallback lost static working pose.'
    $view.WorkingAnimation=$animation;Set-RebeccaAnimation $view
    $view.Window.Close()
    Assert-Animation ($view.IsClosed -and $null -eq $view.WorkingClock -and -not [Windows.DependencyPropertyHelper]::GetValueSource($view.Character,[Windows.Controls.Image]::SourceProperty).IsAnimated) 'Window close retained a GIF animation clock.'
    Set-RebeccaAnimation $view
    Assert-Animation ($null -eq $view.WorkingClock) 'Closed view restarted animation.'
} finally {if(-not $view.IsClosed){$view.Window.Close()}}

$result=[ordered]@{checks=$script:animationChecks;result='passed';mode='synthetic-gif-only';output=$OutputDirectory}
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'result.json'),($result|ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
if($PassThru){[pscustomobject]$result}else{$result|ConvertTo-Json}
