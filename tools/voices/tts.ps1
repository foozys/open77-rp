param([string]$OutDir, [string]$Voice, [string]$Prefix = "v")
# Синтез фраз голосом OneCore (WinRT Windows.Media.SpeechSynthesis) в WAV.
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Media.SpeechSynthesis.SpeechSynthesizer, Windows.Media.SpeechSynthesis, ContentType = WindowsRuntime]
$null = [Windows.Storage.Streams.DataReader, Windows.Storage.Streams, ContentType = WindowsRuntime]
$asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
function Await($op, [Type]$type) {
    $task = $asTask.MakeGenericMethod($type).Invoke($null, @($op))
    $task.Wait() | Out-Null
    $task.Result
}
New-Item -ItemType Directory -Force $OutDir | Out-Null
$synth = New-Object Windows.Media.SpeechSynthesis.SpeechSynthesizer
$synth.Voice = [Windows.Media.SpeechSynthesis.SpeechSynthesizer]::AllVoices | Where-Object { $_.DisplayName -eq $Voice } | Select-Object -First 1
if (-not $synth.Voice -or $synth.Voice.DisplayName -ne $Voice) { throw "voice not found: $Voice" }
$phrases = @(
 "Сними это железо.",
 "Ты больше не человек.",
 "Они смотрят на тебя.",
 "Тебе ведь это нравится, да?",
 "Сделай это. Сейчас.",
 "Ты уже не помнишь своё лицо.",
 "Никто тебе не поможет.",
 "Мясо. Они все просто мясо."
)
$i = 1
foreach ($p in $phrases) {
    # Ниже, медленнее и тише — ближе к шёпоту, чем к диктору.
    $ssml = "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='ru-RU'>" +
            "<prosody rate='-18%' pitch='-8%' volume='soft'>$p</prosody></speak>"
    $stream = Await ($synth.SynthesizeSsmlToStreamAsync($ssml)) ([Windows.Media.SpeechSynthesis.SpeechSynthesisStream])
    $size = [uint32]$stream.Size
    $reader = New-Object Windows.Storage.Streams.DataReader($stream.GetInputStreamAt(0))
    $null = Await ($reader.LoadAsync($size)) ([uint32])
    $bytes = New-Object byte[] $size
    $reader.ReadBytes($bytes)
    [IO.File]::WriteAllBytes((Join-Path $OutDir "$Prefix$i.wav"), $bytes)
    $i++
}
"ok $Voice"
