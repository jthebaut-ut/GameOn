#!/usr/bin/env python3
"""Restore localization keys lost when Localizable.xcstrings was truncated.

Upserts missing keys into the canonical catalog. Does not overwrite existing
non-empty translations. Does not introduce a second L10n helper.
"""
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
        "en": en,
        "es": es,
        "fr": fr,
        "pt": pt,
        "de": de,
        "it": it,
        "pl": pl,
        "ru": ru,
        "sq": sq,
        "zh-Hans": zh,
        "nl": nl,
    }


# Keys that exist in 10 languages but were never given Dutch after catalog restore.
NL_FILL: dict[str, str] = {
    "going_play_filter": "Filter",
    "going_play_upcoming": "Aankomend",
    "going_play_badge_pickup": "PICKUP",
    "going_play_badge_team": "TEAM",
    "going_play_filter_all": "Alles",
    "going_play_filter_hosting": "Organiseren",
    "going_play_filter_invites": "Uitnodigingen",
    "going_play_filter_pickups": "Pickups",
    "going_play_filter_team_events": "Teamevents",
    "profile_my_teams_subtitle": "Teams waarvan ik deel uitmaak",
    "profile_my_teams_view_all": "Alles bekijken",
    "profile_favorite_teams_subtitle": "Professionele clubs die je volgt.",
    "pickup_rating_pending_status": "Beoordeling in behandeling",
    "action_center_cta_view_event": "Event bekijken",
}


ENTRIES: dict[str, dict[str, str]] = {}

# --- Visible screenshot failures + Profile / Teams / Inbox ---
ENTRIES.update({
    "fan_teams_filter_all": tr(
        "All", "Todos", "Tous", "Todos", "Alle", "Tutti", "Wszystkie", "Все", "Të gjitha", "全部", "Alles",
    ),
    "fan_teams_filter_managing": tr(
        "Managing", "Gestionando", "Gestion", "Gerenciando", "Verwalten", "Gestione", "Zarządzanie", "Управление", "Menaxhim", "管理中", "Beheer",
    ),
    "fan_teams_filter_joined": tr(
        "Joined", "Unido", "Rejoint", "Entrou", "Beigetreten", "Iscritto", "Dołączono", "Участник", "Anëtar", "已加入", "Lid",
    ),
    "fan_teams_relationship_via": tr(
        "Via %@", "Vía %@", "Via %@", "Via %@", "Über %@", "Tramite %@", "Przez %@", "Через %@", "Nëpërmjet %@", "通过 %@", "Via %@",
    ),
    "fan_teams_relationship_a11y_role": tr(
        "Role: %@", "Rol: %@", "Rôle : %@", "Função: %@", "Rolle: %@", "Ruolo: %@", "Rola: %@", "Роль: %@", "Roli: %@", "角色：%@", "Rol: %@",
    ),
    "fan_teams_relationship_a11y_via": tr(
        "Via %@", "Vía %@", "Via %@", "Via %@", "Über %@", "Tramite %@", "Przez %@", "Через %@", "Nëpërmjet %@", "通过 %@", "Via %@",
    ),
    "profile_my_teams_title": tr(
        "My Teams", "Mis equipos", "Mes équipes", "Minhas equipes", "Meine Teams", "Le mie squadre", "Moje drużyny", "Мои команды", "Ekipet e mia", "我的队伍", "Mijn teams",
    ),
    "profile_my_teams_empty": tr(
        "Join or create a Team to see it here.",
        "Únete o crea un equipo para verlo aquí.",
        "Rejoignez ou créez une équipe pour la voir ici.",
        "Entre ou crie uma equipe para vê-la aqui.",
        "Tritt einem Team bei oder erstelle eines, um es hier zu sehen.",
        "Unisciti o crea una squadra per vederla qui.",
        "Dołącz lub utwórz drużynę, aby zobaczyć ją tutaj.",
        "Вступите в команду или создайте её, чтобы увидеть здесь.",
        "Bashkohuni ose krijoni një ekip për ta parë këtu.",
        "加入或创建队伍后会显示在这里。",
        "Word lid of maak een team om het hier te zien.",
    ),
    "profile_my_teams_opens_team_a11y": tr(
        "Opens Team", "Abre el equipo", "Ouvre l’équipe", "Abre a equipe", "Öffnet das Team", "Apre la squadra", "Otwiera drużynę", "Открывает команду", "Hap ekipin", "打开队伍", "Opent team",
    ),
    "profile_my_teams_show_on_profile": tr(
        "Show My Teams on Profile",
        "Mostrar Mis equipos en el perfil",
        "Afficher Mes équipes sur le profil",
        "Mostrar Minhas equipes no perfil",
        "Meine Teams im Profil zeigen",
        "Mostra Le mie squadre nel profilo",
        "Pokaż Moje drużyny w profilu",
        "Показывать «Мои команды» в профиле",
        "Shfaq Ekipet e mia në profil",
        "在个人资料中显示我的队伍",
        "Toon Mijn teams op profiel",
    ),
    "profile_my_teams_visibility": tr(
        "Who can see My Teams",
        "Quién puede ver Mis equipos",
        "Qui peut voir Mes équipes",
        "Quem pode ver Minhas equipes",
        "Wer Meine Teams sehen kann",
        "Chi può vedere Le mie squadre",
        "Kto widzi Moje drużyny",
        "Кто видит «Мои команды»",
        "Kush mund t’i shohë Ekipet e mia",
        "谁可以看到我的队伍",
        "Wie Mijn teams kan zien",
    ),
    "profile_my_teams_visibility_everyone": tr(
        "Everyone", "Todos", "Tout le monde", "Todos", "Alle", "Tutti", "Wszyscy", "Все", "Të gjithë", "所有人", "Iedereen",
    ),
    "profile_my_teams_visibility_friends": tr(
        "Friends", "Amigos", "Amis", "Amigos", "Freunde", "Amici", "Znajomi", "Друзья", "Miqtë", "好友", "Vrienden",
    ),
    "profile_my_teams_visibility_team_members": tr(
        "Team members", "Miembros del equipo", "Membres de l’équipe", "Membros da equipe", "Teammitglieder", "Membri della squadra", "Członkowie drużyny", "Участники команды", "Anëtarët e ekipit", "队伍成员", "Teamlid",
    ),
    "profile_my_teams_visibility_only_me": tr(
        "Only me", "Solo yo", "Moi uniquement", "Somente eu", "Nur ich", "Solo io", "Tylko ja", "Только я", "Vetëm unë", "仅自己", "Alleen ik",
    ),
    "profile_my_teams_visible_to_format": tr(
        "Visible to: %@", "Visible para: %@", "Visible par : %@", "Visível para: %@", "Sichtbar für: %@", "Visibile a: %@", "Widoczne dla: %@", "Видно: %@", "E dukshme për: %@", "可见对象：%@", "Zichtbaar voor: %@",
    ),
    "action_center_cta_review": tr(
        "Review", "Revisar", "Examiner", "Revisar", "Prüfen", "Esamina", "Sprawdź", "Проверить", "Shqyrto", "查看", "Bekijken",
    ),
    "action_center_empty_body": tr(
        "You're all caught up.",
        "Estás al día.",
        "Vous êtes à jour.",
        "Você está em dia.",
        "Du bist auf dem neuesten Stand.",
        "Sei in pari.",
        "Wszystko na bieżąco.",
        "Все актуально.",
        "Je i përditësuar.",
        "全部处理完毕。",
        "Je bent helemaal bij.",
    ),
    "action_center_schedule_badge_a11y": tr(
        "%lld Schedule updates",
        "%lld actualizaciones de Agenda",
        "%lld mises à jour Agenda",
        "%lld atualizações da Agenda",
        "%lld Plan-Updates",
        "%lld aggiornamenti Calendario",
        "%lld aktualizacje Harmonogramu",
        "%lld обновлений расписания",
        "%lld përditësime të Orarit",
        "%lld 个日程更新",
        "%lld Agenda-updates",
    ),
    "action_center_teams_badge_a11y": tr(
        "Team invitations",
        "Invitaciones de equipo",
        "Invitations d’équipe",
        "Convites de equipe",
        "Team-Einladungen",
        "Inviti di squadra",
        "Zaproszenia do drużyny",
        "Приглашения в команду",
        "Ftesa ekipi",
        "队伍邀请",
        "Teamuitnodigingen",
    ),
    "chat_reply": tr(
        "Reply", "Responder", "Répondre", "Responder", "Antworten", "Rispondi", "Odpowiedz", "Ответить", "Përgjigju", "回复", "Beantwoorden",
    ),
    "chat_reply_cancel_a11y": tr(
        "Cancel reply", "Cancelar respuesta", "Annuler la réponse", "Cancelar resposta", "Antwort abbrechen", "Annulla risposta", "Anuluj odpowiedź", "Отменить ответ", "Anulo përgjigjen", "取消回复", "Antwoord annuleren",
    ),
    "chat_reply_original_not_found": tr(
        "Original message not found",
        "No se encontró el mensaje original",
        "Message d’origine introuvable",
        "Mensagem original não encontrada",
        "Originalnachricht nicht gefunden",
        "Messaggio originale non trovato",
        "Nie znaleziono oryginalnej wiadomości",
        "Исходное сообщение не найдено",
        "Mesazhi origjinal nuk u gjet",
        "找不到原始消息",
        "Oorspronkelijk bericht niet gevonden",
    ),
    "chat_reply_original_unavailable": tr(
        "Original message unavailable",
        "Mensaje original no disponible",
        "Message d’origine indisponible",
        "Mensagem original indisponível",
        "Originalnachricht nicht verfügbar",
        "Messaggio originale non disponibile",
        "Oryginalna wiadomość niedostępna",
        "Исходное сообщение недоступно",
        "Mesazhi origjinal i padisponueshëm",
        "原始消息不可用",
        "Oorspronkelijk bericht niet beschikbaar",
    ),
    "chat_reply_replying_to_format": tr(
        "Replying to %@", "Respondiendo a %@", "Réponse à %@", "Respondendo a %@", "Antwort an %@", "Risposta a %@", "Odpowiedź do %@", "Ответ для %@", "Përgjigje për %@", "回复 %@", "Antwoord aan %@",
    ),
    "chat_reply_view_original_a11y_hint": tr(
        "Shows the original message",
        "Muestra el mensaje original",
        "Affiche le message d’origine",
        "Mostra a mensagem original",
        "Zeigt die Originalnachricht",
        "Mostra il messaggio originale",
        "Pokazuje oryginalną wiadomość",
        "Показывает исходное сообщение",
        "Shfaq mesazhin origjinal",
        "显示原始消息",
        "Toont het oorspronkelijke bericht",
    ),
})

