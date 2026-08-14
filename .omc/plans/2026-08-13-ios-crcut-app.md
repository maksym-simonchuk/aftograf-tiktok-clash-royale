# CRCut iOS — нативное приложение с алгоритмом crcut на телефоне

**Статус: pending approval** (план не исполняется до явного одобрения)
Дата: 2026-08-13 · Автор: teamlead-сессия · Источники фактов: инвентаризация кода (agent ios-facts), анализ рисков (agent ios-analyst), live-проверка ffmpeg-kit.

---

## 1. Требования (зафиксированы интервью)

| # | Требование | Решение пользователя |
|---|---|---|
| R1 | Загружать видео в приложение, оно режет и собирает клипы прямо на айфоне | «Всё на телефоне» — нативный Swift-порт, без сервера |
| R2 | Объём v1 | «Полный паритет с crcut»: клипы ≤20с + 3 варианта монтажа + мемы + SFX + бит-снап музыки + голос |
| R3 | Сохранять результат в галерею iPhone | Photos framework, add-only разрешение |
| R4 | Текстовка к каждому видео, удобно копировать | In-app текст + кнопка «копировать» + share sheet |
| R5 | Дистрибуция | Без App Store, без платного аккаунта: бесплатный Apple ID, сайдлоад через Xcode, переподпись раз в 7 дней |
| R6 | Лёгкая пересборка: дорабатываем алгоритм → пересобрал → скинул на айфон | Однокомандный build+install (`make ios-install`), golden-фикстуры синхронизируют Python↔Swift |

Уточнение к R2: паритет **функциональный**, не попиксельный. Кривые zoompan/xfade у ffmpeg и Core Image математически не совпадут 1:1 — критерий приёмки «эффект присутствует и выглядит эквивалентно», допуски заданы в §6.

## 2. Ключевые решения (ADR-кратко)

1. **Native AVFoundation/Core Image/vDSP, НЕ ffmpeg-kit.** Проверено live: `arthenica/ffmpeg-kit` archived (gh api, 2026-08-13). Плюс: GPL-вопрос x264 исчезает; аппаратный энкодер быстрее/холоднее на телефоне; IPA меньше → быстрее цикл переподписи.
2. **Рендер только в форграунде**: экран не гаснет (`isIdleTimerDisabled = true`), прогресс на экране. iOS не даёт «3 минуты в фоне по требованию» (BGProcessingTask — планировщик, не on-demand). Уход в фон mid-render → отмена с чекпоинтом (план сохранён, рендер перезапускается с текущей группы).
3. **Минимальная iOS: 17.0.** Даёт зрелые PHPicker/AVVideoCompositing/vDSP API; любой iPhone последних ~5 лет подходит.
4. **Голос — тот же движок, что на десктопе**: порт протокола edge-tts (WebSocket к Microsoft-эндпоинту — desktop-версия уже так работает, voice.py:336-346), офлайн-фолбэк `AVSpeechSynthesizer` (аналог фолбэка на `say`, voice.py:273-287). «Всё на телефоне» = обработка видео в приложении; сетевой TTS-запрос сохраняет паритет качества голоса.
5. **Бит-сетки бандл-музыки предвычисляются на Маке** при сборке (librosa уже есть: plan.py:609-618) и кладутся в бандл как JSON. На устройстве librosa не нужна вовсе — полный паритет бит-снапа для тех же 15+1 треков без DSP-проекта. Импорт своей музыки пользователем → v1.1 (потребует on-device beat tracker).
6. **Кодирование**: `AVAssetWriter`, HEVC/H.264 hardware, bitrate ~20 Mbps для 1080×1920@30 (замена `libx264 -crf 16`, render.py:87-109). Валидация: side-by-side с десктопным рендером того же исходника (§7-V5).
7. **Монорепо**: приложение живёт в `ios/` этого же репозитория — golden-фикстуры генерятся Python-тестами и читаются XCTest без синхронизации между репо.
8. **SDR принудительно на инжесте** (bt709, как во всём render.py): HDR-скринрекорды тонмапятся при чтении, SDR-оверлеи (PNG-капшены/мемы) компонуются без сюрпризов.

