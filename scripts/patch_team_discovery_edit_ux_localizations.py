#!/usr/bin/env python3
"""Insert Edit Team → Discovery & Location UX copy without rewriting the catalog."""
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
XCSTRINGS = ROOT / "GameOn" / "Localizable.xcstrings"

LANGS = ["de", "en", "es", "fr", "it", "nl", "pl", "pt", "ru", "sq", "zh-Hans"]

ENTRIES: dict[str, dict[str, str]] = {
    "team_discovery_show_on_discover_supporting": {
        "en": "When enabled, your Team can be found on the Play → Places map.",
        "es": "Si está activado, tu equipo aparece en el mapa de Jugar → Lugares.",
        "fr": "Lorsque c’est activé, votre équipe apparaît sur la carte Jouer → Lieux.",
        "pt": "Quando ativado, sua equipe aparece no mapa Jogar → Lugares.",
        "de": "Wenn aktiviert, ist dein Team auf der Karte Spielen → Orte zu finden.",
        "it": "Se attivo, la tua squadra è visibile sulla mappa Gioca → Luoghi.",
        "pl": "Po włączeniu zespół będzie widoczny na mapie Graj → Miejsca.",
        "ru": "Если включено, команду можно найти на карте «Играть → Места».",
        "sq": "Kur aktivizohet, ekipi juaj gjendet në hartën Luaj → Vendet.",
        "zh-Hans": "开启后，可在“玩 → 地点”地图上找到你的队伍。",
        "nl": "Als dit aan staat, is je team te vinden op de kaart Spelen → Plaatsen.",
    },
    "team_discovery_looking_for_players_supporting": {
        "en": "Let others know your Team is open to new players.",
        "es": "Haz saber que tu equipo admite nuevos jugadores.",
        "fr": "Indiquez que votre équipe accueille de nouveaux joueurs.",
        "pt": "Mostre que sua equipe está aberta a novos jogadores.",
        "de": "Zeige, dass dein Team neue Spieler aufnimmt.",
        "it": "Fai sapere che la tua squadra accoglie nuovi giocatori.",
        "pl": "Daj znać, że zespół przyjmuje nowych zawodników.",
        "ru": "Сообщите, что команда открыта для новых игроков.",
        "sq": "Tregoni se ekipi juaj pranon lojtarë të rinj.",
        "zh-Hans": "让其他人知道你的队伍欢迎新球员。",
        "nl": "Laat weten dat je team openstaat voor nieuwe spelers.",
    },
    "team_discovery_looking_for_players_private_hint": {
        "en": "Shown to others only when this Team is on Discover.",
        "es": "Solo se muestra a otros cuando el equipo está en Descubrir.",
        "fr": "Visible par les autres uniquement si l’équipe est dans Découvrir.",
        "pt": "Visível para outras pessoas somente quando a equipe estiver no Descobrir.",
        "de": "Für andere nur sichtbar, wenn das Team in Entdecken ist.",
        "it": "Visibile agli altri solo quando la squadra è in Scopri.",
        "pl": "Widoczne dla innych tylko gdy zespół jest w Odkrywaj.",
        "ru": "Другие видят это, только если команда в Обзоре.",
        "sq": "Shfaqet për të tjerët vetëm kur ekipi është në Zbulo.",
        "zh-Hans": "仅在队伍出现在发现中时向他人显示。",
        "nl": "Alleen zichtbaar voor anderen als dit team in Ontdekken staat.",
    },
    "team_discovery_location_supporting": {
        "en": "Choose a public location where your Team is based or most active.",
        "es": "Elige un lugar público donde tu equipo está o es más activo.",
        "fr": "Choisissez un lieu public où votre équipe est basée ou le plus active.",
        "pt": "Escolha um local público onde sua equipe fica ou é mais ativa.",
        "de": "Wähle einen öffentlichen Ort, an dem dein Team basiert oder am aktivsten ist.",
        "it": "Scegli un luogo pubblico in cui la squadra ha sede o è più attiva.",
        "pl": "Wybierz publiczne miejsce, w którym zespół ma siedzibę lub jest najbardziej aktywny.",
        "ru": "Выберите публичное место, где команда базируется или чаще всего играет.",
        "sq": "Zgjidhni një vend publik ku ekipi ka bazën ose është më aktiv.",
        "zh-Hans": "选择一个公开地点，作为队伍所在地或最常活动的地方。",
        "nl": "Kies een openbare locatie waar je team is gevestigd of het meest actief is.",
    },
    "team_discovery_change": {
        "en": "Change",
        "es": "Cambiar",
        "fr": "Modifier",
        "pt": "Alterar",
        "de": "Ändern",
        "it": "Cambia",
        "pl": "Zmień",
        "ru": "Изменить",
        "sq": "Ndrysho",
        "zh-Hans": "更改",
        "nl": "Wijzigen",
    },
    "team_discovery_choose_location": {
        "en": "Choose Team Location",
        "es": "Elegir ubicación del equipo",
        "fr": "Choisir le lieu de l’équipe",
        "pt": "Escolher local da equipe",
        "de": "Teamstandort wählen",
        "it": "Scegli posizione della squadra",
        "pl": "Wybierz lokalizację zespołu",
        "ru": "Выбрать место команды",
        "sq": "Zgjidh vendndodhjen e ekipit",
        "zh-Hans": "选择队伍位置",
        "nl": "Kies teamlocatie",
    },
    "team_discovery_specific_explainer": {
        "en": "Shows the selected location on the map.",
        "es": "Muestra la ubicación seleccionada en el mapa.",
        "fr": "Affiche le lieu sélectionné sur la carte.",
        "pt": "Mostra o local selecionado no mapa.",
        "de": "Zeigt den gewählten Standort auf der Karte.",
        "it": "Mostra la posizione selezionata sulla mappa.",
        "pl": "Pokazuje wybraną lokalizację na mapie.",
        "ru": "Показывает выбранное место на карте.",
        "sq": "Shfaq vendndodhjen e zgjedhur në hartë.",
        "zh-Hans": "在地图上显示所选位置。",
        "nl": "Toont de geselecteerde locatie op de kaart.",
    },
    "team_discovery_general_explainer": {
        "en": "Shows a broader area without the exact address.",
        "es": "Muestra una zona más amplia sin la dirección exacta.",
        "fr": "Affiche une zone plus large sans l’adresse exacte.",
        "pt": "Mostra uma área mais ampla sem o endereço exato.",
        "de": "Zeigt einen weiteren Bereich ohne die genaue Adresse.",
        "it": "Mostra un’area più ampia senza l’indirizzo esatto.",
        "pl": "Pokazuje szerszy obszar bez dokładnego adresu.",
        "ru": "Показывает более широкий район без точного адреса.",
        "sq": "Shfaq një zonë më të gjerë pa adresën e saktë.",
        "zh-Hans": "显示更大范围，不展示精确地址。",
        "nl": "Toont een groter gebied zonder het exacte adres.",
    },
    "team_discovery_location_privacy_home": {
        "en": "Never use a personal home address.",
        "es": "Nunca uses una dirección de casa personal.",
        "fr": "N’utilisez jamais une adresse personnelle.",
        "pt": "Nunca use um endereço residencial pessoal.",
        "de": "Verwende niemals eine private Wohnadresse.",
        "it": "Non usare mai un indirizzo di casa personale.",
        "pl": "Nigdy nie używaj prywatnego adresu domowego.",
        "ru": "Не указывайте личный домашний адрес.",
        "sq": "Mos përdorni kurrë një adresë shtëpie personale.",
        "zh-Hans": "请勿使用个人家庭住址。",
        "nl": "Gebruik nooit een persoonlijk thuisadres.",
    },
    "team_discovery_what_others_will_see": {
        "en": "What others will see",
        "es": "Lo que verán los demás",
        "fr": "Ce que les autres verront",
        "pt": "O que os outros verão",
        "de": "Was andere sehen",
        "it": "Cosa vedranno gli altri",
        "pl": "Co zobaczą inni",
        "ru": "Что увидят другие",
        "sq": "Çfarë do të shohin të tjerët",
        "zh-Hans": "其他人会看到什么",
        "nl": "Wat anderen zien",
    },
    "team_discovery_map_preview_specific_a11y": {
        "en": "Team location map preview. Selected location.",
        "es": "Vista previa del mapa de la ubicación del equipo. Ubicación seleccionada.",
        "fr": "Aperçu carte du lieu de l’équipe. Lieu sélectionné.",
        "pt": "Prévia do mapa da localização da equipe. Local selecionado.",
        "de": "Kartenvorschau des Teamstandorts. Ausgewählter Standort.",
        "it": "Anteprima mappa della posizione della squadra. Posizione selezionata.",
        "pl": "Podgląd mapy lokalizacji zespołu. Wybrana lokalizacja.",
        "ru": "Предпросмотр карты места команды. Выбранное место.",
        "sq": "Parapamja e hartës së vendndodhjes së ekipit. Vendndodhja e zgjedhur.",
        "zh-Hans": "队伍位置地图预览。已选择的位置。",
        "nl": "Kaartvoorbeeld van de teamlocatie. Geselecteerde locatie.",
    },
    "team_discovery_map_preview_general_a11y": {
        "en": "Team location map preview. Approximate area.",
        "es": "Vista previa del mapa de la ubicación del equipo. Zona aproximada.",
        "fr": "Aperçu carte du lieu de l’équipe. Zone approximative.",
        "pt": "Prévia do mapa da localização da equipe. Área aproximada.",
        "de": "Kartenvorschau des Teamstandorts. Ungefährer Bereich.",
        "it": "Anteprima mappa della posizione della squadra. Area approssimativa.",
        "pl": "Podgląd mapy lokalizacji zespołu. Przybliżony obszar.",
        "ru": "Предпросмотр карты места команды. Примерный район.",
        "sq": "Parapamja e hartës së vendndodhjes së ekipit. Zonë e përafërt.",
        "zh-Hans": "队伍位置地图预览。大致区域。",
        "nl": "Kaartvoorbeeld van de teamlocatie. Geschat gebied.",
    },
    "team_discovery_editors_only": {
        "en": "Only Team owners and editors can change Discovery settings.",
        "es": "Solo los propietarios y editores del equipo pueden cambiar los ajustes de Descubrimiento.",
        "fr": "Seuls les propriétaires et éditeurs de l’équipe peuvent modifier les réglages de Découverte.",
        "pt": "Somente proprietários e editores da equipe podem alterar as configurações de Descoberta.",
        "de": "Nur Teameigentümer und -bearbeiter können die Entdeckungseinstellungen ändern.",
        "it": "Solo i proprietari e gli editor della squadra possono modificare le impostazioni di Scoperta.",
        "pl": "Tylko właściciele i edytorzy zespołu mogą zmieniać ustawienia Odkrywania.",
        "ru": "Только владельцы и редакторы команды могут менять настройки обнаружения.",
        "sq": "Vetëm pronarët dhe redaktorët e ekipit mund të ndryshojnë cilësimet e Zbulimit.",
        "zh-Hans": "仅队伍所有者和编辑者可以更改发现设置。",
        "nl": "Alleen teameigenaren en -bewerkers kunnen Ontdekkingsinstellingen wijzigen.",
    },
    "team_discovery_location_required_supporting": {
        "en": "A location is required before the Team can appear on Discover.",
        "es": "Se necesita una ubicación para que el equipo aparezca en Descubrir.",
        "fr": "Un lieu est requis pour que l’équipe apparaisse dans Découvrir.",
        "pt": "É necessário um local para a equipe aparecer no Descobrir.",
        "de": "Ein Standort ist erforderlich, bevor das Team in Entdecken erscheint.",
        "it": "Serve una posizione perché la squadra appaia in Scopri.",
        "pl": "Lokalizacja jest wymagana, zanim zespół pojawi się w Odkrywaj.",
        "ru": "Чтобы команда появилась в Обзоре, нужно указать место.",
        "sq": "Nevojitet një vendndodhje para se ekipi të shfaqet në Zbulo.",
        "zh-Hans": "队伍出现在发现中之前必须选择位置。",
        "nl": "Er is een locatie nodig voordat het team in Ontdekken kan verschijnen.",
    },
}