ENTRIES.update({
    "fan_team_lineup_title": tr("Lineup", "Alineación", "Composition", "Escalação", "Aufstellung", "Formazione", "Skład", "Состав", "Formacioni", "阵容", "Opstelling"),
    "fan_team_lineup_create": tr("Create Lineup", "Crear alineación", "Créer la composition", "Criar escalação", "Aufstellung erstellen", "Crea formazione", "Utwórz skład", "Создать состав", "Krijo formacionin", "创建阵容", "Opstelling maken"),
    "fan_team_lineup_edit": tr("Edit Lineup", "Editar alineación", "Modifier la composition", "Editar escalação", "Aufstellung bearbeiten", "Modifica formazione", "Edytuj skład", "Изменить состав", "Ndrysho formacionin", "编辑阵容", "Opstelling bewerken"),
    "fan_team_lineup_view": tr("View", "Ver", "Voir", "Ver", "Ansehen", "Vedi", "Zobacz", "Смотреть", "Shiko", "查看", "Bekijken"),
    "fan_team_lineup_starting": tr("Starting", "Titulares", "Titulaires", "Titulares", "Startelf", "Titolari", "Skład podstawowy", "Старт", "Startuesit", "首发", "Basis"),
    "fan_team_lineup_bench": tr("Bench", "Banquillo", "Banc", "Banco", "Bank", "Panchina", "Ławka", "Запас", "Stola", "替补", "Bank"),
    "fan_team_lineup_publish": tr("Publish", "Publicar", "Publier", "Publicar", "Veröffentlichen", "Pubblica", "Opublikuj", "Опубликовать", "Publiko", "发布", "Publiceren"),
    "fan_team_lineup_save_draft": tr("Save Draft", "Guardar borrador", "Enregistrer le brouillon", "Salvar rascunho", "Entwurf speichern", "Salva bozza", "Zapisz szkic", "Сохранить черновик", "Ruaj skicën", "保存草稿", "Concept opslaan"),
    "fan_team_lineup_status_draft": tr("Draft", "Borrador", "Brouillon", "Rascunho", "Entwurf", "Bozza", "Szkic", "Черновик", "Skicë", "草稿", "Concept"),
    "fan_team_lineup_status_published": tr("Published", "Publicado", "Publié", "Publicado", "Veröffentlicht", "Pubblicata", "Opublikowano", "Опубликовано", "Publikuar", "已发布", "Gepubliceerd"),
    "fan_team_lineup_published_short": tr("Published", "Publicado", "Publié", "Publicado", "Veröffentlicht", "Pubblicata", "Opublikowano", "Опубликовано", "Publikuar", "已发布", "Gepubliceerd"),
    "fan_team_lineup_published_by_team": tr(
        "Published by the Team", "Publicado por el equipo", "Publié par l’équipe", "Publicado pela equipe",
        "Vom Team veröffentlicht", "Pubblicata dalla squadra", "Opublikowane przez drużynę",
        "Опубликовано командой", "Publikuar nga ekipi", "由队伍发布", "Gepubliceerd door het team",
    ),
    "fan_team_lineup_your_position": tr("Your position", "Tu posición", "Votre poste", "Sua posição", "Deine Position", "La tua posizione", "Twoja pozycja", "Ваша позиция", "Pozicioni yt", "你的位置", "Jouw positie"),
    "fan_team_lineup_substitute": tr("Substitute", "Suplente", "Remplaçant", "Reserva", "Ersatz", "Riserva", "Rezerwowy", "Запасной", "Zëvendësues", "替补", "Wissel"),
    "fan_team_lineup_sub_badge": tr("SUB", "SUP", "REM", "RES", "ERS", "RIS", "REZ", "ЗАП", "ZËV", "替", "WIS"),
    "fan_team_lineup_unassigned_badge": tr("OPEN", "LIBRE", "LIBRE", "LIVRE", "OFFEN", "LIBERO", "WOLNE", "СВОБ", "HAPUR", "未定", "OPEN"),
    "fan_team_lineup_player_count_format": tr("%lld players", "%lld jugadores", "%lld joueurs", "%lld jogadores", "%lld Spieler", "%lld giocatori", "%lld zawodników", "%lld игроков", "%lld lojtarë", "%lld 名球员", "%lld spelers"),
    "fan_team_lineup_positions_manager_note": tr(
        "Positions are set by the Team.",
        "Las posiciones las asigna el equipo.",
        "Les postes sont définis par l’équipe.",
        "As posições são definidas pela equipe.",
        "Positionen werden vom Team festgelegt.",
        "Le posizioni sono assegnate dalla squadra.",
        "Pozycje ustala drużyna.",
        "Позиции назначает команда.",
        "Pozicionet i cakton ekipi.",
        "位置由队伍设定。",
        "Posities worden door het team ingesteld.",
    ),
    "fan_team_lineup_counts_format": tr(
        "%lld starting · %lld bench", "%lld titulares · %lld banquillo", "%lld titulaires · %lld banc",
        "%lld titulares · %lld banco", "%lld Startelf · %lld Bank", "%lld titolari · %lld panchina",
        "%lld w składzie · %lld na ławce", "%lld в старте · %lld в запасе", "%lld startues · %lld stolë",
        "%lld 首发 · %lld 替补", "%lld basis · %lld bank",
    ),
    "fan_team_lineup_more_format": tr("+%lld more", "+%lld más", "+%lld de plus", "+%lld mais", "+%lld weitere", "+%lld altri", "+%lld więcej", "+ещё %lld", "+%lld të tjerë", "+还有 %lld 人", "+%lld meer"),
    "fan_team_lineup_section_count_format": tr("%@ · %lld", "%@ · %lld", "%@ · %lld", "%@ · %lld", "%@ · %lld", "%@ · %lld", "%@ · %lld", "%@ · %lld", "%@ · %lld", "%@ · %lld", "%@ · %lld"),
    "fan_team_lineup_section_a11y_format": tr("%@, %lld players", "%@, %lld jugadores", "%@, %lld joueurs", "%@, %lld jogadores", "%@, %lld Spieler", "%@, %lld giocatori", "%@, %lld zawodników", "%@, %lld игроков", "%@, %lld lojtarë", "%@，%lld 名球员", "%@, %lld spelers"),
    "fan_team_lineup_formation": tr("Formation", "Formación", "Dispositif", "Formação", "Formation", "Modulo", "Ustawienie", "Схема", "Formacioni", "阵型", "Formatie"),
    "fan_team_lineup_no_position": tr("No position", "Sin posición", "Aucun poste", "Sem posição", "Keine Position", "Nessuna posizione", "Brak pozycji", "Без позиции", "Pa pozicion", "无位置", "Geen positie"),
    "fan_team_lineup_no_longer_attending": tr(
        "No longer attending", "Ya no asiste", "Ne participe plus", "Não participa mais",
        "Nimmt nicht mehr teil", "Non partecipa più", "Już nie uczestniczy",
        "Больше не участвует", "Nuk merr pjesë më", "不再参加", "Doet niet meer mee",
    ),
    "fan_team_lineup_no_longer_attending_count_format": tr(
        "%lld no longer attending", "%lld ya no asisten", "%lld ne participent plus", "%lld não participam mais",
        "%lld nehmen nicht mehr teil", "%lld non partecipano più", "%lld już nie uczestniczy",
        "%lld больше не участвуют", "%lld nuk marrin pjesë më", "%lld 人不再参加", "%lld doen niet meer mee",
    ),
    "fan_team_lineup_not_published_yet": tr(
        "Lineup not published yet", "Alineación aún no publicada", "Composition pas encore publiée",
        "Escalação ainda não publicada", "Aufstellung noch nicht veröffentlicht", "Formazione non ancora pubblicata",
        "Skład jeszcze nieopublikowany", "Состав ещё не опубликован", "Formacioni nuk është publikuar ende",
        "阵容尚未发布", "Opstelling nog niet gepubliceerd",
    ),
    "fan_team_lineup_no_roster_members": tr(
        "No roster members yet", "Aún no hay jugadores en la plantilla", "Pas encore de joueurs dans l’effectif",
        "Ainda não há jogadores no elenco", "Noch keine Kaderspieler", "Nessun giocatore in rosa",
        "Brak zawodników w kadrze", "В заявке пока нет игроков", "Ende nuk ka lojtarë në listë",
        "名单中还没有球员", "Nog geen selectiespelers",
    ),
    "fan_team_lineup_edit_forbidden": tr(
        "You don’t have permission to edit this lineup.",
        "No tienes permiso para editar esta alineación.",
        "Vous n’avez pas l’autorisation de modifier cette composition.",
        "Você não tem permissão para editar esta escalação.",
        "Du darfst diese Aufstellung nicht bearbeiten.",
        "Non hai il permesso di modificare questa formazione.",
        "Nie masz uprawnień do edycji tego składu.",
        "У вас нет права редактировать этот состав.",
        "Nuk keni leje ta ndryshoni këtë formacion.",
        "你没有权限编辑此阵容。",
        "Je mag deze opstelling niet bewerken.",
    ),
    "fan_team_lineup_manager_help": tr(
        "Move players between Starting and Bench, then publish when ready.",
        "Mueve jugadores entre Titulares y Banquillo y publica cuando esté listo.",
        "Déplacez les joueurs entre Titulaires et Banc, puis publiez.",
        "Mova jogadores entre Titulares e Banco e publique quando estiver pronto.",
        "Verschiebe Spieler zwischen Startelf und Bank und veröffentliche sie.",
        "Sposta i giocatori tra Titolari e Panchina, poi pubblica.",
        "Przenoś zawodników między składem a ławką, a następnie opublikuj.",
        "Перемещайте игроков между стартом и запасом, затем опубликуйте.",
        "Zhvendosni lojtarët mes Startuesve dhe Stolës, pastaj publikoni.",
        "在首发和替补之间调整球员，准备好后发布。",
        "Verplaats spelers tussen Basis en Bank en publiceer daarna.",
    ),
    "fan_team_lineup_roster_section": tr("Roster", "Plantilla", "Effectif", "Elenco", "Kader", "Rosa", "Kadra", "Заявка", "Lista", "名单", "Selectie"),
    "fan_team_lineup_playing_today": tr("Playing today", "Juega hoy", "Joue aujourd’hui", "Joga hoje", "Spielt heute", "Gioca oggi", "Gra dzisiaj", "Играет сегодня", "Luan sot", "今日参赛", "Speelt vandaag"),
    "fan_team_lineup_player": tr("Player", "Jugador", "Joueur", "Jogador", "Spieler", "Giocatore", "Zawodnik", "Игрок", "Lojtar", "球员", "Speler"),
    "fan_team_lineup_set_position": tr("Set Position", "Asignar posición", "Définir le poste", "Definir posição", "Position festlegen", "Imposta posizione", "Ustaw pozycję", "Назначить позицию", "Cakto pozicionin", "设置位置", "Positie instellen"),
    "fan_team_lineup_reset_to_team_default": tr(
        "Reset to Team default", "Restablecer valor del equipo", "Réinitialiser le poste d’équipe",
        "Redefinir para o padrão da equipe", "Teamstandard wiederherstellen", "Ripristina predefinito squadra",
        "Przywróć domyślną drużyny", "Сбросить на командную по умолчанию", "Rikthe te parazgjedhja e ekipit",
        "重置为队伍默认", "Terugzetten naar teamstandaard",
    ),
    "fan_team_lineup_team_default": tr("Team default", "Predeterminado del equipo", "Défaut de l’équipe", "Padrão da equipe", "Teamstandard", "Predefinito squadra", "Domyślna drużyny", "По умолчанию команды", "Parazgjedhja e ekipit", "队伍默认", "Teamstandaard"),
    "fan_team_lineup_team_default_format": tr(
        "Team default: %@", "Predeterminado del equipo: %@", "Défaut de l’équipe : %@", "Padrão da equipe: %@",
        "Teamstandard: %@", "Predefinito squadra: %@", "Domyślna drużyny: %@", "По умолчанию команды: %@",
        "Parazgjedhja e ekipit: %@", "队伍默认：%@", "Teamstandaard: %@",
    ),
    "fan_team_lineup_position_control_set_a11y": tr(
        "Set position", "Asignar posición", "Définir le poste", "Definir posição", "Position festlegen",
        "Imposta posizione", "Ustaw pozycję", "Назначить позицию", "Cakto pozicionin", "设置位置", "Positie instellen",
    ),
    "fan_team_lineup_position_control_change_a11y_format": tr(
        "Change position, currently %@", "Cambiar posición, actualmente %@", "Modifier le poste, actuellement %@",
        "Alterar posição, atualmente %@", "Position ändern, aktuell %@", "Cambia posizione, attualmente %@",
        "Zmień pozycję, obecnie %@", "Изменить позицию, сейчас %@", "Ndrysho pozicionin, aktualisht %@",
        "更改位置，当前 %@", "Positie wijzigen, nu %@",
    ),
    "fan_team_lineup_edit_player_a11y": tr(
        "Edit player", "Editar jugador", "Modifier le joueur", "Editar jogador", "Spieler bearbeiten",
        "Modifica giocatore", "Edytuj zawodnika", "Изменить игрока", "Ndrysho lojtarin", "编辑球员", "Speler bewerken",
    ),
    "fan_team_role_head_coach": tr("Head Coach", "Entrenador principal", "Entraîneur principal", "Treinador principal", "Cheftrainer", "Allenatore", "Trener główny", "Главный тренер", "Trajneri kryesor", "主教练", "Hoofdtrainer"),
    "fan_team_role_assistant_coach": tr("Assistant Coach", "Entrenador asistente", "Entraîneur adjoint", "Treinador assistente", "Co-Trainer", "Vice-allenatore", "Asystent trenera", "Помощник тренера", "Ndihmës trajner", "助理教练", "Assistent-trainer"),
    "fan_team_role_assistant_captain": tr("Assistant Captain", "Capitán asistente", "Capitaine adjoint", "Capitão assistente", "Vizekapitän", "Vice-capitano", "Zastępca kapitana", "Ассистент капитана", "Ndihmës kapiten", "副队长", "Vice-aanvoerder"),
})

