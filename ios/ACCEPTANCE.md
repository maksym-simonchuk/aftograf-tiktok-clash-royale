# CRCut iOS — приёмка (A1-A9)

Источник критериев: `.omc/plans/2026-08-13-ios-crcut-app.md` §7. Для каждого —
точная команда проверки и текущий статус. Обновлять по мере закрытия M-этапов
(§6 того же плана).

Общая команда для пакетов на Маке (без симулятора/устройства):
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```
(запускать в `ios/Packages/<Kit>/`)

---

## A1 — golden-тест детекции
> На фикстуре найдены все 3 синтетических импакта ±2.0с, ни одного вне матч-окна (паритет с `tests/test_detect.py`).

- Проверка: `cd ios/Packages/DetectKit && DEVELOPER_DIR=... swift test` — golden-тест сравнивает с `tests/golden/analysis.json`.
- Статус: **зелёно** — DetectKit, 23 теста / 5 сьютов, 0 failures (#3 закрыт). Golden-тест: допуск таймстампов 1.2с задокументирован в тесте. Реальные кадры (МАТЧ1): 6/6 хайлайтов найдено, макс. отклонение 0.1с.

## A2 — golden-тест плана
> Сегменты Swift == Python (kind/speed/границы, точность 1e-6 на одинаковых входах); клип ≤20.0с; монтаж — 3 варианта с масштабами 1.0/0.62/1.28.

- Проверка: `cd ios/Packages/PlanKit && DEVELOPER_DIR=... swift test` — golden-тесты против `tests/golden/plan_clips.json` / `plan_montage.json`.
- Статус: **зелёно** — PlanKit, 35 тестов, 0 failures.

## A3 — реальный рендер на устройстве
> На реальном скринрекорде матча (~2 мин) приложение собирает клипы и сохраняет в Фото; ролик открывается в галерее, 1080×1920@30, есть аудиодорожка.

- Проверка: ручной чеклист на устройстве (§9 V3) — импорт скринрекорда → рендер → Photos → открыть ролик, проверить разрешение/fps/аудиодорожку в Инфо.
- Статус: **не проверено** (нужен установленный билд на телефоне, M3+M5 минимум).

## A4 — батч без OOM/перегрева
> Батч 3×2мин → 3 монтажа доезжает до конца на устройстве пользователя без memory warning и без `thermalState == .critical`.

- Проверка: ручной прогон на устройстве (§9 V3), смотреть Xcode Debug Navigator (Memory) + `ProcessInfo.thermalState` лог во время батча.
- Статус: **не проверено** (блокируется M8: лимит батча ≤5/≤15мин, термальный отклик).

## A5 — филтерграф-паритет визуального слоя
> В видеоряде присутствуют: хук первым сегментом с хард-катом после, zoompan на hit/hook, ≥1 xfade, капшен на каждом hit, flash только в clips-режиме — проверяется покадровым дампом тестового рендера в XCTest (кадр на t=peak ярче соседних на ≥15%).

- Проверка: `cd ios/Packages/RenderKit && DEVELOPER_DIR=... swift test` — покадровые офлайн-тесты компоновщика (flash brightness, xfade mid-frame blend, caption line-count) плюс `RoughCutTests` на golden-фикстуре.
- Статус: **зелёно на уровне пакета** — RenderKit, 21 тест / 5 сьютов, 0 failures (#7 + #9 закрыты): `CompositorEffectsTests` — flash ≥15% ярче соседних, xfade все 6 kinds, капшены ≤3 строк; `M7PolishTests` — дакинг+лаудность цифрами (outputLUFS=-13.998, таргет -14, diff 0.0019 LU; дакинг -29.74дБ, 0.4788→0.0156 под войсом); старые сьюты (AudioMix/Loudness/RoughCut) целы. `xcodebuild -scheme CRCut -destination generic/platform=iOS` — BUILD SUCCEEDED (с VoiceKit).

## A6 — текстовка + share
> Текстовка = title + desc (ротация без повторов в батче) + 6 хэштегов; кнопка «Скопировать» кладёт всё в UIPasteboard; share sheet работает.

- Проверка: PlanKit golden/юниты на ротацию title/desc/hashtags (`swift test`) + ручная проверка UIPasteboard/`UIActivityViewController` на устройстве.
- Статус: **ЗАКРЫТ**:
  - title без повторов в батче — `PlanBehaviorTests.swift:61 variantsDifferInLengthAndOpening` (`Set(titles).count == 3` на 3 варианта монтажа).
  - caption/adlib без повторов — `PlanBehaviorTests.swift:37 noCaptionIsReusedAcrossVariants`, `:46 adlibsAreSpokenBetweenTheCaptionsAndNeverRepeat`.
  - hashtags per-lang — `PlanBehaviorTests.swift:284 langFlagSwitchesCopy` (проверяет наличие `#рек`/`#fyp`; пул фиксирован — 6 штук на язык, `Copy.swift:84-88`).
  - desc (описание поста) подключено: `Pipeline.roughCutRender(source:idx:)` возвращает `(url, caption)`, формат — точный порт cli.py:57-60: `title + "\n" + descFor(lang, seed, idx:) + "\n\n" + hashtags.joined(" ") + "\n"`. `descSeed = plan.sources.joined(separator: "|")` (полные пути, как в Python). Ротация без повторов в батче — через `idx` = индекс элемента очереди. `QueueItem.caption` — stored property, перезаписывается результатом рендера.
  - UI-часть (UIPasteboard/share) — **не проверено**, нужно устройство.