Отклонено: ffmpeg-kit (archived, GPL, размер), Personal Voice iOS 17 (клонирует голос владельца, не персонажа), on-device beat tracking в v1 (открытый DSP-проект — премортем-риск №1 аналитика), точный порт say-цепочек `rasp`/`grandpa_deep` (acrusher/aexciter не имеют AVAudioUnit-эквивалентов — в v1 стили едут через edge-tts rate/pitch, что уже покрывает story/hype/clean/grandpa-подобные).

## 3. Что портируем (карта Python → Swift)

| Python (файл:строки) | Swift-модуль | iOS API | Риск |
|---|---|---|---|
| detect.py:86-104 motion/flash (frame-diff, яркость>240) | `DetectKit/Signals.swift` | AVAssetReader → CVPixelBuffer, vImage/vDSP | Низкий |
| detect.py:98-102 shake (`cv2.phaseCorrelate` + Hanning) | `DetectKit/Shake.swift` | Спайк: `VNTranslationalImageRegistrationRequest`; если мимо — vDSP FFT фазовая корреляция вручную | Средний |
| detect.py:107-135 live-гейт (HUD-медиана, live_ratio=2.5) | `DetectKit/LiveGate.swift` | чистая математика на буферах | Низкий |
| detect.py:138-172 z-скоры (веса 1.0/0.8/1.2), сглаживание, жадный отбор (min_gap=6.0, max=6, min_hype=0.5) | `DetectKit/Highlights.swift` | vDSP свёртка | Низкий |
| media.py:55-75 probe (rotation, fps, duration) | `MediaKit/Probe.swift` | AVAsset / AVAssetTrack | Низкий |
| plan.py целиком: PlanConfig (26 констант, :22-52), Window/Segment/Group, build_plan (:316-412), _split/_merge (:222-255), _score ×1.5 клатч (:258-267), segments_for 70/30 (:273-298), _hook_seg EOF-кламп (:491-497), _trim_to_target (:526-565), _snapped (:568-606), пулы TITLES/CAPTIONS 30/ADLIBS 16/DESCRIPTIONS 20/HASHTAGS (:623-816) | `PlanKit/` (чистый Swift, без iOS API) | — | Низкий (механический порт + golden-тесты) |
| render.py:119-160 трим/скорость/пилларбокс-блюр | `RenderKit/Timeline.swift` | AVMutableComposition (`scaleTimeRange` для speed), Core Image blur для пилларбокса | Средний |
| render.py:163-182 zoompan punch (экспон. затухание зума+тряски) | `RenderKit/Compositor.swift` (custom `AVVideoCompositing`) | Core Image transform per-frame | Средний |
| render.py:204-224 xfade 6 переходов (plan.py:646) | тот же Compositor | CI dissolve/wipe/blend на кадр перехода | Средний |
| render.py:185-201 flash (белый поп + rgbashift, только clips) | тот же Compositor | CIColorMatrix / канальный сдвиг | Низкий |
| overlay.py:39-68 Pillow-капшены (автофит ≤3 строк, обводка) | `RenderKit/Captions.swift` | Core Text → CGImage (лучше Pillow) | Низкий |
| render.py:69-74 прогресс-бар ретеншена | Compositor | CI-полоса, x=f(t) | Низкий |
| render.py:227-248 мемы на хитах, render.py:267-278 SFX | Timeline + AVAudioMix | — | Низкий |
| render.py:301-369 микс: music loop/fade, voice volume=1.7, **sidechaincompress duck**, **loudnorm I=-14** | `RenderKit/AudioMix.swift` | AVAudioMix ramps; дак = огибающая голоса (vDSP) → volume ramps на музыке; loudnorm = упрощённый R128-замер (vDSP) + статический гейн + лимитер | **Высокий** — оба без готового API |
| voice.py:314-346 edge-tts + jitter (:259-270), кэш sha1 | `VoiceKit/EdgeTTS.swift` + `VoiceKit/LocalTTS.swift` | URLSessionWebSocketTask; AVSpeechSynthesizer фолбэк | Средний (неофиц. протокол; фолбэк обязателен) |
| music.py: 3 синт-бита 140bpm | `MusicKit_/Beds.swift` (генерация wav vDSP) или пререндер в бандл | пререндер проще — решает исполнитель | Низкий |
| cli.py:190-228 fav/ + ротация музыки, :246-252 раскладка вывода, :56-61 .txt | `AppCore/Pipeline.swift` + UI | — | Низкий |