ENTRIES.update({
    "fan_team_member_left_push_title_format": tr("%@ left %@", "%@ salió de %@", "%@ a quitté %@", "%@ saiu de %@", "%@ hat %@ verlassen", "%@ ha lasciato %@", "%@ opuścił(a) %@", "%@ покинул(а) %@", "%@ u largua nga %@", "%@ 已离开 %@", "%@ heeft %@ verlaten"),
    "fan_team_member_left_push_body_format": tr("%@ is no longer on %@", "%@ ya no está en %@", "%@ ne fait plus partie de %@", "%@ não faz mais parte de %@", "%@ ist nicht mehr bei %@", "%@ non è più in %@", "%@ nie jest już w %@", "%@ больше не в %@", "%@ nuk është më në %@", "%@ 已不在 %@", "%@ zit niet meer bij %@"),
    "fan_team_rsvp_update_failed_message": tr("Couldn’t update RSVP. Try again.", "No se pudo actualizar la asistencia. Inténtalo de nuevo.", "Impossible de mettre à jour la réponse. Réessayez.", "Não foi possível atualizar a confirmação. Tente de novo.", "RSVP konnte nicht aktualisiert werden. Bitte erneut versuchen.", "Impossibile aggiornare l’RSVP. Riprova.", "Nie udało się zaktualizować RSVP. Spróbuj ponownie.", "Не удалось обновить ответ. Попробуйте ещё раз.", "Nuk u përditësua RSVP. Provo sërish.", "无法更新回复，请重试。", "RSVP bijwerken mislukt. Probeer opnieuw."),
    "fan_team_schedule_event_cancelled": tr("Cancelled", "Cancelado", "Annulé", "Cancelado", "Abgesagt", "Annullato", "Odwołane", "Отменено", "Anuluar", "已取消", "Geannuleerd"),
    "fan_team_schedule_rsvp_change": tr("Change RSVP", "Cambiar asistencia", "Modifier la réponse", "Alterar confirmação", "RSVP ändern", "Cambia RSVP", "Zmień RSVP", "Изменить ответ", "Ndrysho RSVP", "更改回复", "RSVP wijzigen"),
    "fan_team_schedule_rsvp_change_a11y_format": tr("Change RSVP for %@", "Cambiar asistencia de %@", "Modifier la réponse de %@", "Alterar confirmação de %@", "RSVP für %@ ändern", "Cambia RSVP di %@", "Zmień RSVP dla %@", "Изменить ответ для %@", "Ndrysho RSVP për %@", "更改 %@ 的回复", "RSVP van %@ wijzigen"),
    "fan_team_schedule_rsvp_mark_cant_go_a11y_format": tr("Mark %@ as Can’t Go", "Marcar a %@ como No puede ir", "Marquer %@ comme Ne peut pas venir", "Marcar %@ como Não vai", "%@ als Absage markieren", "Segna %@ come Non può", "Oznacz %@ jako Nie idzie", "Отметить %@ как не идёт", "Shëno %@ si Nuk shkon", "将 %@ 标为不去", "%@ markeren als Kan niet"),
    "fan_team_schedule_rsvp_mark_going_a11y_format": tr("Mark %@ as Going", "Marcar a %@ como Asiste", "Marquer %@ comme Présent", "Marcar %@ como Vai", "%@ als Going markieren", "Segna %@ come Partecipa", "Oznacz %@ jako Idzie", "Отметить %@ как идёт", "Shëno %@ si Shkon", "将 %@ 标为参加", "%@ markeren als Gaat"),
    "fan_team_schedule_rsvp_not_participating": tr("Not participating", "No participa", "Ne participe pas", "Não participa", "Nimmt nicht teil", "Non partecipa", "Nie uczestniczy", "Не участвует", "Nuk merr pjesë", "不参加", "Doet niet mee"),
    "fan_team_schedule_rsvp_player_fallback": tr("Player", "Jugador", "Joueur", "Jogador", "Spieler", "Giocatore", "Zawodnik", "Игрок", "Lojtar", "球员", "Speler"),
    "fan_team_schedule_rsvp_save_failed": tr("Couldn’t save RSVP.", "No se pudo guardar la asistencia.", "Impossible d’enregistrer la réponse.", "Não foi possível salvar a confirmação.", "RSVP konnte nicht gespeichert werden.", "Impossibile salvare l’RSVP.", "Nie udało się zapisać RSVP.", "Не удалось сохранить ответ.", "Nuk u ruajt RSVP.", "无法保存回复。", "RSVP opslaan mislukt."),
    "fan_team_schedule_rsvp_will_be_there_format": tr("Will %@ be there?", "¿Estará %@?", "%@ sera-t-il/elle là ?", "%@ vai estar?", "Ist %@ dabei?", "%@ ci sarà?", "Czy %@ będzie?", "%@ будет?", "A do të jetë %@?", "%@ 会到场吗？", "Is %@ erbij?"),
    "fan_team_schedule_vs": tr("vs", "vs", "vs", "vs", "vs", "vs", "vs", "vs", "vs", "vs", "vs"),
    "fan_teams_add_back_to_event": tr("Add back to event", "Volver a añadir al evento", "Remettre dans l’événement", "Adicionar de volta ao evento", "Wieder zum Event hinzufügen", "Riaggiungi all’evento", "Dodaj z powrotem do wydarzenia", "Вернуть в событие", "Shto sërish në event", "重新加入活动", "Weer toevoegen aan event"),
    "fan_teams_avatar_stack_and_more_format": tr("and %lld more", "y %lld más", "et %lld de plus", "e %lld mais", "und %lld weitere", "e altri %lld", "i %lld więcej", "и ещё %lld", "dhe %lld të tjerë", "以及另外 %lld 人", "en %lld meer"),
    "fan_teams_choose_role_help": tr("Choose this person’s role on the Team.", "Elige el rol de esta persona en el equipo.", "Choisissez le rôle de cette personne dans l’équipe.", "Escolha a função desta pessoa na equipe.", "Wähle die Rolle dieser Person im Team.", "Scegli il ruolo di questa persona nella squadra.", "Wybierz rolę tej osoby w drużynie.", "Выберите роль этого человека в команде.", "Zgjidhni rolin e kësaj persone në ekip.", "选择此人在队伍中的角色。", "Kies de rol van deze persoon in het team."),
    "fan_teams_events_no_upcoming_title": tr("No upcoming events", "No hay eventos próximos", "Aucun événement à venir", "Nenhum evento próximo", "Keine kommenden Events", "Nessun evento in arrivo", "Brak nadchodzących wydarzeń", "Нет ближайших событий", "Nuk ka evente të ardhshme", "暂无即将开始的活动", "Geen aankomende events"),
    "fan_teams_events_no_upcoming_body": tr("Scheduled Team events will show up here.", "Los eventos de equipo programados aparecerán aquí.", "Les événements d’équipe planifiés apparaîtront ici.", "Eventos de equipe agendados aparecerão aqui.", "Geplante Team-Events erscheinen hier.", "Gli eventi di squadra programmati appariranno qui.", "Zaplanowane wydarzenia drużyny pojawią się tutaj.", "Запланированные события команды появятся здесь.", "Eventet e planifikuara të ekipit do të shfaqen këtu.", "已安排的队伍活动会显示在这里。", "Geplande teamevents verschijnen hier."),
    "fan_teams_events_no_past_title": tr("No past events", "No hay eventos anteriores", "Aucun événement passé", "Nenhum evento anterior", "Keine vergangenen Events", "Nessun evento passato", "Brak przeszłych wydarzeń", "Нет прошедших событий", "Nuk ka evente të kaluara", "暂无过往活动", "Geen eerdere events"),
    "fan_teams_events_no_past_body": tr("Completed Team events will show up here.", "Los eventos de equipo completados aparecerán aquí.", "Les événements d’équipe terminés apparaîtront ici.", "Eventos de equipe concluídos aparecerão aqui.", "Abgeschlossene Team-Events erscheinen hier.", "Gli eventi di squadra conclusi appariranno qui.", "Zakończone wydarzenia drużyny pojawią się tutaj.", "Завершённые события команды появятся здесь.", "Eventet e përfunduara të ekipit do të shfaqen këtu.", "已结束的队伍活动会显示在这里。", "Afgeronde teamevents verschijnen hier."),
    "fan_teams_excluded_from_event_section": tr("Not in this event", "Fuera de este evento", "Hors de cet événement", "Fora deste evento", "Nicht in diesem Event", "Fuori da questo evento", "Poza tym wydarzeniem", "Не в этом событии", "Jo në këtë event", "不在此活动中", "Niet in dit event"),
    "fan_teams_excluded_from_event_status": tr("Removed from event", "Quitado del evento", "Retiré de l’événement", "Removido do evento", "Vom Event entfernt", "Rimosso dall’evento", "Usunięto z wydarzenia", "Удалён из события", "Hequr nga eventi", "已从此活动移除", "Verwijderd uit event"),
    "fan_teams_header_create_event": tr("Create Event", "Crear evento", "Créer un événement", "Criar evento", "Event erstellen", "Crea evento", "Utwórz wydarzenie", "Создать событие", "Krijo event", "创建活动", "Event maken"),
    "fan_teams_jersey_number": tr("Number", "Número", "Numéro", "Número", "Nummer", "Numero", "Numer", "Номер", "Numri", "号码", "Nummer"),
    "fan_teams_make_announcement_a11y_hint": tr("Opens Make Announcement", "Abre Hacer anuncio", "Ouvre Faire une annonce", "Abre Fazer anúncio", "Öffnet Ankündigung erstellen", "Apre Fai un annuncio", "Otwiera Utwórz ogłoszenie", "Открывает «Сделать объявление»", "Hap Bëj njoftim", "打开发布公告", "Opent Aankondiging maken"),
    "fan_teams_make_announcement_nav_title": tr("Make Announcement", "Hacer anuncio", "Faire une annonce", "Fazer anúncio", "Ankündigung erstellen", "Fai un annuncio", "Utwórz ogłoszenie", "Сделать объявление", "Bëj njoftim", "发布公告", "Aankondiging maken"),
    "fan_teams_member_since": tr("Member since", "Miembro desde", "Membre depuis", "Membro desde", "Mitglied seit", "Membro da", "Członek od", "В команде с", "Anëtar që nga", "加入时间", "Lid sinds"),
    "fan_teams_my_player_info": tr("My Player Info", "Mi info de jugador", "Mes infos joueur", "Minhas infos de jogador", "Meine Spielerinfos", "Le mie info giocatore", "Moje dane zawodnika", "Мои данные игрока", "Info e lojtarit tim", "我的球员信息", "Mijn spelerininfo"),
    "fan_teams_my_player_info_jersey_a11y_format": tr("Jersey number %lld", "Número %lld", "Numéro %lld", "Número %lld", "Rückennummer %lld", "Numero %lld", "Numer %lld", "Номер %lld", "Numri %lld", "球衣号码 %lld", "Rugnummer %lld"),
    "fan_teams_my_player_info_row_a11y_format": tr("%@: %@", "%@: %@", "%@ : %@", "%@: %@", "%@: %@", "%@: %@", "%@: %@", "%@: %@", "%@: %@", "%@：%@", "%@: %@"),
    "fan_teams_no_events_title": tr("No events yet", "Aún no hay eventos", "Pas encore d’événements", "Ainda sem eventos", "Noch keine Events", "Nessun evento ancora", "Brak wydarzeń", "Пока нет событий", "Ende pa evente", "还没有活动", "Nog geen events"),
    "fan_teams_no_events_body": tr("When this Team schedules an event, it will show up here.", "Cuando este equipo programe un evento, aparecerá aquí.", "Lorsqu’un événement sera planifié, il apparaîtra ici.", "Quando esta equipe agendar um evento, ele aparecerá aqui.", "Wenn dieses Team ein Event plant, erscheint es hier.", "Quando la squadra programmerà un evento, apparirà qui.", "Gdy drużyna zaplanuje wydarzenie, pojawi się tutaj.", "Когда команда запланирует событие, оно появится здесь.", "Kur ky ekip planifikon një event, do të shfaqet këtu.", "队伍安排活动后会显示在这里。", "Als dit team een event plant, verschijnt het hier."),
    "fan_teams_not_set": tr("Not set", "No definido", "Non défini", "Não definido", "Nicht festgelegt", "Non impostato", "Nie ustawiono", "Не задано", "I pacaktuar", "未设置", "Niet ingesteld"),
    "fan_teams_player_details": tr("Player Details", "Datos del jugador", "Détails du joueur", "Detalhes do jogador", "Spielerdetails", "Dettagli giocatore", "Dane zawodnika", "Данные игрока", "Detajet e lojtarit", "球员详情", "Spelergegevens"),
    "fan_teams_player_info_change_number_a11y": tr("Change number", "Cambiar número", "Modifier le numéro", "Alterar número", "Nummer ändern", "Cambia numero", "Zmień numer", "Изменить номер", "Ndrysho numrin", "更改号码", "Nummer wijzigen"),
    "fan_teams_player_info_change_position_a11y": tr("Change position", "Cambiar posición", "Modifier le poste", "Alterar posição", "Position ändern", "Cambia posizione", "Zmień pozycję", "Изменить позицию", "Ndrysho pozicionin", "更改位置", "Positie wijzigen"),
    "fan_teams_player_info_subject_a11y_format": tr("Player info for %@", "Info de jugador de %@", "Infos joueur de %@", "Info de jogador de %@", "Spielerinfo für %@", "Info giocatore di %@", "Dane zawodnika: %@", "Данные игрока: %@", "Info lojtari për %@", "%@ 的球员信息", "Spelerininfo voor %@"),
    "fan_teams_player_info_subject_selected_a11y_format": tr("Selected: %@", "Seleccionado: %@", "Sélectionné : %@", "Selecionado: %@", "Ausgewählt: %@", "Selezionato: %@", "Wybrano: %@", "Выбрано: %@", "Zgjedhur: %@", "已选择：%@", "Geselecteerd: %@"),
    "fan_teams_player_info_who_viewing": tr("Whose info", "Info de quién", "Infos de qui", "Info de quem", "Wessen Infos", "Info di chi", "Czyje dane", "Чьи данные", "Info e kujt", "查看谁的信息", "Van wie"),
    "fan_teams_player_information": tr("Player Information", "Información del jugador", "Informations du joueur", "Informações do jogador", "Spielerinformationen", "Informazioni giocatore", "Informacje o zawodniku", "Информация об игроке", "Informacioni i lojtarit", "球员信息", "Spelerinformatie"),
    "fan_teams_player_position_current_a11y_format": tr("Current position: %@", "Posición actual: %@", "Poste actuel : %@", "Posição atual: %@", "Aktuelle Position: %@", "Posizione attuale: %@", "Aktualna pozycja: %@", "Текущая позиция: %@", "Pozicioni aktual: %@", "当前位置：%@", "Huidige positie: %@"),
    "fan_teams_position": tr("Position", "Posición", "Poste", "Posição", "Position", "Posizione", "Pozycja", "Позиция", "Pozicioni", "位置", "Positie"),
    "fan_teams_remove_from_event": tr("Remove from event", "Quitar del evento", "Retirer de l’événement", "Remover do evento", "Vom Event entfernen", "Rimuovi dall’evento", "Usuń z wydarzenia", "Удалить из события", "Hiq nga eventi", "从活动中移除", "Verwijderen uit event"),
    "fan_teams_remove_from_event_confirm_action": tr("Remove", "Quitar", "Retirer", "Remover", "Entfernen", "Rimuovi", "Usuń", "Удалить", "Hiq", "移除", "Verwijderen"),
    "fan_teams_remove_from_event_confirm_body_format": tr(
        "Remove %@ from %@? They can be added back later.",
        "¿Quitar a %@ de %@? Podrás volver a añadirlo después.",
        "Retirer %@ de %@ ? Vous pourrez le remettre plus tard.",
        "Remover %@ de %@? Você poderá adicionar de volta depois.",
        "%@ aus %@ entfernen? Du kannst die Person später wieder hinzufügen.",
        "Rimuovere %@ da %@? Potrai riaggiungerlo in seguito.",
        "Usunąć %@ z %@? Później można dodać ponownie.",
        "Удалить %@ из %@? Позже можно вернуть.",
        "Të hiqet %@ nga %@? Mund ta shtosh sërish më vonë.",
        "将 %@ 从 %@ 移除？之后可以再加回来。",
        "%@ verwijderen uit %@? Je kunt die later weer toevoegen.",
    ),
    "fan_teams_remove_from_event_confirm_title": tr("Remove from event?", "¿Quitar del evento?", "Retirer de l’événement ?", "Remover do evento?", "Vom Event entfernen?", "Rimuovere dall’evento?", "Usunąć z wydarzenia?", "Удалить из события?", "Të hiqet nga eventi?", "从活动中移除？", "Verwijderen uit event?"),
    "fan_teams_remove_number": tr("Remove number", "Quitar número", "Supprimer le numéro", "Remover número", "Nummer entfernen", "Rimuovi numero", "Usuń numer", "Убрать номер", "Hiq numrin", "移除号码", "Nummer verwijderen"),
    "fan_teams_schedule_event": tr("Schedule Event", "Programar evento", "Planifier un événement", "Agendar evento", "Event planen", "Programma evento", "Zaplanuj wydarzenie", "Запланировать событие", "Planifiko event", "安排活动", "Event plannen"),
    "fan_teams_schedule_event_a11y_hint": tr("Opens Schedule Event", "Abre Programar evento", "Ouvre Planifier un événement", "Abre Agendar evento", "Öffnet Event planen", "Apre Programma evento", "Otwiera Zaplanuj wydarzenie", "Открывает «Запланировать событие»", "Hap Planifiko event", "打开安排活动", "Opent Event plannen"),
    "fan_teams_schedule_rsvp_privacy_note": tr("RSVP is visible to Team members.", "La asistencia es visible para los miembros del equipo.", "La réponse est visible par les membres de l’équipe.", "A confirmação é visível para os membros da equipe.", "RSVP ist für Teammitglieder sichtbar.", "L’RSVP è visibile ai membri della squadra.", "RSVP jest widoczne dla członków drużyny.", "Ответ виден участникам команды.", "RSVP është e dukshme për anëtarët e ekipit.", "回复对队伍成员可见。", "RSVP is zichtbaar voor teamleden."),
    "fan_teams_schedule_section_upcoming_events": tr("Upcoming Events", "Eventos próximos", "Événements à venir", "Eventos próximos", "Kommende Events", "Eventi in arrivo", "Nadchodzące wydarzenia", "Ближайшие события", "Evente të ardhshme", "即将开始的活动", "Aankomende events"),
    "fan_teams_schedule_section_past_events": tr("Past Events", "Eventos anteriores", "Événements passés", "Eventos anteriores", "Vergangene Events", "Eventi passati", "Minione wydarzenia", "Прошедшие события", "Evente të kaluara", "过往活动", "Eerdere events"),
    "fan_teams_set_player_position_failed": tr("Couldn’t save position.", "No se pudo guardar la posición.", "Impossible d’enregistrer le poste.", "Não foi possível salvar a posição.", "Position konnte nicht gespeichert werden.", "Impossibile salvare la posizione.", "Nie udało się zapisać pozycji.", "Не удалось сохранить позицию.", "Nuk u ruajt pozicioni.", "无法保存位置。", "Positie opslaan mislukt."),
    "fan_teams_tab_schedule": tr("Schedule", "Agenda", "Calendrier", "Agenda", "Plan", "Calendario", "Harmonogram", "Расписание", "Orari", "日程", "Agenda"),
    "fan_teams_team_role": tr("Team role", "Rol en el equipo", "Rôle dans l’équipe", "Função na equipe", "Teamrolle", "Ruolo in squadra", "Rola w drużynie", "Роль в команде", "Roli në ekip", "队伍角色", "Teamrol"),
    "fan_teams_team_status": tr("Team status", "Estado en el equipo", "Statut dans l’équipe", "Status na equipe", "Teamstatus", "Stato in squadra", "Status w drużynie", "Статус в команде", "Statusi në ekip", "队伍状态", "Teamstatus"),
})

