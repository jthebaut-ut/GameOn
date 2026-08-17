#!/usr/bin/env python3
"""Team sport-position labels and leftover lineup/editor keys."""
from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
XCSTRINGS = ROOT / "GameOn" / "Localizable.xcstrings"
SUPPORTED = ["en", "es", "fr", "pt", "de", "it", "pl", "ru", "sq", "zh-Hans", "nl"]


def unit(value: str) -> dict:
    return {"stringUnit": {"state": "translated", "value": value}}


def tr(en: str, es: str, fr: str, pt: str, de: str, it: str, pl: str, ru: str, sq: str, zh: str, nl: str) -> dict[str, str]:
    return {
        "en": en, "es": es, "fr": fr, "pt": pt, "de": de,
        "it": it, "pl": pl, "ru": ru, "sq": sq, "zh-Hans": zh, "nl": nl,
    }


ENTRIES: dict[str, dict[str, str]] = {
    "fan_team_lineup_add_players": tr("Add Players", "Añadir jugadores", "Ajouter des joueurs", "Adicionar jogadores", "Spieler hinzufügen", "Aggiungi giocatori", "Dodaj zawodników", "Добавить игроков", "Shto lojtarë", "添加球员", "Spelers toevoegen"),
    "fan_team_lineup_select_position": tr("Select Position", "Seleccionar posición", "Choisir le poste", "Selecionar posição", "Position wählen", "Seleziona posizione", "Wybierz pozycję", "Выбрать позицию", "Zgjidh pozicionin", "选择位置", "Positie kiezen"),
    "fan_team_lineup_move_to_starting": tr("Move to Starting", "Mover a titulares", "Mettre titulaire", "Mover para titulares", "In die Startelf", "Sposta tra i titolari", "Przenieś do składu", "В стартовый состав", "Kalo te startuesit", "移至首发", "Naar de basis"),
    "fan_team_lineup_move_to_bench": tr("Move to Bench", "Mover al banquillo", "Mettre sur le banc", "Mover para o banco", "Auf die Bank", "Sposta in panchina", "Przenieś na ławkę", "На скамейку", "Kalo te stola", "移至替补", "Naar de bank"),
    "fan_team_lineup_remove": tr("Remove from Lineup", "Quitar de la alineación", "Retirer de la composition", "Remover da escalação", "Aus der Aufstellung entfernen", "Rimuovi dalla formazione", "Usuń ze składu", "Убрать из состава", "Hiq nga formacioni", "从阵容移除", "Uit opstelling verwijderen"),
    "fan_team_lineup_no_response_count_format": tr("%lld no response", "%lld sin respuesta", "%lld sans réponse", "%lld sem resposta", "%lld ohne Antwort", "%lld senza risposta", "%lld bez odpowiedzi", "%lld без ответа", "%lld pa përgjigje", "%lld 人未回复", "%lld geen reactie"),
    "fan_team_lineup_change_position": tr("Change Position", "Cambiar posición", "Modifier le poste", "Alterar posição", "Position ändern", "Cambia posizione", "Zmień pozycję", "Изменить позицию", "Ndrysho pozicionin", "更改位置", "Positie wijzigen"),
    "fan_team_lineup_clear_position": tr("Clear Position", "Quitar posición", "Effacer le poste", "Limpar posição", "Position entfernen", "Rimuovi posizione", "Usuń pozycję", "Сбросить позицию", "Hiq pozicionin", "清除位置", "Positie wissen"),
    "fan_teams_set_player_position": tr("Set Position", "Asignar posición", "Définir le poste", "Definir posição", "Position festlegen", "Imposta posizione", "Ustaw pozycję", "Назначить позицию", "Cakto pozicionin", "设置位置", "Positie instellen"),
    "fan_teams_change_player_position": tr("Change Position", "Cambiar posición", "Modifier le poste", "Alterar posição", "Position ändern", "Cambia posizione", "Zmień pozycję", "Изменить позицию", "Ndrysho pozicionin", "更改位置", "Positie wijzigen"),
    "fan_teams_remove_player_position": tr("Remove Position", "Quitar posición", "Supprimer le poste", "Remover posição", "Position entfernen", "Rimuovi posizione", "Usuń pozycję", "Убрать позицию", "Hiq pozicionin", "移除位置", "Positie verwijderen"),
    "fan_teams_player_position": tr("Position", "Posición", "Poste", "Posição", "Position", "Posizione", "Pozycja", "Позиция", "Pozicioni", "位置", "Positie"),
    "fan_teams_filter_a11y": tr("%@, %lld", "%@, %lld", "%@, %lld", "%@, %lld", "%@, %lld", "%@, %lld", "%@, %lld", "%@, %lld", "%@, %lld", "%@，%lld", "%@, %lld"),
    "fan_teams_filter_a11y_selected": tr("%@, %lld, selected", "%@, %lld, seleccionado", "%@, %lld, sélectionné", "%@, %lld, selecionado", "%@, %lld, ausgewählt", "%@, %lld, selezionato", "%@, %lld, wybrane", "%@, %lld, выбрано", "%@, %lld, zgjedhur", "%@，%lld，已选", "%@, %lld, geselecteerd"),
    "fan_team_schedule_rsvp_is_going_format": tr("%@ is Going", "%@ asiste", "%@ est présent(e)", "%@ vai", "%@ geht hin", "%@ partecipa", "%@ idzie", "%@ идёт", "%@ shkon", "%@ 将参加", "%@ gaat"),
    "fan_team_schedule_rsvp_may_be_going_format": tr("%@ may be going", "%@ quizá asista", "%@ sera peut-être là", "%@ talvez vá", "%@ kommt vielleicht", "%@ forse partecipa", "%@ może pójść", "%@ возможно пойдёт", "%@ ndoshta shkon", "%@ 可能参加", "%@ gaat misschien"),
    "fan_team_schedule_rsvp_cant_go_format": tr("%@ can’t go", "%@ no puede ir", "%@ ne peut pas venir", "%@ não pode ir", "%@ kann nicht", "%@ non può", "%@ nie może", "%@ не может", "%@ nuk mund", "%@ 去不了", "%@ kan niet"),
    # Groups
    "fan_team_position_group_goalkeeper": tr("Goalkeeper", "Portero", "Gardien", "Goleiro", "Torwart", "Portiere", "Bramkarz", "Вратарь", "Portier", "守门员", "Keeper"),
    "fan_team_position_group_defense": tr("Defense", "Defensa", "Défense", "Defesa", "Abwehr", "Difesa", "Obrona", "Защита", "Mbrojtje", "后卫", "Verdediging"),
    "fan_team_position_group_midfield": tr("Midfield", "Centrocampo", "Milieu", "Meio-campo", "Mittelfeld", "Centrocampo", "Pomoc", "Полузащита", "Mesfushë", "中场", "Middenveld"),
    "fan_team_position_group_attack": tr("Attack", "Ataque", "Attaque", "Ataque", "Angriff", "Attacco", "Atak", "Нападение", "Sulm", "前锋", "Aanval"),
    "fan_team_position_group_pitcher_catcher": tr("Pitcher & Catcher", "Lanzador y receptor", "Lanceur et receveur", "Arremessador e receptor", "Pitcher & Catcher", "Lanciatore e ricevitore", "Miotacz i łapacz", "Питчер и кэтчер", "Hedhës dhe kapës", "投手与捕手", "Pitcher en catcher"),
    "fan_team_position_group_infield": tr("Infield", "Cuadro", "Intérieur", "Inner field", "Infield", "Interno", "Infield", "Инфилд", "Brendësia", "内野", "Binnenveld"),
    "fan_team_position_group_outfield": tr("Outfield", "Jardín", "Extérieur", "Outer field", "Outfield", "Esterno", "Outfield", "Аутфилд", "Jashtësia", "外野", "Buitenveld"),
    "fan_team_position_group_dh": tr("Designated Hitter", "Bateador designado", "Frappeur désigné", "Batedor designado", "Designated Hitter", "Designated hitter", "Designated hitter", "Назначенный бьющий", "Goditës i caktuar", "指定打击", "Aangewezen slagman"),
    "fan_team_position_group_guards": tr("Guards", "Bases", "Arrières", "Armadores", "Guards", "Guard", "Rozgrywający", "Защитники", "Gardianë", "后卫", "Guards"),
    "fan_team_position_group_forwards": tr("Forwards", "Aleros", "Ailiers", "Ala", "Forwards", "Ali", "Skrzydłowi", "Форварды", "Sulmues", "前锋", "Forwards"),
    "fan_team_position_group_center": tr("Center", "Pívot", "Pivot", "Pivô", "Center", "Centro", "Środkowy", "Центровой", "Qendër", "中锋", "Center"),
    "fan_team_position_group_offense": tr("Offense", "Ataque", "Attaque", "Ataque", "Offense", "Attacco", "Ofensywa", "Нападение", "Sulm", "进攻", "Offense"),
    "fan_team_position_group_special_teams": tr("Special Teams", "Equipos especiales", "Unités spéciales", "Special teams", "Special Teams", "Special team", "Special teams", "Спецкоманды", "Ekipe speciale", "特勤组", "Special teams"),
    "fan_team_position_group_goaltender": tr("Goaltender", "Portero", "Gardien", "Goleiro", "Torhüter", "Portiere", "Bramkarz", "Вратарь", "Portier", "守门员", "Keeper"),
    "fan_team_position_group_setters": tr("Setters", "Colocadores", "Passeurs", "Levantadores", "Zuspieler", "Palleggiatori", "Rozgrywający", "Связующие", "Vendosës", "二传", "Spelverdelers"),
    "fan_team_position_group_hitters": tr("Hitters", "Atacantes", "Attaquants", "Atacantes", "Angreifer", "Schiacciatori", "Atakujący", "Диагональные", "Goditës", "攻手", "Aanvallers"),
    "fan_team_position_group_middle": tr("Middle", "Centrales", "Centraux", "Centrais", "Mittelblocker", "Centrali", "Środkowi", "Центральные", "Mes", "副攻", "Midden"),
    "fan_team_position_group_libero_defense": tr("Libero & Defense", "Líbero y defensa", "Libéro et défense", "Líbero e defesa", "Libero & Abwehr", "Libero e difesa", "Libero i obrona", "Либеро и защита", "Libero dhe mbrojtje", "自由人与防守", "Libero en verdediging"),
    # Soccer
    "fan_team_position_gk": tr("Goalkeeper", "Portero", "Gardien", "Goleiro", "Torwart", "Portiere", "Bramkarz", "Вратарь", "Portier", "守门员", "Keeper"),
    "fan_team_position_lb": tr("Left Back", "Lateral izquierdo", "Latéral gauche", "Lateral esquerdo", "Linker Verteidiger", "Terzino sinistro", "Lewy obrońca", "Левый защитник", "Mbrojtës i majtë", "左后卫", "Linksback"),
    "fan_team_position_cb": tr("Center Back", "Central", "Défenseur central", "Zagueiro", "Innenverteidiger", "Difensore centrale", "Środkowy obrońca", "Центральный защитник", "Mbrojtës qendror", "中后卫", "Centrale verdediger"),
    "fan_team_position_rb": tr("Right Back", "Lateral derecho", "Latéral droit", "Lateral direito", "Rechter Verteidiger", "Terzino destro", "Prawy obrońca", "Правый защитник", "Mbrojtës i djathtë", "右后卫", "Rechtsback"),
    "fan_team_position_lwb": tr("Left Wing Back", "Carrilero izquierdo", "Pistón gauche", "Ala esquerda", "Linker Flügelverteidiger", "Esterno sinistro", "Lewy wahadłowy", "Левый латераль", "Krah i majtë mbrojtës", "左边卫", "Linker vleugelverdediger"),
    "fan_team_position_rwb": tr("Right Wing Back", "Carrilero derecho", "Pistón droit", "Ala direita", "Rechter Flügelverteidiger", "Esterno destro", "Prawy wahadłowy", "Правый латераль", "Krah i djathtë mbrojtës", "右边卫", "Rechter vleugelverdediger"),
    "fan_team_position_def": tr("Defender", "Defensa", "Défenseur", "Defensor", "Verteidiger", "Difensore", "Obrońca", "Защитник", "Mbrojtës", "后卫", "Verdediger"),
    "fan_team_position_cdm": tr("Defensive Midfielder", "Mediocentro defensivo", "Milieu défensif", "Volante defensivo", "Sechser", "Mediano", "Defensywny pomocnik", "Опорный полузащитник", "Mesfushor mbrojtës", "后腰", "Verdedigende middenvelder"),
    "fan_team_position_cm": tr("Central Midfielder", "Mediocentro", "Milieu central", "Meia central", "Achter", "Centrocampista", "Środkowy pomocnik", "Центральный полузащитник", "Mesfushor qendror", "中前卫", "Centrale middenvelder"),
    "fan_team_position_cam": tr("Attacking Midfielder", "Mediapunta", "Milieu offensif", "Meia ofensivo", "Zehn", "Trequartista", "Ofensywny pomocnik", "Атакующий полузащитник", "Mesfushor sulmues", "前腰", "Aanvallende middenvelder"),
    "fan_team_position_lm": tr("Left Midfielder", "Interior izquierdo", "Milieu gauche", "Meia esquerda", "Linkes Mittelfeld", "Centrocampista sinistro", "Lewy pomocnik", "Левый полузащитник", "Mesfushor i majtë", "左前卫", "Linkermiddenvelder"),
    "fan_team_position_rm": tr("Right Midfielder", "Interior derecho", "Milieu droit", "Meia direita", "Rechtes Mittelfeld", "Centrocampista destro", "Prawy pomocnik", "Правый полузащитник", "Mesfushor i djathtë", "右前卫", "Rechtermiddenvelder"),
    "fan_team_position_mid": tr("Midfielder", "Centrocampista", "Milieu", "Meia", "Mittelfeldspieler", "Centrocampista", "Pomocnik", "Полузащитник", "Mesfushor", "中场", "Middenvelder"),
    "fan_team_position_lw": tr("Left Wing", "Extremo izquierdo", "Ailier gauche", "Ponta esquerda", "Linksaußen", "Ala sinistra", "Lewy skrzydłowy", "Левый вингер", "Krah i majtë", "左边锋", "Linksbuiten"),
    "fan_team_position_rw": tr("Right Wing", "Extremo derecho", "Ailier droit", "Ponta direita", "Rechtsaußen", "Ala destra", "Prawy skrzydłowy", "Правый вингер", "Krah i djathtë", "右边锋", "Rechtsbuiten"),
    "fan_team_position_cf": tr("Center Forward", "Delantero centro", "Avant-centre", "Centroavante", "Mittelstürmer", "Centravanti", "Środkowy napastnik", "Центральный нападающий", "Sulmues qendror", "中锋", "Spits"),
    "fan_team_position_st": tr("Striker", "Delantero", "Attaquant", "Atacante", "Stürmer", "Attaccante", "Napastnik", "Нападающий", "Sulmues", "前锋", "Spits"),
    "fan_team_position_fwd": tr("Forward", "Delantero", "Attaquant", "Atacante", "Stürmer", "Attaccante", "Napastnik", "Нападающий", "Sulmues", "前锋", "Aanvaller"),
    # Baseball
    "fan_team_position_p": tr("Pitcher", "Lanzador", "Lanceur", "Arremessador", "Pitcher", "Lanciatore", "Miotacz", "Питчер", "Hedhës", "投手", "Pitcher"),
    "fan_team_position_c_baseball": tr("Catcher", "Receptor", "Receveur", "Receptor", "Catcher", "Ricevitore", "Łapacz", "Кэтчер", "Kapës", "捕手", "Catcher"),
    "fan_team_position_1b": tr("First Base", "Primera base", "Premier but", "Primeira base", "Erste Base", "Prima base", "Pierwsza baza", "Первая база", "Baza e parë", "一垒", "Eerste honk"),
    "fan_team_position_2b": tr("Second Base", "Segunda base", "Deuxième but", "Segunda base", "Zweite Base", "Seconda base", "Druga baza", "Вторая база", "Baza e dytë", "二垒", "Tweede honk"),
    "fan_team_position_3b": tr("Third Base", "Tercera base", "Troisième but", "Terceira base", "Dritte Base", "Terza base", "Trzecia baza", "Третья база", "Baza e tretë", "三垒", "Derde honk"),
    "fan_team_position_ss": tr("Shortstop", "Campocorto", "Arrêt-court", "Interbases", "Shortstop", "Interbase", "Łącznik", "Шортстоп", "Ndalues i shkurtër", "游击手", "Korte stop"),
    "fan_team_position_lf": tr("Left Field", "Jardín izquierdo", "Champ gauche", "Jardinheiro esquerdo", "Left Field", "Esterno sinistro", "Lewy zapolowy", "Левый филдер", "Fusha e majtë", "左外野", "Linksveld"),
    "fan_team_position_cf_baseball": tr("Center Field", "Jardín central", "Champ centre", "Jardinheiro central", "Center Field", "Esterno centro", "Środkowy zapolowy", "Центральный филдер", "Fusha qendrore", "中外野", "Middenveld"),
    "fan_team_position_rf": tr("Right Field", "Jardín derecho", "Champ droit", "Jardinheiro direito", "Right Field", "Esterno destro", "Prawy zapolowy", "Правый филдер", "Fusha e djathtë", "右外野", "Rechtsveld"),
    "fan_team_position_dh": tr("Designated Hitter", "Bateador designado", "Frappeur désigné", "Batedor designado", "Designated Hitter", "Designated hitter", "Designated hitter", "Назначенный бьющий", "Goditës i caktuar", "指定打击", "Aangewezen slagman"),
    # Basketball
    "fan_team_position_pg": tr("Point Guard", "Base", "Meneur", "Armador", "Point Guard", "Playmaker", "Rozgrywający", "Разыгрывающий", "Organizator", "控球后卫", "Point guard"),
    "fan_team_position_sg": tr("Shooting Guard", "Escolta", "Arrière", "Ala-armador", "Shooting Guard", "Guardia", "Rzucający obrońca", "Атакующий защитник", "Gardian hedhës", "得分后卫", "Shooting guard"),
    "fan_team_position_sf": tr("Small Forward", "Alero", "Ailier", "Ala", "Small Forward", "Ala piccola", "Niski skrzydłowy", "Лёгкий форвард", "Sulmues i vogël", "小前锋", "Small forward"),
    "fan_team_position_pf": tr("Power Forward", "Ala-pívot", "Ailier fort", "Ala de força", "Power Forward", "Ala grande", "Silny skrzydłowy", "Тяжёлый форвард", "Sulmues i fuqishëm", "大前锋", "Power forward"),
    "fan_team_position_c_basketball": tr("Center", "Pívot", "Pivot", "Pivô", "Center", "Centro", "Środkowy", "Центровой", "Qendër", "中锋", "Center"),
    # Football
    "fan_team_position_qb": tr("Quarterback", "Quarterback", "Quarterback", "Quarterback", "Quarterback", "Quarterback", "Quarterback", "Квотербек", "Quarterback", "四分卫", "Quarterback"),
    "fan_team_position_rb_fb": tr("Running Back", "Running back", "Running back", "Running back", "Running Back", "Running back", "Running back", "Ранинбек", "Running back", "跑卫", "Running back"),
    "fan_team_position_wr": tr("Wide Receiver", "Wide receiver", "Wide receiver", "Wide receiver", "Wide Receiver", "Wide receiver", "Wide receiver", "Уайд-ресивер", "Wide receiver", "外接手", "Wide receiver"),
    "fan_team_position_te": tr("Tight End", "Tight end", "Tight end", "Tight end", "Tight End", "Tight end", "Tight end", "Тайт-энд", "Tight end", "近端锋", "Tight end"),
    "fan_team_position_ol": tr("Offensive Line", "Línea ofensiva", "Ligne offensive", "Linha ofensiva", "Offensive Line", "Linea offensiva", "Linia ofensywna", "Линия нападения", "Linja sulmuese", "进攻线", "Offensive line"),
    "fan_team_position_dl": tr("Defensive Line", "Línea defensiva", "Ligne défensive", "Linha defensiva", "Defensive Line", "Linea difensiva", "Linia defensywna", "Линия защиты", "Linja mbrojtëse", "防守线", "Defensive line"),
    "fan_team_position_lb_fb": tr("Linebacker", "Linebacker", "Linebacker", "Linebacker", "Linebacker", "Linebacker", "Linebacker", "Лайнбекер", "Linebacker", "线卫", "Linebacker"),
    "fan_team_position_cb_fb": tr("Cornerback", "Cornerback", "Cornerback", "Cornerback", "Cornerback", "Cornerback", "Cornerback", "Корнербек", "Cornerback", "角卫", "Cornerback"),
    "fan_team_position_s_fb": tr("Safety", "Safety", "Safety", "Safety", "Safety", "Safety", "Safety", "Сэйфти", "Safety", "安全卫", "Safety"),
    "fan_team_position_k": tr("Kicker", "Kicker", "Kicker", "Kicker", "Kicker", "Kicker", "Kicker", "Кикер", "Kicker", "踢球手", "Kicker"),
    "fan_team_position_p_fb": tr("Punter", "Punter", "Punter", "Punter", "Punter", "Punter", "Punter", "Пантер", "Punter", "弃踢手", "Punter"),
    # Hockey
    "fan_team_position_g": tr("Goaltender", "Portero", "Gardien", "Goleiro", "Torhüter", "Portiere", "Bramkarz", "Вратарь", "Portier", "守门员", "Keeper"),
    "fan_team_position_ld": tr("Left Defense", "Defensa izquierdo", "Défenseur gauche", "Defensor esquerdo", "Linker Verteidiger", "Difensore sinistro", "Lewy obrońca", "Левый защитник", "Mbrojtës i majtë", "左后卫", "Linker verdediger"),
    "fan_team_position_rd": tr("Right Defense", "Defensa derecho", "Défenseur droit", "Defensor direito", "Rechter Verteidiger", "Difensore destro", "Prawy obrońca", "Правый защитник", "Mbrojtës i djathtë", "右后卫", "Rechter verdediger"),
    "fan_team_position_c_hockey": tr("Center", "Centro", "Centre", "Centro", "Center", "Centro", "Środkowy", "Центральный", "Qendër", "中锋", "Center"),
    "fan_team_position_lw_hockey": tr("Left Wing", "Ala izquierda", "Ailier gauche", "Ponta esquerda", "Linksaußen", "Ala sinistra", "Lewy skrzydłowy", "Левый край", "Krah i majtë", "左边锋", "Linkervleugel"),
    "fan_team_position_rw_hockey": tr("Right Wing", "Ala derecha", "Ailier droit", "Ponta direita", "Rechtsaußen", "Ala destra", "Prawy skrzydłowy", "Правый край", "Krah i djathtë", "右边锋", "Rechtervleugel"),
    # Volleyball
    "fan_team_position_s_vb": tr("Setter", "Colocador", "Passeur", "Levantador", "Zuspieler", "Palleggiatore", "Rozgrywający", "Связующий", "Vendosës", "二传", "Spelverdeler"),
    "fan_team_position_oh": tr("Outside Hitter", "Punta", "Réceptionneur-attaquant", "Ponteiro", "Außenangreifer", "Schiacciatore", "Przyjmujący", "Доигровщик", "Goditës i jashtëm", "主攻", "Buitenaanvaller"),
    "fan_team_position_opp": tr("Opposite", "Opuesto", "Pointu", "Oposto", "Diagonalangreifer", "Opposto", "Atakujący", "Диагональный", "I kundërt", "接应", "Diagonaal"),
    "fan_team_position_mb": tr("Middle Blocker", "Central", "Central", "Central", "Mittelblocker", "Centrale", "Środkowy", "Центральный блокирующий", "Bllokues i mesit", "副攻", "Middenblocker"),
    "fan_team_position_l_vb": tr("Libero", "Líbero", "Libéro", "Líbero", "Libero", "Libero", "Libero", "Либеро", "Libero", "自由人", "Libero"),
    "fan_team_position_ds": tr("Defensive Specialist", "Especialista defensivo", "Spécialiste défensif", "Especialista defensivo", "Abwehrspezialist", "Specialista difensivo", "Specjalista obrony", "Защитный специалист", "Specialist mbrojtjeje", "防守专员", "Verdedigingsspecialist"),
}


def main() -> None:
    data = json.loads(XCSTRINGS.read_text(encoding="utf-8"))
    strings = data.setdefault("strings", {})
    inserted = 0
    for key, translations in ENTRIES.items():
        entry = strings.get(key, {"extractionState": "manual", "localizations": {}})
        entry["extractionState"] = "manual"
        locs = entry.setdefault("localizations", {})
        existed = bool((locs.get("en") or {}).get("stringUnit", {}).get("value"))
        for lang in SUPPORTED:
            value = translations.get(lang)
            if not value:
                continue
            if (locs.get(lang) or {}).get("stringUnit", {}).get("value"):
                continue
            locs[lang] = unit(value)
        strings[key] = entry
        if not existed:
            inserted += 1
    XCSTRINGS.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"upserted {len(ENTRIES)} position/lineup keys ({inserted} new)")


if __name__ == "__main__":
    main()