## 4. Структура проекта

```
ios/
  Makefile               # make ios-install: xcodebuild -allowProvisioningUpdates + devicectl install
  CRCut.xcodeproj
  CRCut/                 # SwiftUI-приложение
    App.swift, ImportView, QueueView, ResultView (плеер + текстовка + копировать/сохранить)
    Resources/: музыка (15+fav), beatgrids.json, sfx/, memes/, шрифт .ttf (бандлим — на iOS нет Arial Black)
  Packages/
    DetectKit/ PlanKit/ RenderKit/ VoiceKit/ MediaKit/   # SPM, PlanKit/DetectKit — без UIKit, тестируются на Маке
  Tests/
    GoldenTests/         # читают tests/golden/*.json из корня репо
scripts/export_golden.py # генерит golden из Python (фикстура make_fake_cr.py)
```

## 5. Синхронизация алгоритма Python ↔ Swift (R6)

Python-репо остаётся лабораторией алгоритма. Механизм:
1. `scripts/export_golden.py` прогоняет `analyze()` + `build_plan()` на синтетической фикстуре (tests/fixtures/make_fake_cr.py) и пишет `tests/golden/{analysis,plan_clips,plan_montage}.json` (сигналы, хайлайты, сегменты с точностью 1e-6).
2. XCTest в `GoldenTests` прогоняет Swift-порт на том же видео-файле фикстуры (бандлится в тест-таргет) и сравнивает: хайлайты ±0.15с (разница декодеров), сегменты плана — точное совпадение при одинаковых входных массивах.
3. Улучшили алгоритм в Python → перегенерили golden → Swift-тесты красные → показывают, что именно портировать. `make ios-install` — и новая версия на телефоне.

Цикл пересборки: `cd ios && make ios-install` (телефон по кабелю; первый раз — Trust developer в Настройках). Переподпись: тот же самый запуск раз в ≤7 дней. Лимиты бесплатного Apple ID: ≤3 приложения одновременно, ≤10 App ID в неделю — для одного приложения не мешает.

## 6. Порядок реализации (каждая фаза = рабочее приложение)

- **M0 Скелет** (риск низкий): проект, SPM-пакеты, PHPicker импорт → passthrough-реэкспорт AVAssetWriter → сохранение в Photos (add-only permission) → заглушка текстовки с копированием. Доказывает весь I/O-контур.
- **M1 Детекция**: порт detect.py + media.probe; спайк VNTranslational vs vDSP-фазокорреляция; golden-тест детекции зелёный.
- **M2 План**: порт plan.py в PlanKit; golden-тесты плана зелёные (clips и montage).
- **M3 Рендер «грубыми склейками»**: AVMutableComposition, хард-каты + speed (lead 1.35/1.25, hit 0.55, hook 0.7), hardware-энкод, сохранение. Некрасиво, но клипы уже правильные по таймингу — можно пользоваться.
- **M4 Визуальный слой** (главный риск расписания): custom AVVideoCompositing — zoompan, 6 xfade, flash, пилларбокс-блюр, капшены Core Text, мемы, прогресс-бар.
- **M5 Аудио-слой**: синт-биты + бандл-треки с предвычисленными сетками, fav-первым (cli.py:213), SFX-кьюи, плоский микс без дакинга.
- **M6 Голос**: EdgeTTS-клиент (story-стиль + джиттер ±4%/±3Hz из sha1 — voice.py:259-270), AVSpeech-фолбэк, кэш в Caches с лимитом 200MB LRU. **Первым делом спайк**: слушаем AVSpeech ru-RU на устройстве, чтобы знать качество фолбэка.
- **M7 Полировка микса** (второй главный риск): дак-огибающая + упрощённый loudnorm + лимитер. До M7 плоский микс — приемлемое промежуточное состояние.
- **M8 UX-добивка**: пулы текстовок (20 RU/EN, ротация idx как plan.py:825-829), очередь батча, термальный отклик (`thermalState == .serious` → пауза с баннером), пустое состояние «моменты не найдены», лимит батча (≤5 файлов / ≤15 мин суммарно за раз).

## 7. Критерии приёмки (все проверяемые)

