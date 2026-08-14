import CryptoKit
import Foundation

// Port of src/crcut/plan.py:621-838 (copy pools + title_for/desc_for/hashtags_for/plain_text).
// Strings copied verbatim (ru/en). Python reduces the full sha1 hexdigest as a
// 160-bit integer (`int(hexdigest, 16) % len(pool)`). Swift has no bignum, but
// `stablePoolIndex` doesn't need one: for `n mod count`, folding byte-by-byte as
// `acc = (acc * 256 + byte) % count` over the digest (big-endian, same order as
// the hex string) telescopes to the identical result -- bit-exact with Python.

public let titles: [String: [String]] = [
    "ru": [
        "ТАКОГО КЛАТЧА ТЫ ЕЩЁ НЕ ВИДЕЛ 😳",
        "ОН РЕАЛЬНО ЭТОГО НЕ ЖДАЛ 🔥",
        "ЛАСТ ХИТ РЕШИЛ ВСЁ ⚡",
        "ДОСМОТРИ ДО КОНЦА 👀",
        "ДОП. ВРЕМЯ РЕШАЕТ 👑",
        "Я НЕ ВЕРИЛ ДО ПОСЛЕДНЕЙ СЕКУНДЫ 😭",
    ],
    "en": [
        "THIS CLUTCH IS INSANE 😳",
        "HE REALLY DIDN'T SEE IT COMING 🔥",
        "LAST HIT DECIDED EVERYTHING ⚡",
        "WATCH TILL THE END 👀",
        "OVERTIME DECIDES IT 👑",
        "I DIDN'T BELIEVE IT TILL THE LAST SECOND 😭",
    ],
]

/// full cut / short one for the loop / long one for watch time
public let variantScale: [Double] = [1.0, 0.62, 1.28]

/// smooth ones only -- a hard wipe between two shots of the same arena reads as a glitch
public let transitions: [String] = [
    "smoothleft", "dissolve", "circleopen", "smoothup", "smoothright", "fadegrays",
]

// on-screen text goes through Pillow, which cannot draw colour emoji -- these stay plain.
// Deep enough that one run never repeats a line: three variants eat ~20 of them.
public let captions: [String: [String]] = [
    // alternating tease / payoff, so any contiguous slice still reads as a build-up
    "ru": [
        "СМОТРИ ДО КОНЦА", "ЭТО БЫЛО БОЛЬНО", "НЕ МОРГАЙ", "ОН В ШОКЕ",
        "СЕЙЧАС БУДЕТ", "ЛАСТ ХИТ", "А ТЕПЕРЬ ВНИМАНИЕ", "НУ И КАК ТЕБЕ",
        "ВОТ ЭТОТ МОМЕНТ", "ОН НЕ УСПЕЛ", "ОН ЕЩЁ НЕ ПОНЯЛ", "ТЫ ЭТО ВИДЕЛ",
        "ДАЛЬШЕ ХУЖЕ", "ТУТ ОН СЛОМАЛСЯ", "ЭТО ЕЩЁ НЕ ВСЁ", "НИКТО НЕ ОЖИДАЛ",
        "ДЕРЖИСЬ", "ОН ДУМАЛ ЧТО ВЫИГРАЛ", "ВОТ ТУТ НАЧАЛОСЬ", "БЕЗ ШАНСОВ",
        "ВОТ ЗАЧЕМ ТЫ ЗДЕСЬ", "КАК ОН ВЫЖИЛ", "ЗАПОМНИ ЭТОТ КАДР", "ЭТО ВООБЩЕ ЛЕГАЛЬНО",
        "СЕКУНДА РЕШИЛА ВСЁ", "ПЕРЕМОТАЙ И ГЛЯНЬ", "ЭТО КОНЕЦ", "Я ПЕРЕСМОТРЕЛ 10 РАЗ",
        "ПОПРОБУЙ ПОВТОРИ", "ГГ",
    ],
    "en": [
        "WATCH TILL THE END", "THAT HURT", "DO NOT BLINK", "HE IS DONE",
        "HERE IT COMES", "LAST HIT", "NOW WATCH THIS", "HOW WAS THAT",
        "THIS IS THE MOMENT", "TOO LATE", "HE HAS NO IDEA", "DID YOU SEE THAT",
        "IT GETS WORSE", "HERE HE BROKE", "NOT DONE YET", "NOBODY SAW IT",
        "HOLD ON", "HE THOUGHT HE WON", "IT STARTS HERE", "NO CHANCE",
        "THIS IS WHY YOU CAME", "HOW DID HE LIVE", "REMEMBER THIS FRAME", "IS THIS EVEN LEGAL",
        "ONE SECOND DECIDED IT", "REWIND AND LOOK", "THIS IS THE END", "I REWATCHED IT TEN TIMES",
        "TRY TO REPEAT THAT", "GG",
    ],
]