ENTRIES.update({
    "managed_players_title": tr("My Players", "Mis jugadores", "Mes joueurs", "Meus jogadores", "Meine Spieler", "I miei giocatori", "Moi zawodnicy", "Мои игроки", "Lojtarët e mi", "我的球员", "Mijn spelers"),
    "managed_players_add": tr("Add Player", "Añadir jugador", "Ajouter un joueur", "Adicionar jogador", "Spieler hinzufügen", "Aggiungi giocatore", "Dodaj zawodnika", "Добавить игрока", "Shto lojtar", "添加球员", "Speler toevoegen"),
    "managed_players_add_to_team": tr("Add to Team", "Añadir al equipo", "Ajouter à l’équipe", "Adicionar à equipe", "Zum Team hinzufügen", "Aggiungi alla squadra", "Dodaj do drużyny", "Добавить в команду", "Shto në ekip", "加入队伍", "Aan team toevoegen"),
    "managed_players_add_to_team_confirm": tr("Add", "Añadir", "Ajouter", "Adicionar", "Hinzufügen", "Aggiungi", "Dodaj", "Добавить", "Shto", "添加", "Toevoegen"),
    "managed_players_add_to_team_empty_title": tr("No Teams available", "No hay equipos disponibles", "Aucune équipe disponible", "Nenhuma equipe disponível", "Keine Teams verfügbar", "Nessuna squadra disponibile", "Brak dostępnych drużyn", "Нет доступных команд", "Nuk ka ekipe të disponueshme", "暂无可用队伍", "Geen teams beschikbaar"),
    "managed_players_add_to_team_empty_body": tr("Create or join a Team first.", "Primero crea o únete a un equipo.", "Créez ou rejoignez d’abord une équipe.", "Crie ou entre em uma equipe primeiro.", "Erstelle oder trete zuerst einem Team bei.", "Crea o unisciti prima a una squadra.", "Najpierw utwórz drużynę lub dołącz do niej.", "Сначала создайте команду или вступите в неё.", "Së pari krijo ose bashkohu në një ekip.", "请先创建或加入一支队伍。", "Maak eerst een team of word lid."),
    "managed_players_add_to_team_footer": tr("Only Teams you manage can add a player.", "Solo los equipos que gestionas pueden añadir un jugador.", "Seules les équipes que vous gérez peuvent ajouter un joueur.", "Somente equipes que você gerencia podem adicionar um jogador.", "Nur Teams, die du verwaltest, können einen Spieler hinzufügen.", "Solo le squadre che gestisci possono aggiungere un giocatore.", "Tylko drużyny, którymi zarządzasz, mogą dodać zawodnika.", "Добавить игрока могут только команды, которыми вы управляете.", "Vetëm ekipet që menaxhon mund të shtojnë një lojtar.", "只有你管理的队伍可以添加球员。", "Alleen teams die je beheert kunnen een speler toevoegen."),
    "managed_players_add_to_team_header_format": tr("Add %@ to a Team", "Añadir a %@ a un equipo", "Ajouter %@ à une équipe", "Adicionar %@ a uma equipe", "%@ zu einem Team hinzufügen", "Aggiungi %@ a una squadra", "Dodaj %@ do drużyny", "Добавить %@ в команду", "Shto %@ në një ekip", "将 %@ 加入队伍", "%@ aan een team toevoegen"),
    "managed_players_already_on_team": tr("Already on this Team", "Ya está en este equipo", "Déjà dans cette équipe", "Já está nesta equipe", "Bereits in diesem Team", "Già in questa squadra", "Już w tej drużynie", "Уже в этой команде", "Tashmë në këtë ekip", "已在此队伍", "Al in dit team"),
    "managed_players_archive": tr("Archive Player", "Archivar jugador", "Archiver le joueur", "Arquivar jogador", "Spieler archivieren", "Archivia giocatore", "Archiwizuj zawodnika", "Архивировать игрока", "Arkivo lojtarin", "归档球员", "Speler archiveren"),
    "managed_players_archive_confirm": tr("Archive", "Archivar", "Archiver", "Arquivar", "Archivieren", "Archivia", "Archiwizuj", "Архивировать", "Arkivo", "归档", "Archiveren"),
    "managed_players_archive_footer": tr("Archiving hides this player from My Players. Team memberships are not deleted.", "Archivar oculta a este jugador de Mis jugadores. Las membresías no se eliminan.", "L’archivage masque ce joueur de Mes joueurs. Les appartenances ne sont pas supprimées.", "Arquivar oculta este jogador de Meus jogadores. As associações não são excluídas.", "Archivieren blendet diesen Spieler aus Meine Spieler aus. Mitgliedschaften bleiben.", "Archiviare nasconde questo giocatore da I miei giocatori. Le iscrizioni non vengono eliminate.", "Archiwizacja ukrywa zawodnika w Moi zawodnicy. Członkostwa nie są usuwane.", "Архивация скрывает игрока из «Мои игроки». Членство не удаляется.", "Arkivimi e fsheh këtë lojtar nga Lojtarët e mi. Anëtarësimet nuk fshihen.", "归档后此球员会从“我的球员”中隐藏，队伍成员身份不会删除。", "Archiveren verbergt deze speler in Mijn spelers. Lidmaatschappen worden niet verwijderd."),
    "managed_players_birth_year": tr("Birth year", "Año de nacimiento", "Année de naissance", "Ano de nascimento", "Geburtsjahr", "Anno di nascita", "Rok urodzenia", "Год рождения", "Viti i lindjes", "出生年份", "Geboortejaar"),
    "managed_players_birth_year_footer": tr("Year only — never a full birthday.", "Solo el año, nunca la fecha completa.", "Année uniquement — jamais la date complète.", "Somente o ano — nunca a data completa.", "Nur das Jahr — kein vollständiges Datum.", "Solo l’anno — mai la data completa.", "Tylko rok — nigdy pełna data.", "Только год — не полная дата.", "Vetëm viti — kurrë data e plotë.", "仅年份，不含完整生日。", "Alleen het jaar — nooit de volledige geboortedatum."),
    "managed_players_birth_year_format": tr("Born %@", "Nacido en %@", "Né(e) en %@", "Nascido em %@", "Geboren %@", "Nato nel %@", "Urodzony w %@", "Год рождения: %@", "Lindur më %@", "%@ 年出生", "Geboren %@"),
    "managed_players_change_photo": tr("Change Photo", "Cambiar foto", "Changer la photo", "Alterar foto", "Foto ändern", "Cambia foto", "Zmień zdjęcie", "Изменить фото", "Ndrysho foton", "更换照片", "Foto wijzigen"),
    "managed_players_empty_title": tr("No players yet", "Aún no hay jugadores", "Pas encore de joueurs", "Ainda sem jogadores", "Noch keine Spieler", "Nessun giocatore ancora", "Brak zawodników", "Пока нет игроков", "Ende pa lojtarë", "还没有球员", "Nog geen spelers"),
    "managed_players_empty_body": tr("Add a player you manage, like a child on a Team.", "Añade un jugador que gestionas, como un hijo en un equipo.", "Ajoutez un joueur que vous gérez, comme un enfant dans une équipe.", "Adicione um jogador que você gerencia, como um filho em uma equipe.", "Füge einen Spieler hinzu, den du verwaltest, z. B. ein Kind in einem Team.", "Aggiungi un giocatore che gestisci, ad esempio un figlio in una squadra.", "Dodaj zawodnika, którym zarządzasz, np. dziecko w drużynie.", "Добавьте игрока, которым вы управляете, например ребёнка в команде.", "Shto një lojtar që menaxhon, p.sh. një fëmijë në ekip.", "添加你管理的球员，例如队伍中的孩子。", "Voeg een speler toe die je beheert, zoals een kind in een team."),
    "managed_players_error_title": tr("Couldn’t load players", "No se pudieron cargar los jugadores", "Impossible de charger les joueurs", "Não foi possível carregar os jogadores", "Spieler konnten nicht geladen werden", "Impossibile caricare i giocatori", "Nie udało się wczytać zawodników", "Не удалось загрузить игроков", "Nuk u ngarkuan lojtarët", "无法加载球员", "Spelers laden mislukt"),
    "managed_players_first_name": tr("First name", "Nombre", "Prénom", "Nome", "Vorname", "Nome", "Imię", "Имя", "Emri", "名", "Voornaam"),
    "managed_players_invite_selection_empty": tr("Select at least one player.", "Selecciona al menos un jugador.", "Sélectionnez au moins un joueur.", "Selecione pelo menos um jogador.", "Wähle mindestens einen Spieler.", "Seleziona almeno un giocatore.", "Wybierz co najmniej jednego zawodnika.", "Выберите хотя бы одного игрока.", "Zgjidh të paktën një lojtar.", "请至少选择一名球员。", "Selecteer minstens één speler."),
    "managed_players_last_name": tr("Last name", "Apellido", "Nom", "Sobrenome", "Nachname", "Cognome", "Nazwisko", "Фамилия", "Mbiemri", "姓", "Achternaam"),
    "managed_players_manage": tr("Manage", "Gestionar", "Gérer", "Gerenciar", "Verwalten", "Gestisci", "Zarządzaj", "Управлять", "Menaxho", "管理", "Beheren"),
    "managed_players_no_teams": tr("Not on any Teams yet", "Aún no está en ningún equipo", "Pas encore dans une équipe", "Ainda não está em nenhuma equipe", "Noch in keinem Team", "Non ancora in nessuna squadra", "Jeszcze w żadnej drużynie", "Пока ни в одной команде", "Ende në asnjë ekip", "尚未加入任何队伍", "Nog in geen enkel team"),
    "managed_players_photo_load_failed": tr("Couldn’t load photo.", "No se pudo cargar la foto.", "Impossible de charger la photo.", "Não foi possível carregar a foto.", "Foto konnte nicht geladen werden.", "Impossibile caricare la foto.", "Nie udało się wczytać zdjęcia.", "Не удалось загрузить фото.", "Nuk u ngarkua fotoja.", "无法加载照片。", "Foto laden mislukt."),
    "managed_players_player_info": tr("Player Info", "Info del jugador", "Infos joueur", "Info do jogador", "Spielerinfo", "Info giocatore", "Dane zawodnika", "Данные игрока", "Info e lojtarit", "球员信息", "Spelerininfo"),
    "managed_players_preferred_name": tr("Preferred name", "Nombre preferido", "Prénom d’usage", "Nome preferido", "Bevorzugter Name", "Nome preferito", "Preferowane imię", "Предпочитаемое имя", "Emri i preferuar", "常用名", "Voorkeursnaam"),
    "managed_players_preferred_name_footer": tr("Shown on Teams instead of the legal first name when set.", "Si se indica, se muestra en los equipos en lugar del nombre legal.", "S’affiche dans les équipes à la place du prénom officiel.", "Se definido, aparece nas equipes no lugar do nome legal.", "Wird in Teams statt des offiziellen Vornamens angezeigt.", "Se impostato, viene mostrato nelle squadre al posto del nome legale.", "Jeśli ustawiono, wyświetlane w drużynach zamiast imienia urzędowego.", "Если задано, показывается в командах вместо официального имени.", "Nëse vendoset, shfaqet te ekipet në vend të emrit zyrtar.", "设置后，队伍中会显示常用名而不是法定名。", "Indien ingesteld, getoond in teams in plaats van de officiële voornaam."),
    "managed_players_privacy_footer": tr("My Players is private to you. It is not a public profile.", "Mis jugadores es privado. No es un perfil público.", "Mes joueurs est privé. Ce n’est pas un profil public.", "Meus jogadores é privado. Não é um perfil público.", "Meine Spieler ist privat. Kein öffentliches Profil.", "I miei giocatori è privato. Non è un profilo pubblico.", "Moi zawodnicy jest prywatne. To nie jest profil publiczny.", "«Мои игроки» доступны только вам. Это не публичный профиль.", "Lojtarët e mi është privat. Nuk është profil publik.", "“我的球员”仅你可见，不是公开资料。", "Mijn spelers is privé. Dit is geen openbaar profiel."),
    "managed_players_remove_photo": tr("Remove Photo", "Quitar foto", "Supprimer la photo", "Remover foto", "Foto entfernen", "Rimuovi foto", "Usuń zdjęcie", "Удалить фото", "Hiq foton", "移除照片", "Foto verwijderen"),
    "managed_players_seats_disabled": tr("Managed player seats are unavailable right now.", "Los asientos de jugadores gestionados no están disponibles ahora.", "Les places de joueurs gérés sont indisponibles pour le moment.", "Assentos de jogadores gerenciados indisponíveis no momento.", "Verwaltete Spielerplätze sind gerade nicht verfügbar.", "I posti per giocatori gestiti non sono disponibili ora.", "Miejsca zarządzanych zawodników są teraz niedostępne.", "Места управляемых игроков сейчас недоступны.", "Vendet e lojtarëve të menaxhuar nuk janë të disponueshme tani.", "托管球员席位暂时不可用。", "Beheerde spelersplekken zijn nu niet beschikbaar."),
    "managed_players_team_count_one": tr("1 Team", "1 equipo", "1 équipe", "1 equipe", "1 Team", "1 squadra", "1 drużyna", "1 команда", "1 ekip", "1 支队伍", "1 team"),
    "managed_players_team_count_other": tr("%lld Teams", "%lld equipos", "%lld équipes", "%lld equipes", "%lld Teams", "%lld squadre", "%lld drużyn", "%lld команд", "%lld ekipe", "%lld 支队伍", "%lld teams"),
    "managed_players_teams_section": tr("Teams", "Equipos", "Équipes", "Equipes", "Teams", "Squadre", "Drużyny", "Команды", "Ekipe", "队伍", "Teams"),
})