- **A1**: golden-тест детекции — на фикстуре найдены все 3 синтетических импакта ±2.0с, ни одного вне матч-окна (паритет с tests/test_detect.py).
- **A2**: golden-тест плана — сегменты Swift == Python (kind/speed/границы, точность 1e-6 на одинаковых входах); клип ≤20.0с; монтаж — 3 варианта с масштабами 1.0/0.62/1.28.
- **A3**: на реальном скринрекорде матча (~2 мин) приложение собирает клипы и сохраняет в Фото; ролик открывается в галерее, 1080×1920@30, есть аудиодорожка.
- **A4**: батч 3×2мин → 3 монтажа доезжает до конца на устройстве пользователя без memory warning и без `thermalState == .critical`.
- **A5**: в филтерграфе… — в видеоряде присутствуют: хук первым сегментом с хард-катом после (plan.py:438-439), zoompan на hit/hook, ≥1 xfade, капшен на каждом hit, flash только в clips-режиме — проверяется покадровым дампом тестового рендера в XCTest (CI-сравнение: кадр на t=peak ярче соседних на ≥15%).
- **A6**: текстовка = title + desc (ротация без повторов в батче) + 6 хэштегов; кнопка «Скопировать» кладёт всё в UIPasteboard; share sheet работает.
- **A7**: голос: с сетью — edge-tts (Dmitry, story), без сети — рендер не падает, AVSpeech-фолбэк с пометкой в UI; повторный рендер того же текста — из кэша (без сетевого запроса, проверяется тестом с выключенным моком сети).
- **A8**: `make ios-install` от чистого чекаута до запущенного на телефоне — одна команда, ≤10 мин; повторная инкрементальная — ≤3 мин.
- **A9**: юнит-тесты DetectKit/PlanKit гоняются на Маке без симулятора (`swift test`), <60с.

## 8. Риски и митигации

| Риск | Митигация |
|---|---|
| Custom AVVideoCompositing — медленная отладка на устройстве (rebuild-resign-run вместо `uv run crcut`) | M4 изолирован; компоновщик разрабатывается как SPM-пакет с офлайн-рендером PNG-кадров в XCTest на Маке — на телефон едет уже отлаженным |
| Дак/лаудness DSP «это же просто компрессор» | Отложено в M7; критерий — не битэкзакт с ffmpeg, а «музыка проседает под голосом на 6–10dB с атакой ~15мс» + пик ≤ −1.5dBTP |
| edge-tts эндпоинт неофициальный, может сломаться | Фолбэк AVSpeech обязателен с M6; кэш переживает поломку для уже озвученных фраз |
| AVSpeech ru-RU звучит хуже Азуре | Спайк в начале M6; если совсем плохо — подсказка в UI скачать Enhanced-голос в Настройках (приложение умеет его обнаружить) |
| 7-дневная переподпись убивает момент | `make ios-install` = переподпись; заметка в README; риск процессный, не кодовый |
| OOM на длинных исходниках | Только стриминг AVAssetReader/Writer, ≤3 кадров в полёте; лимит батча (M8); анализ на даунскейле 240px как в detect.py:27 |
| HDR-скринрекорды | Принудительный SDR/bt709 на инжесте (решение №8) |
| Beat-снап пользовательской музыки выпрошен позже | Честно помечено v1.1; бандл-треки покрывают текущий UX полностью (fav/ловед-трек уже там) |

## 9. Верификация

- V1: `swift test` (DetectKit/PlanKit golden + юниты) — зелёный на каждом M.
- V2: XCTest рендер-дампы (A5) — зелёные с M4.
- V3: ручной чеклист на устройстве (A3, A4, A6, A7-офлайн) — перед закрытием M3/M5/M6/M8.
- V4: `uv run pytest -q` в корне остаётся зелёным (Python-репо не трогаем, кроме scripts/export_golden.py и tests/golden/).
- V5: side-by-side одного исходника: десктопный crcut vs iOS-рендер — субъективная приёмка пользователем (качество энкода, решение №6).

## 10. Вне объёма v1 (явно)

Импорт своей музыки с on-device beat tracking; стили голоса rasp/grandpa_deep с DSP-цепочками; фоновый рендер; iPad/лендскейп; публикация в App Store; автозагрузка в TikTok (API не даёт).