// never drawn, only spoken -- so these are written the way they are said, not shouted.
// Short: they land on the tail of a moment and must be over before the next one.
public let adlibs: [String: [String]] = [
    "ru": [
        "Ох ты ж!", "Ай-ай-ай...", "Ну ты даёшь!", "Э, куда собрался?!",
        "Во! Вот это дед понимает!", "Ну-ну... ну-ну.", "В моё время так не умели!",
        "Тьфу ты, ну!", "Спокойно. Я всё видел.", "Ох, батюшки-и...",
        "Молодец, внучек!", "Ну всё. Финиш.", "Я аж привстал!",
        "Не смотри... там страшно.", "Вот так вот, да!", "Ай, красиво-о!",
    ],
    "en": [
        "Oh boy!", "Well, well...", "Easy now!", "Hey! Where do you think you are going?!",
        "Back in my day...", "Oh dear-r...", "Not bad, kid!", "Goodness me!",
        "That is all, folks.", "I did warn him!", "Hoo boy...", "Watch him go!",
        "I nearly stood up!", "Do not look... it is scary.", "There we go!", "Oh, that is nice-e!",
    ],
]

// researched 2026-08: 4 game tags + 2 discovery, ordered specific -> broad.
// ru spelling "клешроаль" is what CR clippers actually type, not the correct one
public let hashtags: [String: [String]] = [
    "ru": ["#клешроаль", "#клеш", "#эдит", "#clashroyale", "#рек", "#fyp"],
    "en": ["#clashroyale", "#clashtok", "#cardevolution", "#clashroyalemoments",
           "#gaming", "#fyp"],
]

// the second line of the post: the title hooks, this one makes the viewer act.
// researched 2026-08 from viral gaming captions: POV / open loop / save-share CTA /
// comment bait / tag-a-friend / challenge -- 20 per language, so a whole run of
// clips never repeats a line
public let descriptions: [String: [String]] = [
    "ru": [
        "POV: у тебя один пуш до потери башни 😳",
        "Досмотри до конца, там разворот",
        "Сохрани это перед следующей каткой",
        "Оцени катку от 1 до 10 в комментах",
        "Отметь того, кто всегда сливает клатч",
        "Смотри до последней секунды, не пожалеешь",
        "Это видео зациклено не просто так 👀",
        "Плюс если этот пуш заслужил победу",
        "Угадай, какая карта спасла раунд",
        "Думал что в безопасности, ага щас",
        "Никто не предупредил, что так бывает",
        "Попробуй не зажмуриться на последней секунде",
        "Кинь другу, который сливает 2x эликсир",
        "Смог бы ты повторить этот клатч",
        "Все ненавидят такую деку, признавайтесь",
        "Кидай 🔥 если башня заслужила такой обмен",
        "Если честно, руки тряслись весь раунд",
        "Скрин этой деки, пока не удалили",
        "Пересмотри, ты что-то пропустил в начале",
        "Притормози и глянь последние 3 секунды",
    ],
    "en": [
        "POV: you're one push away from losing this tower 😳",
        "Wait for the ending, it's not what you think",
        "Save this before your next match, trust me",
        "Comment your rating 1-10, no cap",
        "Tag someone who always chokes at 2x elixir",
        "Watch till the last second, I promise it's worth it",
        "This clip loops for a reason, look closely 👀",
        "Rate my push before you scroll away",
        "Guess what card saves this round",
        "Bro thought he was safe lol",
        "Nobody warned me this could happen",
        "Try not to flinch at the last second",
        "Share this with your duo partner rn",
        "Could you have pulled this off",
        "All my homies hate this matchup",
        "Drop a 🔥 if this deserved the win",
        "Not gonna lie, my hands were shaking",
        "Screenshot this deck before it's gone",
        "Replay it, you missed something first time",
        "Slow down and watch the last 3 seconds",
    ],
]

/// sha1-seeded, deterministic pool index; bit-exact with Python's
/// `int(hexdigest, 16) % count` (see file header).
func stablePoolIndex(seed: String, count: Int) -> Int {
    precondition(count > 0)
    let digest = Insecure.SHA1.hash(data: Data(seed.utf8))
    var acc = 0
    for byte in digest {
        acc = (acc * 256 + Int(byte)) % count
    }
    return acc
}

public func titleFor(_ lang: String, _ seed: String) -> String {
    let pool = titles[lang] ?? titles["ru"]!
    return pool[stablePoolIndex(seed: seed, count: pool.count)]
}

/// Rotate through the pool: clips uploaded as one batch must not share a line.
public func descFor(_ lang: String, _ seed: String, idx: Int = 0) -> String {
    let pool = descriptions[lang] ?? descriptions["ru"]!
    let off = stablePoolIndex(seed: seed, count: pool.count)
    return pool[(off + idx) % pool.count]
}

public func hashtagsFor(_ lang: String) -> [String] {
    hashtags[lang] ?? hashtags["ru"]!
}

/// Drop emoji: they belong in the .txt sidecar, not in a Pillow-rendered caption.
public func plainText(_ text: String) -> String {
    let filtered = String(text.unicodeScalars.filter { $0.value < 0x2000 })
    return filtered.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}