ENTRIES.update({
    "friend_groups_title": tr("Friend Groups", "Grupos de amigos", "Groupes d’amis", "Grupos de amigos", "Freundesgruppen", "Gruppi di amici", "Grupy znajomych", "Группы друзей", "Grupet e miqve", "好友分组", "Vriendengroepen"),
    "friend_groups_groups": tr("Groups", "Grupos", "Groupes", "Grupos", "Gruppen", "Gruppi", "Grupy", "Группы", "Grupe", "分组", "Groepen"),
    "friend_groups_all_friends": tr("All Friends", "Todos los amigos", "Tous les amis", "Todos os amigos", "Alle Freunde", "Tutti gli amici", "Wszyscy znajomi", "Все друзья", "Të gjithë miqtë", "全部好友", "Alle vrienden"),
    "friend_groups_new_group": tr("New Group", "Nuevo grupo", "Nouveau groupe", "Novo grupo", "Neue Gruppe", "Nuovo gruppo", "Nowa grupa", "Новая группа", "Grup i ri", "新建分组", "Nieuwe groep"),
    "friend_groups_create_title": tr("Create Group", "Crear grupo", "Créer un groupe", "Criar grupo", "Gruppe erstellen", "Crea gruppo", "Utwórz grupę", "Создать группу", "Krijo grup", "创建分组", "Groep maken"),
    "friend_groups_create_action": tr("Create", "Crear", "Créer", "Criar", "Erstellen", "Crea", "Utwórz", "Создать", "Krijo", "创建", "Maken"),
    "friend_groups_create_new_group": tr("Create New Group", "Crear nuevo grupo", "Créer un nouveau groupe", "Criar novo grupo", "Neue Gruppe erstellen", "Crea nuovo gruppo", "Utwórz nową grupę", "Создать новую группу", "Krijo grup të ri", "创建新分组", "Nieuwe groep maken"),
    "friend_groups_create_hero_body": tr("Name a group and add friends you invite together.", "Ponle nombre a un grupo y añade amigos a los que invitas juntos.", "Donnez un nom au groupe et ajoutez des amis que vous invitez ensemble.", "Dê um nome ao grupo e adicione amigos que você convida juntos.", "Benenne eine Gruppe und füge Freunde hinzu, die du gemeinsam einlädst.", "Dai un nome al gruppo e aggiungi amici che inviti insieme.", "Nazwij grupę i dodaj znajomych, których zapraszasz razem.", "Назовите группу и добавьте друзей, которых приглашаете вместе.", "Emërto një grup dhe shto miq që fton bashkë.", "为分组命名并添加你一起邀请的好友。", "Geef de groep een naam en voeg vrienden toe die je samen uitnodigt."),
    "friend_groups_name_label": tr("Group name", "Nombre del grupo", "Nom du groupe", "Nome do grupo", "Gruppenname", "Nome del gruppo", "Nazwa grupy", "Название группы", "Emri i grupit", "分组名称", "Groepsnaam"),
    "friend_groups_name_placeholder": tr("Weekend Crew", "Equipo del fin de semana", "Équipe du week-end", "Turma do fim de semana", "Wochenend-Crew", "Crew del weekend", "Ekipa weekendowa", "Команда выходных", "Ekipi i fundjavës", "周末小队", "Weekendcrew"),
    "friend_groups_name_footer": tr("Up to %lld characters.", "Hasta %lld caracteres.", "Jusqu’à %lld caractères.", "Até %lld caracteres.", "Maximal %lld Zeichen.", "Fino a %lld caratteri.", "Maksymalnie %lld znaków.", "До %lld символов.", "Deri në %lld karaktere.", "最多 %lld 个字符。", "Maximaal %lld tekens."),
    "friend_groups_add_friends": tr("Add Friends", "Añadir amigos", "Ajouter des amis", "Adicionar amigos", "Freunde hinzufügen", "Aggiungi amici", "Dodaj znajomych", "Добавить друзей", "Shto miq", "添加好友", "Vrienden toevoegen"),
    "friend_groups_add_to_group_title": tr("Add to Group", "Añadir al grupo", "Ajouter au groupe", "Adicionar ao grupo", "Zur Gruppe hinzufügen", "Aggiungi al gruppo", "Dodaj do grupy", "Добавить в группу", "Shto në grup", "添加到分组", "Aan groep toevoegen"),
    "friend_groups_remove_from_group": tr("Remove from Group", "Quitar del grupo", "Retirer du groupe", "Remover do grupo", "Aus Gruppe entfernen", "Rimuovi dal gruppo", "Usuń z grupy", "Удалить из группы", "Hiq nga grupi", "从分组移除", "Uit groep verwijderen"),
    "friend_groups_rename": tr("Rename", "Renombrar", "Renommer", "Renomear", "Umbenennen", "Rinomina", "Zmień nazwę", "Переименовать", "Riemërto", "重命名", "Hernoemen"),
    "friend_groups_rename_title": tr("Rename Group", "Renombrar grupo", "Renommer le groupe", "Renomear grupo", "Gruppe umbenennen", "Rinomina gruppo", "Zmień nazwę grupy", "Переименовать группу", "Riemërto grupin", "重命名分组", "Groep hernoemen"),
    "friend_groups_delete": tr("Delete", "Eliminar", "Supprimer", "Excluir", "Löschen", "Elimina", "Usuń", "Удалить", "Fshi", "删除", "Verwijderen"),
    "friend_groups_delete_title_format": tr("Delete %@?", "¿Eliminar %@?", "Supprimer %@ ?", "Excluir %@?", "%@ löschen?", "Eliminare %@?", "Usunąć %@?", "Удалить %@?", "Të fshihet %@?", "删除 %@？", "%@ verwijderen?"),
    "friend_groups_delete_message": tr("This removes the group. Your friends stay in your friends list.", "Esto elimina el grupo. Tus amigos siguen en tu lista.", "Cela supprime le groupe. Vos amis restent dans votre liste.", "Isso exclui o grupo. Seus amigos continuam na sua lista.", "Damit wird die Gruppe entfernt. Deine Freunde bleiben in der Liste.", "Questo elimina il gruppo. Gli amici restano nella lista.", "To usuwa grupę. Znajomi zostają na liście.", "Группа будет удалена. Друзья останутся в списке.", "Kjo e fshin grupin. Miqtë mbeten në listën tënde.", "这将删除分组。好友仍在你的好友列表中。", "Dit verwijdert de groep. Je vrienden blijven in je vriendenlijst."),
    "friend_groups_select_all": tr("Select All", "Seleccionar todo", "Tout sélectionner", "Selecionar tudo", "Alle auswählen", "Seleziona tutto", "Zaznacz wszystkie", "Выбрать все", "Zgjidh të gjitha", "全选", "Alles selecteren"),
    "friend_groups_empty_title": tr("No groups yet", "Aún no hay grupos", "Pas encore de groupes", "Ainda sem grupos", "Noch keine Gruppen", "Nessun gruppo ancora", "Brak grup", "Пока нет групп", "Ende pa grupe", "还没有分组", "Nog geen groepen"),
    "friend_groups_empty_body": tr("Create a group to invite the same friends faster.", "Crea un grupo para invitar más rápido a los mismos amigos.", "Créez un groupe pour inviter plus vite les mêmes amis.", "Crie um grupo para convidar os mesmos amigos mais rápido.", "Erstelle eine Gruppe, um dieselben Freunde schneller einzuladen.", "Crea un gruppo per invitare più in fretta gli stessi amici.", "Utwórz grupę, aby szybciej zapraszać tych samych znajomych.", "Создайте группу, чтобы быстрее приглашать тех же друзей.", "Krijo një grup për t’i ftuar më shpejt të njëjtët miq.", "创建分组，更快邀请同一批好友。", "Maak een groep om dezelfde vrienden sneller uit te nodigen."),
    "friend_groups_error_title": tr("Couldn’t load groups", "No se pudieron cargar los grupos", "Impossible de charger les groupes", "Não foi possível carregar os grupos", "Gruppen konnten nicht geladen werden", "Impossibile caricare i gruppi", "Nie udało się wczytać grup", "Не удалось загрузить группы", "Nuk u ngarkuan grupet", "无法加载分组", "Groepen laden mislukt"),
    "friend_groups_no_members": tr("No members yet", "Aún no hay miembros", "Pas encore de membres", "Ainda sem membros", "Noch keine Mitglieder", "Nessun membro ancora", "Brak członków", "Пока нет участников", "Ende pa anëtarë", "还没有成员", "Nog geen leden"),
    "friend_groups_members_section": tr("Members", "Miembros", "Membres", "Membros", "Mitglieder", "Membri", "Członkowie", "Участники", "Anëtarët", "成员", "Leden"),
    "friend_groups_member_count_one": tr("1 member", "1 miembro", "1 membre", "1 membro", "1 Mitglied", "1 membro", "1 członek", "1 участник", "1 anëtar", "1 位成员", "1 lid"),
    "friend_groups_member_count_other": tr("%lld members", "%lld miembros", "%lld membres", "%lld membros", "%lld Mitglieder", "%lld membri", "%lld członków", "%lld участников", "%lld anëtarë", "%lld 位成员", "%lld leden"),
    "friend_groups_invite_count_format": tr("%lld selected", "%lld seleccionados", "%lld sélectionnés", "%lld selecionados", "%lld ausgewählt", "%lld selezionati", "%lld wybranych", "%lld выбрано", "%lld të zgjedhur", "已选 %lld 人", "%lld geselecteerd"),
    "friend_groups_privacy_title": tr("Private to you", "Privado para ti", "Privé pour vous", "Privado para você", "Nur für dich", "Privato per te", "Widoczne tylko dla Ciebie", "Видно только вам", "Privat për ty", "仅你可见", "Alleen voor jou"),
    "friend_groups_privacy_body": tr("Friend groups are only visible to you. Other people cannot see your groups.", "Los grupos de amigos solo los ves tú. Nadie más puede verlos.", "Les groupes d’amis ne sont visibles que par vous.", "Os grupos de amigos são visíveis só para você.", "Freundesgruppen siehst nur du. Andere sehen sie nicht.", "I gruppi di amici sono visibili solo a te.", "Grupy znajomych widzisz tylko Ty.", "Группы друзей видны только вам.", "Grupet e miqve i sheh vetëm ti.", "好友分组仅你可见，其他人看不到。", "Vriendengroepen zijn alleen voor jou zichtbaar."),
    "friend_groups_no_friends_match": tr("No friends match your search.", "Ningún amigo coincide con la búsqueda.", "Aucun ami ne correspond à votre recherche.", "Nenhum amigo corresponde à busca.", "Keine Freunde passen zur Suche.", "Nessun amico corrisponde alla ricerca.", "Brak znajomych pasujących do wyszukiwania.", "Нет друзей по запросу.", "Asnjë mik nuk përputhet me kërkimin.", "没有匹配的好友。", "Geen vrienden komen overeen met je zoekopdracht."),
    "friend_groups_search_friends": tr("Search friends", "Buscar amigos", "Rechercher des amis", "Buscar amigos", "Freunde suchen", "Cerca amici", "Szukaj znajomych", "Поиск друзей", "Kërko miq", "搜索好友", "Vrienden zoeken"),
    "friend_groups_search_in_group": tr("Search in group", "Buscar en el grupo", "Rechercher dans le groupe", "Buscar no grupo", "In der Gruppe suchen", "Cerca nel gruppo", "Szukaj w grupie", "Поиск в группе", "Kërko në grup", "在分组中搜索", "Zoeken in groep"),
    "friend_groups_back_to_groups": tr("Back to Groups", "Volver a grupos", "Retour aux groupes", "Voltar aos grupos", "Zurück zu Gruppen", "Torna ai gruppi", "Wróć do grup", "Назад к группам", "Kthehu te grupet", "返回分组", "Terug naar groepen"),
    "friend_groups_a11y_group_row": tr("%@, %lld members", "%@, %lld miembros", "%@, %lld membres", "%@, %lld membros", "%@, %lld Mitglieder", "%@, %lld membri", "%@, %lld członków", "%@, %lld участников", "%@, %lld anëtarë", "%@，%lld 位成员", "%@, %lld leden"),
    "friend_groups_a11y_remove_member": tr("Remove from group", "Quitar del grupo", "Retirer du groupe", "Remover do grupo", "Aus Gruppe entfernen", "Rimuovi dal gruppo", "Usuń z grupy", "Удалить из группы", "Hiq nga grupi", "从分组移除", "Uit groep verwijderen"),
})

