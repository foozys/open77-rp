# Голоса психоза

Голоса в голове при приступе (`rp_cyberware_ui/audio/voice_N.wav`, `voice_N_severe.wav`).

1. Синтез фраз голосами Windows OneCore (список фраз — в `tts.ps1`):
   ```powershell
   .\tts.ps1 -OutDir raw_pavel -Voice "Microsoft Pavel"
   .\tts.ps1 -OutDir raw_irina -Voice "Microsoft Irina"
   ```
2. Обработка в хор: основной голос, он же ниже, второй голос тихо сверху, мягкий шёпот, эхо между ушами:
   ```powershell
   node voices.js raw_pavel ..\..\resources\rp\rp_cyberware_ui\audio raw_irina
   ```

Вместо синтеза можно положить свои записи (`v1.wav` … `v8.wav`, PCM 16 бит, моно) в папку и прогнать их через `voices.js`.
После замены файлов — `refresh` на сервере и перезаход.