## A7 — голос (edge-tts + офлайн-фолбэк + кэш)
> С сетью — edge-tts (Dmitry, story), без сети — рендер не падает, AVSpeech-фолбэк с пометкой в UI; повторный рендер того же текста — из кэша (без сетевого запроса, тест с выключенным моком сети).

- Проверка: `cd ios/Packages/VoiceKit && DEVELOPER_DIR=... swift test` (включая тест кэша с отключённой сетью) + ручной спайк AVSpeech ru-RU на устройстве (§6 M6).
- Статус: **зелёно (юниты)** — VoiceKit, 21 тест, 0 failures. Ручная проверка на устройстве (сеть выкл/вкл) — не проведена.

## A8 — однокомандная сборка+установка
> `make ios-install` от чистого чекаута до запущенного на телефоне — одна команда, ≤10 мин; повторная инкрементальная — ≤3 мин.

- Проверка: `cd ios && time make ios-install` (сначала `git clean` для «чистого чекаута», затем повторный прогон без clean).
- Статус: **не проверено**.

## A9 — юниты без симулятора, <60с
> Юнит-тесты DetectKit/PlanKit гоняются на Маке без симулятора (`swift test`), <60с.

- Проверка:
  ```
  cd ios/Packages/DetectKit && time DEVELOPER_DIR=... swift test
  cd ios/Packages/PlanKit  && time DEVELOPER_DIR=... swift test
  ```
- Статус: **зелёно, укладывается** — PlanKit 35 тестов (доли секунды), DetectKit 23 теста (~19с, golden-тесты декодируют фикстуру). Оба <60с.

---

## Сводка по пакетам (числа тестов, последняя проверка)

| Пакет | Тесты | Suites | Failures | Задача |
|---|---|---|---|---|
| PlanKit | 35 | 3 | 0 | #2, #8 (fav-исключение) закрыты |
| RenderKit | 21 | 5 | 0 | #6 (M3), #7 (M4), #9 (M7 полировка) закрыты |
| VoiceKit | 21 | — | 0 | #5 закрыт |
| DetectKit | 23 | 5 | 0 | #3 закрыт |

Приложение (`ios/`): `xcodebuild -scheme CRCut -destination generic/platform=iOS -allowProvisioningUpdates CODE_SIGNING_ALLOWED=NO build` — BUILD SUCCEEDED.

Общий Python-репо: `uv run pytest -q` должен оставаться зелёным (§9 V4) — не тронут портом, кроме `scripts/export_golden.py`/`tests/golden/`.

## UI polish (заметка, #10)

Тёмная тема (фон `#0E0F13`), брендовый акцент gold `#F7D046` (тот же цвет, что прогресс-бар в видео — `RenderKit/Effects/ProgressBar.swift`), чёрный текст на золотых CTA, статус-капсулы в очереди, видимая строка ошибки в ряду (замена macOS-only `.help()`). Не имеет отдельного A-критерия — сопутствует A6/A4 (очередь).