ENTRIES.update({
    "pickup_edit_change_opponent": tr("Opponent", "Rival", "Adversaire", "Adversário", "Gegner", "Avversario", "Przeciwnik", "Соперник", "Kundërshtari", "对手", "Tegenstander"),
    "pickup_form_add_opponent": tr("Add opponent", "Añadir rival", "Ajouter un adversaire", "Adicionar adversário", "Gegner hinzufügen", "Aggiungi avversario", "Dodaj przeciwnika", "Добавить соперника", "Shto kundërshtar", "添加对手", "Tegenstander toevoegen"),
    "pickup_form_intro_title_announcement": tr("Post an Announcement", "Publicar un anuncio", "Publier une annonce", "Publicar um anúncio", "Ankündigung posten", "Pubblica un annuncio", "Opublikuj ogłoszenie", "Опубликовать объявление", "Publiko një njoftim", "发布公告", "Aankondiging plaatsen"),
    "pickup_form_intro_title_other": tr("Schedule an Event", "Programar un evento", "Planifier un événement", "Agendar um evento", "Event planen", "Programma un evento", "Zaplanuj wydarzenie", "Запланировать событие", "Planifiko një event", "安排活动", "Event plannen"),
    "pickup_form_intro_title_team_meeting": tr("Schedule a Team Meeting", "Programar una reunión de equipo", "Planifier une réunion d’équipe", "Agendar uma reunião de equipe", "Teammeeting planen", "Programma una riunione di squadra", "Zaplanuj zebranie drużyny", "Запланировать командную встречу", "Planifiko një takim ekipi", "安排队伍会议", "Teambijeenkomst plannen"),
    "pickup_form_matchup": tr("Matchup", "Enfrentamiento", "Affiche", "Confronto", "Paarung", "Scontro", "Mecz", "Матч", "Ndeshja", "对阵", "Onderlinge wedstrijd"),
    "pickup_form_opponent": tr("Opponent", "Rival", "Adversaire", "Adversário", "Gegner", "Avversario", "Przeciwnik", "Соперник", "Kundërshtari", "对手", "Tegenstander"),
    "pickup_form_opponent_footer": tr("Optional. Leave blank if there is no opponent.", "Opcional. Déjalo vacío si no hay rival.", "Facultatif. Laissez vide s’il n’y a pas d’adversaire.", "Opcional. Deixe em branco se não houver adversário.", "Optional. Leer lassen, wenn es keinen Gegner gibt.", "Facoltativo. Lascia vuoto se non c’è un avversario.", "Opcjonalne. Zostaw puste, jeśli nie ma przeciwnika.", "Необязательно. Оставьте пустым, если соперника нет.", "Opsionale. Lëre bosh nëse nuk ka kundërshtar.", "可选。没有对手可留空。", "Optioneel. Laat leeg als er geen tegenstander is."),
    "pickup_form_ready_add_opponent": tr("Add an opponent", "Añade un rival", "Ajoutez un adversaire", "Adicione um adversário", "Gegner hinzufügen", "Aggiungi un avversario", "Dodaj przeciwnika", "Добавьте соперника", "Shto një kundërshtar", "添加对手", "Voeg een tegenstander toe"),
    "pickup_form_team_event_rsvp_only_help": tr("Team members RSVP Going or Can’t Go. There is no join request.", "Los miembros confirman asistencia o no. No hay solicitud para unirse.", "Les membres répondent Présent ou Absent. Pas de demande d’inscription.", "Os membros confirmam presença ou não. Não há pedido para entrar.", "Teammitglieder sagen Going oder Absage. Keine Beitrittsanfrage.", "I membri rispondono Partecipo o Non posso. Nessuna richiesta di iscrizione.", "Członkowie potwierdzają udział lub rezygnację. Brak prośby o dołączenie.", "Участники отвечают «иду» или «не могу». Заявки на вступление нет.", "Anëtarët konfirmojnë pjesëmarrjen ose jo. Nuk ka kërkesë për t’u bashkuar.", "队伍成员回复参加或不去，无需加入申请。", "Teamlid RSVP’en Going of Kan niet. Er is geen deelnameverzoek."),
    "pickup_game_format_announcement": tr("Announcement", "Anuncio", "Annonce", "Anúncio", "Ankündigung", "Annuncio", "Ogłoszenie", "Объявление", "Njoftim", "公告", "Aankondiging"),
    "pickup_game_format_other": tr("Other", "Otro", "Autre", "Outro", "Sonstiges", "Altro", "Inne", "Другое", "Tjetër", "其他", "Overig"),
    "pickup_game_format_team_meeting": tr("Team Meeting", "Reunión de equipo", "Réunion d’équipe", "Reunião de equipe", "Teammeeting", "Riunione di squadra", "Zebranie drużyny", "Командная встреча", "Takim ekipi", "队伍会议", "Teambijeenkomst"),
    "profile_discovery_help_on_search": tr("Appear in search", "Aparecer en la búsqueda", "Apparaître dans la recherche", "Aparecer na busca", "In der Suche erscheinen", "Comparire nella ricerca", "Pojawiaj się w wyszukiwaniu", "Появляться в поиске", "Shfaqu në kërkim", "出现在搜索中", "Verschijn in zoekresultaten"),
    "profile_discovery_help_off_search": tr("You won’t appear in search", "No aparecerás en la búsqueda", "Vous n’apparaîtrez pas dans la recherche", "Você não aparecerá na busca", "Du erscheinst nicht in der Suche", "Non comparirai nella ricerca", "Nie pojawisz się w wyszukiwaniu", "Вы не будете в поиске", "Nuk do të shfaqesh në kërkim", "你不会出现在搜索中", "Je verschijnt niet in zoekresultaten"),
    "profile_discovery_help_privacy_section": tr("Privacy", "Privacidad", "Confidentialité", "Privacidade", "Datenschutz", "Privacy", "Prywatność", "Конфиденциальность", "Privatësia", "隐私", "Privacy"),
    "public_profile_hidden_title": tr("This profile is hidden", "Este perfil está oculto", "Ce profil est masqué", "Este perfil está oculto", "Dieses Profil ist ausgeblendet", "Questo profilo è nascosto", "Ten profil jest ukryty", "Этот профиль скрыт", "Ky profil është i fshehur", "此资料已隐藏", "Dit profiel is verborgen"),
    "public_profile_hidden_body_line1": tr("This fan has turned off Profile Discovery.", "Este fan ha desactivado Descubrir perfil.", "Ce fan a désactivé Découvrir mon profil.", "Este fã desativou Descobrir perfil.", "Dieser Fan hat Profilentdeckung deaktiviert.", "Questo fan ha disattivato Scopri il mio profilo.", "Ten fan wyłączył Odkrywanie profilu.", "Этот фанат отключил обнаружение профиля.", "Ky tifoz e ka çaktivizuar Zbulimin e profilit.", "该用户已关闭个人资料发现。", "Deze fan heeft Profiel ontdekken uitgeschakeld."),
    "public_profile_hidden_body_line2": tr("Only accepted friends can open it.", "Solo los amigos aceptados pueden abrirlo.", "Seuls les amis acceptés peuvent l’ouvrir.", "Somente amigos aceitos podem abri-lo.", "Nur akzeptierte Freunde können es öffnen.", "Solo gli amici accettati possono aprirlo.", "Tylko zaakceptowani znajomi mogą go otworzyć.", "Открыть могут только принятые друзья.", "Vetëm miqtë e pranuar mund ta hapin.", "仅已接受的好友可以打开。", "Alleen geaccepteerde vrienden kunnen het openen."),
    "public_profile_hidden_body_line3": tr("You can still message if you already have a conversation.", "Aún puedes enviar mensajes si ya tenéis una conversación.", "Vous pouvez encore envoyer un message si une conversation existe déjà.", "Você ainda pode enviar mensagens se já tiverem uma conversa.", "Du kannst weiter schreiben, wenn bereits ein Chat besteht.", "Puoi ancora scrivere se avete già una conversazione.", "Nadal możesz pisać, jeśli macie już rozmowę.", "Сообщения доступны, если диалог уже есть.", "Mund të dërgosh mesazhe nëse keni tashmë një bisedë.", "如果已有对话，仍可发消息。", "Je kunt nog berichten sturen als jullie al een gesprek hebben."),
    "public_profile_hidden_close_a11y": tr("Close", "Cerrar", "Fermer", "Fechar", "Schließen", "Chiudi", "Zamknij", "Закрыть", "Mbyll", "关闭", "Sluiten"),
    "public_profile_hidden_turn_on": tr("Turn On Profile Discovery", "Activar Descubrir perfil", "Activer Découvrir mon profil", "Ativar Descobrir perfil", "Profilentdeckung aktivieren", "Attiva Scopri il mio profilo", "Włącz Odkrywanie profilu", "Включить обнаружение профиля", "Aktivizo Zbulimin e profilit", "开启个人资料发现", "Profiel ontdekken inschakelen"),
    "public_profile_hidden_turn_on_a11y": tr("Turn on Profile Discovery", "Activar Descubrir perfil", "Activer Découvrir mon profil", "Ativar Descobrir perfil", "Profilentdeckung aktivieren", "Attiva Scopri il mio profilo", "Włącz Odkrywanie profilu", "Включить обнаружение профиля", "Aktivizo Zbulimin e profilit", "开启个人资料发现", "Profiel ontdekken inschakelen"),
    "no_team_events_found": tr("No Team events found", "No se encontraron eventos de equipo", "Aucun événement d’équipe trouvé", "Nenhum evento de equipe encontrado", "Keine Team-Events gefunden", "Nessun evento di squadra trovato", "Nie znaleziono wydarzeń drużyny", "События команды не найдены", "Nuk u gjetën evente ekipi", "未找到队伍活动", "Geen teamevents gevonden"),
    "no_team_events_found_supporting": tr("When your Teams schedule events, they will show up here.", "Cuando tus equipos programen eventos, aparecerán aquí.", "Lorsque vos équipes planifieront des événements, ils apparaîtront ici.", "Quando suas equipes agendarem eventos, eles aparecerão aqui.", "Wenn deine Teams Events planen, erscheinen sie hier.", "Quando le tue squadre programmeranno eventi, appariranno qui.", "Gdy twoje drużyny zaplanują wydarzenia, pojawią się tutaj.", "Когда ваши команды запланируют события, они появятся здесь.", "Kur ekipet e tua planifikojnë evente, do të shfaqen këtu.", "队伍安排活动后会显示在这里。", "Als je teams events plannen, verschijnen ze hier."),
    "no_team_events_found_supporting_sport_format": tr("No %@ Team events found.", "No se encontraron eventos de equipo de %@.", "Aucun événement d’équipe %@ trouvé.", "Nenhum evento de equipe de %@ encontrado.", "Keine %@-Team-Events gefunden.", "Nessun evento di squadra %@ trovato.", "Nie znaleziono wydarzeń drużyny (%@).", "События команды (%@) не найдены.", "Nuk u gjetën evente ekipi %@.", "未找到 %@ 队伍活动。", "Geen %@-teamevents gevonden."),
    "schedule_noun_team_events": tr("Team Events", "Eventos de equipo", "Événements d’équipe", "Eventos de equipe", "Team-Events", "Eventi di squadra", "Wydarzenia drużyny", "События команды", "Evente ekipi", "队伍活动", "Teamevents"),
    "settings_security_section_title": tr("Security", "Seguridad", "Sécurité", "Segurança", "Sicherheit", "Sicurezza", "Bezpieczeństwo", "Безопасность", "Siguria", "安全", "Beveiliging"),
    "settings_profile_visibility_section_title": tr("Profile Visibility", "Visibilidad del perfil", "Visibilité du profil", "Visibilidade do perfil", "Profilsichtbarkeit", "Visibilità del profilo", "Widoczność profilu", "Видимость профиля", "Dukshmëria e profilit", "资料可见性", "Profielzichtbaarheid"),
    "guide_schedule_live_hero_a11y": tr("Schedule illustration showing Team events and live games", "Ilustración de Agenda con eventos de equipo y partidos en vivo", "Illustration Agenda montrant des événements d’équipe et des matchs en direct", "Ilustração da Agenda com eventos de equipe e jogos ao vivo", "Plan-Illustration mit Team-Events und Live-Spielen", "Illustrazione Calendario con eventi di squadra e partite live", "Ilustracja Harmonogramu z wydarzeniami drużyny i meczami na żywo", "Иллюстрация расписания с событиями команды и прямыми трансляциями", "Ilustrim i Orarit me evente ekipi dhe ndeshje live", "日程插图，展示队伍活动和直播比赛", "Agenda-illustratie met teamevents en live wedstrijden"),
    "guide_teams_hero_a11y": tr("Teams illustration showing FanGeo Team identity, roster, and schedule", "Ilustración de Equipos con identidad, plantilla y agenda de un equipo FanGeo", "Illustration Équipes montrant l’identité, l’effectif et le calendrier d’une équipe FanGeo", "Ilustração de Equipes com identidade, elenco e agenda de uma equipe FanGeo", "Teams-Illustration mit Identität, Kader und Plan eines FanGeo-Teams", "Illustrazione Squadre con identità, rosa e calendario di una squadra FanGeo", "Ilustracja Drużyn z tożsamością, kadrą i harmonogramem drużyny FanGeo", "Иллюстрация команд с идентичностью, заявкой и расписанием команды FanGeo", "Ilustrim i Ekipeve me identitetin, listën dhe orarin e një ekipi FanGeo", "队伍插图，展示 FanGeo 队伍标识、名单和日程", "Teams-illustratie met identiteit, selectie en agenda van een FanGeo-team"),
    "report_conversation": tr("Report Conversation", "Denunciar conversación", "Signaler la conversation", "Denunciar conversa", "Unterhaltung melden", "Segnala conversazione", "Zgłoś rozmowę", "Пожаловаться на переписку", "Raporto bisedën", "举报对话", "Gesprek rapporteren"),
    "report_message": tr("Report Message", "Denunciar mensaje", "Signaler le message", "Denunciar mensagem", "Nachricht melden", "Segnala messaggio", "Zgłoś wiadomość", "Пожаловаться на сообщение", "Raporto mesazhin", "举报消息", "Bericht rapporteren"),
    "report_user": tr("Report User", "Denunciar usuario", "Signaler l’utilisateur", "Denunciar usuário", "Nutzer melden", "Segnala utente", "Zgłoś użytkownika", "Пожаловаться на пользователя", "Raporto përdoruesin", "举报用户", "Gebruiker rapporteren"),
    "report_problem": tr("Report a Problem", "Informar de un problema", "Signaler un problème", "Relatar um problema", "Problem melden", "Segnala un problema", "Zgłoś problem", "Сообщить о проблеме", "Raporto një problem", "报告问题", "Probleem melden"),
})