SECTION_TITLE = {
    "de": "Entdeckung & Standort",
    "en": "Discovery & Location",
    "es": "Descubrimiento y ubicación",
    "fr": "Découverte et lieu",
    "it": "Scoperta e posizione",
    "nl": "Ontdekking en locatie",
    "pl": "Odkrywanie i lokalizacja",
    "pt": "Descoberta e local",
    "ru": "Обнаружение и место",
    "sq": "Zbulimi dhe vendndodhja",
    "zh-Hans": "发现与位置",
}

OLD_SECTION_TITLE = {
    "de": "Entdeckung",
    "en": "Discovery",
    "es": "Descubrimiento",
    "fr": "Découverte",
    "it": "Scoperta",
    "nl": "Ontdekking",
    "pl": "Odkrywanie",
    "pt": "Descoberta",
    "ru": "Обнаружение",
    "sq": "Zbulimi",
    "zh-Hans": "发现",
}


def unit(value: str) -> dict:
    return {"stringUnit": {"state": "translated", "value": value}}


def upsert(strings: dict, key: str, translations: dict[str, str]) -> None:
    entry = strings.get(key, {"extractionState": "manual", "localizations": {}})
    entry["extractionState"] = "manual"
    locs = entry.setdefault("localizations", {})
    for lang in LANGS:
        value = translations.get(lang, translations["en"])
        existing = locs.get(lang, {}).get("stringUnit", {}).get("value")
        if not existing:
            locs[lang] = unit(value)
        elif key == "team_discovery_section_title" and existing == OLD_SECTION_TITLE.get(lang):
            locs[lang] = unit(value)
    strings[key] = entry


def main() -> None:
    import json

    data = json.loads(XCSTRINGS.read_text(encoding="utf-8"))
    strings = data.setdefault("strings", {})
    upsert(strings, "team_discovery_section_title", SECTION_TITLE)
    for key, translations in ENTRIES.items():
        upsert(strings, key, translations)
    XCSTRINGS.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"upserted Discovery editor keys into {XCSTRINGS}")


if __name__ == "__main__":
    main()
