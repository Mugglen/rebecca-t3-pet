param(
    [string]$SheetPath='',
    [string]$OutputPath='',
    [ValidateRange(1,16)][int]$Columns=3,
    [ValidateRange(1,16)][int]$Rows=2,
    [ValidateRange(20,2000)][int]$FrameDelayMs=140,
    [switch]$Force
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$root=Split-Path -Parent $PSScriptRoot
if(-not $SheetPath){$SheetPath=Join-Path $root 'assets\rebecca-working-typing-sheet.png'}
if(-not $OutputPath){$OutputPath=Join-Path $root 'assets\rebecca-working-typing.gif'}
$SheetPath=[IO.Path]::GetFullPath($SheetPath)
$OutputPath=[IO.Path]::GetFullPath($OutputPath)
if([IO.Path]::GetPathRoot($OutputPath) -ine 'D:\'){throw 'GIF output must be on D:.'}
if($SheetPath -ieq $OutputPath){throw 'Sheet and GIF paths must be different.'}
if([IO.File]::Exists($OutputPath) -and -not $Force){throw 'GIF already exists. Use -Force to rebuild this output.'}
if($FrameDelayMs % 10 -ne 0){throw 'GIF delay must be a multiple of 10 ms.'}
if($Columns*$Rows -gt 64){throw 'Use at most 64 frames.'}
$scratch=Join-Path $root 'tmp'
[IO.Directory]::CreateDirectory($scratch)|Out-Null
$env:TEMP=$scratch;$env:TMP=$scratch
$env:PSModuleAnalysisCachePath=Join-Path $scratch 'PowerShellModuleCache'
Add-Type -AssemblyName PresentationCore,WindowsBase

# WPF quantization does not reliably map transparent BGRA pixels to the GIF
# transparent index. Preserve the generated pixels' RGB quantization, assigning
# alpha below 128 to index zero (GIF has no fractional alpha).
if(-not ('RebeccaGifPixels' -as [type])){
    Add-Type -TypeDefinition @'
using System;
public static class RebeccaGifPixels {
    public static void ApplyAlpha(byte[] bgra, byte[] indexed, uint[] palette) {
        for (int p=0; p<indexed.Length; p++) {
            int q=p*4;
            if (bgra[q+3]<128) { indexed[p]=0; continue; }
            if (indexed[p]!=0) continue;
            int best=1, distance=Int32.MaxValue;
            for (int c=1; c<palette.Length; c++) {
                int b=(int)(palette[c]&255)-bgra[q];
                int g=(int)((palette[c]>>8)&255)-bgra[q+1];
                int r=(int)((palette[c]>>16)&255)-bgra[q+2];
                int d=r*r+g*g+b*b;
                if (d<distance) { best=c; distance=d; if (d==0) break; }
            }
            indexed[p]=(byte)best;
        }
    }
}
'@
}

$source=[Windows.Media.Imaging.BitmapImage]::new()
$source.BeginInit();$source.CacheOption=[Windows.Media.Imaging.BitmapCacheOption]::OnLoad
$source.UriSource=[Uri]::new($SheetPath);$source.EndInit();$source.Freeze()
if($source.PixelWidth % $Columns -ne 0 -or $source.PixelHeight % $Rows -ne 0){
    throw ('Sheet size {0}x{1} is not exactly divisible by grid {2}x{3}; no pixels were cropped.' -f $source.PixelWidth,$source.PixelHeight,$Columns,$Rows)
}
$width=[int]($source.PixelWidth/$Columns);$height=[int]($source.PixelHeight/$Rows)
if($width -gt 2048 -or $height -gt 2048 -or [long]$source.PixelWidth*$source.PixelHeight -gt 16777216){throw 'Sheet exceeds the 16-megapixel / 2048-pixel-per-frame limit.'}
$encoder=[Windows.Media.Imaging.GifBitmapEncoder]::new()
$delay=[UInt16]($FrameDelayMs/10)
for($i=0;$i -lt $Columns*$Rows;$i++){
    $rect=[Windows.Int32Rect]::new(($i%$Columns)*$width,[int][Math]::Floor($i/$Columns)*$height,$width,$height)
    $frame=[Windows.Media.Imaging.CroppedBitmap]::new($source,$rect);$frame.Freeze()
    $bgra=[Windows.Media.Imaging.FormatConvertedBitmap]::new($frame,[Windows.Media.PixelFormats]::Bgra32,$null,0)
    $pixels=New-Object byte[] ($width*$height*4);$bgra.CopyPixels($pixels,$width*4,0)
    $colors=[Collections.Generic.List[Windows.Media.Color]]::new()
    $colors.Add([Windows.Media.Color]::FromArgb(0,0,0,0))
    $automatic=[Windows.Media.Imaging.BitmapPalette]::new($frame,255)
    foreach($color in $automatic.Colors){
        if($color.A -gt 0){$colors.Add([Windows.Media.Color]::FromRgb($color.R,$color.G,$color.B))}
    }
    if($colors.Count -lt 2){$colors.Add([Windows.Media.Colors]::Black)}
    $palette=[Windows.Media.Imaging.BitmapPalette]::new($colors)
    $converted=[Windows.Media.Imaging.FormatConvertedBitmap]::new($frame,[Windows.Media.PixelFormats]::Indexed8,$palette,50)
    $indices=New-Object byte[] ($width*$height);$converted.CopyPixels($indices,$width,0)
    [uint32[]]$rgb=foreach($color in $colors){[uint32](([int]$color.R -shl 16) -bor ([int]$color.G -shl 8) -bor [int]$color.B)}
    [RebeccaGifPixels]::ApplyAlpha($pixels,$indices,$rgb)
    $indexed=[Windows.Media.Imaging.BitmapSource]::Create($width,$height,96,96,[Windows.Media.PixelFormats]::Indexed8,$palette,$indices,$width)
    $indexed.Freeze()
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($indexed))
}
$memory=[IO.MemoryStream]::new()
try{$encoder.Save($memory);$bytes=$memory.ToArray()}finally{$memory.Dispose()}

# WPF's GIF encoder drops requested delay/disposal metadata. Walk actual GIF
# blocks (never search arbitrary compressed bytes), then set each full frame's
# Graphic Control Extension. Keep local adaptive palettes and compressed data.
if([Text.Encoding]::ASCII.GetString($bytes,0,6) -ne 'GIF89a'){throw 'Unexpected GIF header.'}
$headerEnd=13
if(($bytes[10] -band 128) -ne 0){$headerEnd+=3*(1 -shl (($bytes[10] -band 7)+1))}
$position=$headerEnd;$frameCount=0;$hasControl=$false
while($position -lt $bytes.Length){
    $marker=$bytes[$position];$position++
    if($marker -eq 59){break}
    if($marker -eq 33){
        $label=$bytes[$position];$position++
        if($label -eq 249){
            if($bytes[$position] -ne 4 -or $position+5 -ge $bytes.Length){throw 'Invalid GIF control block.'}
            $bytes[$position+1]=9 # disposal=2, transparency=true
            $bytes[$position+2]=[byte]($delay -band 255)
            $bytes[$position+3]=[byte]($delay -shr 8)
            $bytes[$position+4]=0
            $hasControl=$true
        }
        do{$length=[int]$bytes[$position];$position+=1+$length}while($length -ne 0 -and $position -lt $bytes.Length)
    } elseif($marker -eq 44){
        if(-not $hasControl){throw 'GIF encoder did not produce a per-frame control block.'}
        if([BitConverter]::ToUInt16($bytes,$position) -ne 0 -or [BitConverter]::ToUInt16($bytes,$position+2) -ne 0 -or [BitConverter]::ToUInt16($bytes,$position+4) -ne $width -or [BitConverter]::ToUInt16($bytes,$position+6) -ne $height){throw 'GIF encoder changed the full-frame bounds.'}
        $packed=$bytes[$position+8];$position+=9
        if(($packed -band 128) -ne 0){$position+=3*(1 -shl (($packed -band 7)+1))}
        $position++ # LZW minimum code size
        do{$length=[int]$bytes[$position];$position+=1+$length}while($length -ne 0 -and $position -lt $bytes.Length)
        $frameCount++;$hasControl=$false
    } else {throw 'Unexpected GIF block.'}
}
if($frameCount -ne $Columns*$Rows){throw 'Encoded GIF frame count does not match the sheet.'}
[byte[]]$loopExtension=@(33,255,11)+[Text.Encoding]::ASCII.GetBytes('NETSCAPE2.0')+@(3,1,0,0,0)
$output=[IO.MemoryStream]::new()
try{
    $output.Write($bytes,0,$headerEnd);$output.Write($loopExtension,0,$loopExtension.Length)
    $output.Write($bytes,$headerEnd,$bytes.Length-$headerEnd);$result=$output.ToArray()
}finally{$output.Dispose()}

# Decode the finished bytes before replacing any destination.
$verifyStream=[IO.MemoryStream]::new($result,$false)
try{
    $verify=[Windows.Media.Imaging.GifBitmapDecoder]::new($verifyStream,[Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,[Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
    if($verify.Frames.Count -ne $frameCount){throw 'Finished GIF failed frame validation.'}
    foreach($item in $verify.Frames){
        if($item.Metadata.GetQuery('/grctlext/Delay') -ne $delay -or $item.Metadata.GetQuery('/grctlext/Disposal') -ne 2 -or -not $item.Metadata.GetQuery('/grctlext/TransparencyFlag')){throw 'Finished GIF failed timing or transparency validation.'}
    }
}finally{$verifyStream.Dispose()}
[IO.Directory]::CreateDirectory((Split-Path -Parent $OutputPath))|Out-Null
$temporary=$OutputPath+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
try{
    [IO.File]::WriteAllBytes($temporary,$result)
    if([IO.File]::Exists($OutputPath)){[IO.File]::Replace($temporary,$OutputPath,$null)}else{[IO.File]::Move($temporary,$OutputPath)}
}finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
[pscustomobject]@{output=$OutputPath;frames=$frameCount;width=$width;height=$height;frame_delay_ms=$FrameDelayMs;duration_ms=$FrameDelayMs*$frameCount;loop='infinite';disposal=2;alpha='1-bit, threshold 128';palette='adaptive, up to 255 opaque colors per frame';bytes=$result.Length}|ConvertTo-Json