ENTRIES.update({
    "team_announcement_form_section": tr("Announcement", "Anuncio", "Annonce", "Anúncio", "Ankündigung", "Annuncio", "Ogłoszenie", "Объявление", "Njoftim", "公告", "Aankondiging"),
    "team_announcement_manager_fallback": tr("Team manager", "Responsable del equipo", "Responsable d’équipe", "Gestor da equipe", "Team-Manager", "Manager della squadra", "Menedżer drużyny", "Менеджер команды", "Menaxheri i ekipit", "队伍管理员", "Teammanager"),
    "team_announcement_message_label": tr("Message", "Mensaje", "Message", "Mensagem", "Nachricht", "Messaggio", "Wiadomość", "Сообщение", "Mesazhi", "正文", "Bericht"),
    "team_announcement_message_placeholder": tr("Write the announcement…", "Escribe el anuncio…", "Rédigez l’annonce…", "Escreva o anúncio…", "Ankündigung schreiben…", "Scrivi l’annuncio…", "Napisz ogłoszenie…", "Напишите объявление…", "Shkruaj njoftimin…", "撰写公告…", "Schrijf de aankondiging…"),
    "team_announcement_message_too_long": tr("Message is too long.", "El mensaje es demasiado largo.", "Le message est trop long.", "A mensagem é longa demais.", "Die Nachricht ist zu lang.", "Il messaggio è troppo lungo.", "Wiadomość jest za długa.", "Сообщение слишком длинное.", "Mesazhi është shumë i gjatë.", "正文过长。", "Bericht is te lang."),
    "team_announcement_overview_a11y_hint": tr("Opens announcement", "Abre el anuncio", "Ouvre l’annonce", "Abre o anúncio", "Öffnet die Ankündigung", "Apre l’annuncio", "Otwiera ogłoszenie", "Открывает объявление", "Hap njoftimin", "打开公告", "Opent aankondiging"),
    "team_announcement_overview_badge": tr("Announcement", "Anuncio", "Annonce", "Anúncio", "Ankündigung", "Annuncio", "Ogłoszenie", "Объявление", "Njoftim", "公告", "Aankondiging"),
    "team_announcement_permission_denied": tr("You don’t have permission to post announcements.", "No tienes permiso para publicar anuncios.", "Vous n’avez pas l’autorisation de publier des annonces.", "Você não tem permissão para publicar anúncios.", "Du darfst keine Ankündigungen posten.", "Non hai il permesso di pubblicare annunci.", "Nie masz uprawnień do publikowania ogłoszeń.", "У вас нет права публиковать объявления.", "Nuk keni leje të publikoni njoftime.", "你没有权限发布公告。", "Je mag geen aankondigingen plaatsen."),
    "team_announcement_post_action": tr("Post Announcement", "Publicar anuncio", "Publier l’annonce", "Publicar anúncio", "Ankündigung posten", "Pubblica annuncio", "Opublikuj ogłoszenie", "Опубликовать объявление", "Publiko njoftimin", "发布公告", "Aankondiging plaatsen"),
    "team_announcement_ready_add_message": tr("Add a message", "Añade un mensaje", "Ajoutez un message", "Adicione uma mensagem", "Nachricht hinzufügen", "Aggiungi un messaggio", "Dodaj wiadomość", "Добавьте сообщение", "Shto një mesazh", "添加正文", "Voeg een bericht toe"),
    "team_announcement_title_label": tr("Title", "Título", "Titre", "Título", "Titel", "Titolo", "Tytuł", "Заголовок", "Titulli", "标题", "Titel"),
    "team_announcement_title_placeholder": tr("Announcement title", "Título del anuncio", "Titre de l’annonce", "Título do anúncio", "Titel der Ankündigung", "Titolo dell’annuncio", "Tytuł ogłoszenia", "Заголовок объявления", "Titulli i njoftimit", "公告标题", "Titel van aankondiging"),
    "team_event_change_your_response": tr("Change your response", "Cambiar tu respuesta", "Modifier votre réponse", "Alterar sua resposta", "Antwort ändern", "Cambia la tua risposta", "Zmień odpowiedź", "Изменить ответ", "Ndrysho përgjigjen", "更改你的回复", "Je antwoord wijzigen"),
    "team_event_directions_a11y_format": tr("Directions to %@", "Cómo llegar a %@", "Itinéraire vers %@", "Como chegar a %@", "Route zu %@", "Indicazioni per %@", "Dojazd do %@", "Маршрут до %@", "Drejtimet për %@", "前往 %@ 的路线", "Route naar %@"),
    "team_event_more_details": tr("More Details", "Más detalles", "Plus de détails", "Mais detalhes", "Mehr Details", "Altri dettagli", "Więcej szczegółów", "Подробнее", "Më shumë detaje", "更多详情", "Meer details"),
    "team_event_notes_title": tr("Notes", "Notas", "Notes", "Notas", "Notizen", "Note", "Notatki", "Заметки", "Shënime", "备注", "Notities"),
    "team_invite_add_another": tr("Add another", "Añadir otro", "Ajouter un autre", "Adicionar outro", "Weiteren hinzufügen", "Aggiungi un altro", "Dodaj kolejnego", "Добавить ещё", "Shto një tjetër", "再添加一位", "Nog een toevoegen"),
    "team_invite_join_team": tr("Join Team", "Unirse al equipo", "Rejoindre l’équipe", "Entrar na equipe", "Team beitreten", "Unisciti alla squadra", "Dołącz do drużyny", "Вступить в команду", "Bashkohu në ekip", "加入队伍", "Lid worden"),
    "team_invite_managed_caption": tr("Managed Player", "Jugador gestionado", "Joueur géré", "Jogador gerenciado", "Verwalteter Spieler", "Giocatore gestito", "Zarządzany zawodnik", "Управляемый игрок", "Lojtar i menaxhuar", "托管球员", "Beheerde speler"),
    "team_invite_myself_caption": tr("Your own membership", "Tu propia membresía", "Votre propre adhésion", "Sua própria associação", "Deine eigene Mitgliedschaft", "La tua iscrizione", "Twoje własne członkostwo", "Ваше членство", "Anëtarësimi yt", "你自己的成员身份", "Je eigen lidmaatschap"),
    "team_invite_who_joining_format": tr("Who is joining %@?", "¿Quién se une a %@?", "Qui rejoint %@ ?", "Quem está entrando em %@?", "Wer tritt %@ bei?", "Chi si unisce a %@?", "Kto dołącza do %@?", "Кто вступает в %@?", "Kush po bashkohet me %@?", "谁将加入 %@？", "Wie wordt lid van %@?"),
    "team_invite_who_joining_subtitle": tr("Choose yourself, a player you manage, or both.", "Elige tú, un jugador que gestionas, o ambos.", "Choisissez vous-même, un joueur que vous gérez, ou les deux.", "Escolha você, um jogador que gerencia, ou ambos.", "Wähle dich selbst, einen verwalteten Spieler oder beides.", "Scegli te stesso, un giocatore che gestisci, o entrambi.", "Wybierz siebie, zawodnika którym zarządzasz, albo obu.", "Выберите себя, управляемого игрока или обоих.", "Zgjidh veten, një lojtar që menaxhon, ose të dy.", "选择你自己、你管理的球员，或两者。", "Kies jezelf, een speler die je beheert, of beide."),
    "team_player_selector_footer": tr("You can join for yourself and add managed players in one step.", "Puedes unirte tú y añadir jugadores gestionados en un paso.", "Vous pouvez rejoindre pour vous et ajouter des joueurs gérés en une étape.", "Você pode entrar e adicionar jogadores gerenciados de uma vez.", "Du kannst selbst beitreten und verwaltete Spieler in einem Schritt hinzufügen.", "Puoi unirti tu e aggiungere giocatori gestiti in un passaggio.", "Możesz dołączyć sam i dodać zarządzanych zawodników za jednym razem.", "Можно вступить самому и сразу добавить управляемых игроков.", "Mund të bashkohesh vetë dhe të shtosh lojtarë të menaxhuar në një hap.", "你可以同时为自己加入并添加托管球员。", "Je kunt zelf lid worden en beheerde spelers in één stap toevoegen."),
    "team_player_selector_join_title": tr("Join", "Unirse", "Rejoindre", "Entrar", "Beitreten", "Unisciti", "Dołącz", "Вступить", "Bashkohu", "加入", "Lid worden"),
    "team_player_selector_myself": tr("Myself", "Yo", "Moi", "Eu", "Ich", "Io", "Ja", "Я", "Unë", "我自己", "Ikzelf"),
    "team_poll_create_management_only_hint": tr("Only Team managers can create polls.", "Solo los responsables del equipo pueden crear encuestas.", "Seuls les responsables d’équipe peuvent créer des sondages.", "Somente gestores da equipe podem criar enquetes.", "Nur Team-Manager können Umfragen erstellen.", "Solo i manager della squadra possono creare sondaggi.", "Tylko menedżerowie drużyny mogą tworzyć ankiety.", "Опросы могут создавать только менеджеры команды.", "Vetëm menaxherët e ekipit mund të krijojnë sondazhe.", "只有队伍管理员可以创建投票。", "Alleen teammanagers kunnen polls maken."),
    "team_poll_permission_anyone": tr("Anyone on the Team", "Cualquiera del equipo", "Tous les membres de l’équipe", "Qualquer um da equipe", "Alle im Team", "Chiunque nella squadra", "Każdy w drużynie", "Любой в команде", "Kushdo në ekip", "队伍中的任何人", "Iedereen in het team"),
    "team_poll_permission_management_only": tr("Managers only", "Solo responsables", "Responsables uniquement", "Somente gestores", "Nur Manager", "Solo manager", "Tylko menedżerowie", "Только менеджеры", "Vetëm menaxherët", "仅管理员", "Alleen managers"),
    "team_schedule_add": tr("Add", "Añadir", "Ajouter", "Adicionar", "Hinzufügen", "Aggiungi", "Dodaj", "Добавить", "Shto", "添加", "Toevoegen"),
    "team_schedule_arrival_none": tr("None", "Ninguna", "Aucune", "Nenhuma", "Keine", "Nessuno", "Brak", "Нет", "Asnjë", "无", "Geen"),
    "team_schedule_arrival_time": tr("Arrival time", "Hora de llegada", "Heure d’arrivée", "Horário de chegada", "Ankunftszeit", "Orario di arrivo", "Godzina przybycia", "Время прибытия", "Ora e mbërritjes", "到达时间", "Aankomsttijd"),
    "team_schedule_arrival_time_subtitle": tr("Optional time to arrive before the event starts.", "Hora opcional para llegar antes de que empiece el evento.", "Heure facultative d’arrivée avant le début.", "Horário opcional para chegar antes do início.", "Optionale Zeit zum Eintreffen vor dem Start.", "Orario facoltativo per arrivare prima dell’inizio.", "Opcjonalna godzina przybycia przed startem.", "Необязательное время прибытия до начала.", "Orë opsionale për të mbërritur para fillimit.", "可选，活动开始前到达的时间。", "Optionele tijd om vóór de start aan te komen."),
    "team_schedule_description_subtitle": tr("Optional notes for the Team.", "Notas opcionales para el equipo.", "Notes facultatives pour l’équipe.", "Notas opcionais para a equipe.", "Optionale Notizen für das Team.", "Note facoltative per la squadra.", "Opcjonalne uwagi dla drużyny.", "Необязательные заметки для команды.", "Shënime opsionale për ekipin.", "给队伍的可选备注。", "Optionele notities voor het team."),
    "team_schedule_end_after_start": tr("End time must be after start time.", "La hora de fin debe ser posterior a la de inicio.", "L’heure de fin doit être après l’heure de début.", "O término deve ser depois do início.", "Die Endzeit muss nach der Startzeit liegen.", "L’orario di fine deve essere dopo l’inizio.", "Czas zakończenia musi być po starcie.", "Время окончания должно быть позже начала.", "Ora e mbarimit duhet të jetë pas fillimit.", "结束时间必须晚于开始时间。", "Eindtijd moet na de starttijd liggen."),
    "team_schedule_more_options": tr("More options", "Más opciones", "Plus d’options", "Mais opções", "Weitere Optionen", "Altre opzioni", "Więcej opcji", "Другие параметры", "Më shumë mundësi", "更多选项", "Meer opties"),
    "team_schedule_more_options_subtitle": tr("Arrival time, notes, and other details.", "Hora de llegada, notas y otros detalles.", "Heure d’arrivée, notes et autres détails.", "Horário de chegada, notas e outros detalhes.", "Ankunftszeit, Notizen und weitere Details.", "Orario di arrivo, note e altri dettagli.", "Godzina przybycia, notatki i inne szczegóły.", "Время прибытия, заметки и другие детали.", "Ora e mbërritjes, shënime dhe detaje të tjera.", "到达时间、备注及其他详情。", "Aankomsttijd, notities en andere details."),
    "team_schedule_post_event": tr("Post Event", "Publicar evento", "Publier l’événement", "Publicar evento", "Event posten", "Pubblica evento", "Opublikuj wydarzenie", "Опубликовать событие", "Publiko eventin", "发布活动", "Event plaatsen"),
    "team_schedule_post_game": tr("Post Game", "Publicar partido", "Publier le match", "Publicar jogo", "Spiel posten", "Pubblica partita", "Opublikuj mecz", "Опубликовать игру", "Publiko ndeshjen", "发布比赛", "Wedstrijd plaatsen"),
    "team_schedule_post_practice": tr("Post Practice", "Publicar entrenamiento", "Publier l’entraînement", "Publicar treino", "Training posten", "Pubblica allenamento", "Opublikuj trening", "Опубликовать тренировку", "Publiko stërvitjen", "发布训练", "Training plaatsen"),
    "team_schedule_post_tryout": tr("Post Tryout", "Publicar prueba", "Publier l’essai", "Publicar seletiva", "Probetraining posten", "Pubblica provino", "Opublikuj test", "Опубликовать просмотр", "Publiko provën", "发布选拔", "Try-out plaatsen"),
    "team_schedule_sport_subtitle": tr("Used for filters and lineup positions.", "Se usa en filtros y posiciones de alineación.", "Utilisé pour les filtres et les postes.", "Usado em filtros e posições da escalação.", "Wird für Filter und Aufstellungspositionen verwendet.", "Usato per filtri e posizioni della formazione.", "Używane w filtrach i pozycjach składu.", "Используется для фильтров и позиций состава.", "Përdoret për filtra dhe pozicione formacioni.", "用于筛选和阵容位置。", "Gebruikt voor filters en opstellingsposities."),
    "team_schedule_time_editor_footer": tr("Times use your local time zone.", "Las horas usan tu zona horaria local.", "Les heures utilisent votre fuseau horaire local.", "Os horários usam seu fuso local.", "Zeiten nutzen deine lokale Zeitzone.", "Gli orari usano il tuo fuso orario locale.", "Godziny używają twojej lokalnej strefy.", "Время указано в вашем часовом поясе.", "Orët përdorin zonën tënde kohore.", "时间使用你的本地时区。", "Tijden gebruiken je lokale tijdzone."),
    "team_schedule_time_label": tr("Time", "Hora", "Heure", "Horário", "Zeit", "Orario", "Godzina", "Время", "Ora", "时间", "Tijd"),
    "team_schedule_time_subtitle": tr("Start and end for this event.", "Inicio y fin de este evento.", "Début et fin de cet événement.", "Início e término deste evento.", "Start und Ende dieses Events.", "Inizio e fine di questo evento.", "Początek i koniec tego wydarzenia.", "Начало и конец этого события.", "Fillimi dhe mbarimi i këtij eventi.", "此活动的开始和结束时间。", "Start en einde van dit event."),
    "team_schedule_title_subtitle": tr("Shown on the Team schedule and in Inbox.", "Se muestra en la agenda del equipo y en Inbox.", "Affiché dans le calendrier de l’équipe et dans Inbox.", "Aparece na agenda da equipe e no Inbox.", "Wird im Teamplan und in Inbox angezeigt.", "Mostrato nel calendario della squadra e in Inbox.", "Widoczne w harmonogramie drużyny i w Inbox.", "Показывается в расписании команды и во входящих.", "Shfaqet në orarin e ekipit dhe në Inbox.", "显示在队伍日程和收件箱中。", "Getoond in de teamagenda en in Inbox."),
    "fan_teams_filter_a11y": tr("%@, %lld", "%@, %lld", "%@, %lld", "%@, %lld", "%@, %lld", "%@, %lld", "%@, %lld", "%@, %lld", "%@, %lld", "%@，%lld", "%@, %lld"),
    "fan_teams_filter_a11y_selected": tr("%@, %lld, selected", "%@, %lld, seleccionado", "%@, %lld, sélectionné", "%@, %lld, selecionado", "%@, %lld, ausgewählt", "%@, %lld, selezionato", "%@, %lld, wybrane", "%@, %lld, выбрано", "%@, %lld, zgjedhur", "%@，%lld，已选", "%@, %lld, geselecteerd"),
    "fan_team_schedule_rsvp_is_going_format": tr("%@ is Going", "%@ asiste", "%@ est présent(e)", "%@ vai", "%@ geht hin", "%@ partecipa", "%@ idzie", "%@ идёт", "%@ shkon", "%@ 将参加", "%@ gaat"),
    "fan_team_schedule_rsvp_may_be_going_format": tr("%@ may be going", "%@ quizá asista", "%@ sera peut-être là", "%@ talvez vá", "%@ kommt vielleicht", "%@ forse partecipa", "%@ może pójść", "%@ возможно пойдёт", "%@ ndoshta shkon", "%@ 可能参加", "%@ gaat misschien"),
    "fan_team_schedule_rsvp_cant_go_format": tr("%@ can’t go", "%@ no puede ir", "%@ ne peut pas venir", "%@ não pode ir", "%@ kann nicht", "%@ non può", "%@ nie może", "%@ не может", "%@ nuk mund", "%@ 去不了", "%@ kan niet"),
    "fan_teams_remove_from_event_failed": tr("Couldn’t remove from event.", "No se pudo quitar del evento.", "Impossible de retirer de l’événement.", "Não foi possível remover do evento.", "Konnte nicht vom Event entfernt werden.", "Impossibile rimuovere dall’evento.", "Nie udało się usunąć z wydarzenia.", "Не удалось удалить из события.", "Nuk u hoq nga eventi.", "无法从活动中移除。", "Verwijderen uit event mislukt."),
    "fan_teams_add_back_to_event_failed": tr("Couldn’t add back to event.", "No se pudo volver a añadir al evento.", "Impossible de remettre dans l’événement.", "Não foi possível adicionar de volta ao evento.", "Konnte nicht wieder zum Event hinzugefügt werden.", "Impossibile riaggiungere all’evento.", "Nie udało się dodać z powrotem do wydarzenia.", "Не удалось вернуть в событие.", "Nuk u shtua sërish në event.", "无法重新加入活动。", "Weer toevoegen aan event mislukt."),
    "fan_teams_player_info_change_a11y": tr("Change player info", "Cambiar info del jugador", "Modifier les infos joueur", "Alterar info do jogador", "Spielerinfo ändern", "Cambia info giocatore", "Zmień dane zawodnika", "Изменить данные игрока", "Ndrysho info të lojtarit", "更改球员信息", "Spelerininfo wijzigen"),
})


