# Голоса психоза

Голоса в голове при приступе (`rp_cyberware_ui/audio/voice_N.wav`, `voice_N_severe.wav`), одни для всех персонажей.
Сейчас — живая запись `audio.mp3`.

## Своя запись

1. Запишите фразы подряд, с паузой между ними (от ~0,3 с), в MP3. Положите сюда как `audio.mp3`.
2. Нарезать по паузам (нужен декодер: `npm install mpg123-decoder` в любой временной папке, оттуда и запускать):
   ```powershell
   node split.mjs C:\open77-rp\tools\voices\audio.mp3 C:\temp\phrases join=5+6,9+10
   ```
   `analyze` — только показать найденные отрезки. Пауза на точке внутри фразы («Сделай это. Сейчас.») такая же, как между
   фразами, поэтому такие фразы режутся на части — `join=5+6,9+10` склеивает отрезки по номерам из `analyze`.
3. Обработка в хор (тот же голос ниже, мягкий шёпот, эхо между ушами; `_severe` — грубее):
   ```powershell
   node voices.js C:\temp\phrases C:\open77-rp\resources\rp\rp_cyberware_ui\audio
   ```
4. Количество фраз — `VOICES` в `rp_cyberware_ui/client/main.lua` и список `files` в `rp_cyberware_ui/open77.lua`.
5. `refresh` на сервере и перезаход.

## Синтез вместо записи

`tts.ps1 -OutDir raw -Voice "Microsoft Pavel"` (голоса Windows OneCore), дальше `voices.js` как выше;
третьим аргументом `voices.js` можно дать папку со вторым голосом — он ляжет тихим слоем сверху.