def upsert_key(strings: dict, key: str, translations: dict[str, str], overwrite_empty_only: bool = True) -> None:
    entry = strings.get(key, {"extractionState": "manual", "localizations": {}})
    entry["extractionState"] = "manual"
    locs = entry.setdefault("localizations", {})
    for lang in SUPPORTED:
        value = translations.get(lang)
        if not value:
            continue
        existing = (locs.get(lang) or {}).get("stringUnit", {}).get("value")
        if existing and overwrite_empty_only:
            continue
        locs[lang] = unit(value)
    strings[key] = entry


def main() -> None:
    data = json.loads(XCSTRINGS.read_text(encoding="utf-8"))
    strings = data.setdefault("strings", {})
    inserted = 0
    filled_langs = 0
    for key, translations in ENTRIES.items():
        missing_langs = [lang for lang in SUPPORTED if lang not in translations]
        if missing_langs:
            raise SystemExit(f"{key} missing languages: {missing_langs}")
        existed = key in strings and bool(strings[key].get("localizations", {}).get("en", {}).get("stringUnit", {}).get("value"))
        upsert_key(strings, key, translations)
        if not existed:
            inserted += 1
        else:
            for lang in SUPPORTED:
                if lang in translations:
                    filled_langs += 1
    for key, nl_value in NL_FILL.items():
        entry = strings.get(key)
        if not entry:
            continue
        locs = entry.setdefault("localizations", {})
        existing = (locs.get("nl") or {}).get("stringUnit", {}).get("value")
        if not existing:
            locs["nl"] = unit(nl_value)
            filled_langs += 1
    XCSTRINGS.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"restored {inserted} missing keys; language fills={filled_langs}; catalog keys={len(strings)}")


if __name__ == "__main__":
    main()

