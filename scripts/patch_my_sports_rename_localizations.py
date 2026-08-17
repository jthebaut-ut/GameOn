#!/usr/bin/env python3
"""Rename Going tab/feature copy to My Sports without rewriting the catalog."""
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
XCSTRINGS = ROOT / "GameOn" / "Localizable.xcstrings"
LANGS = ["de", "en", "es", "fr", "it", "nl", "pl", "pt", "ru", "sq", "zh-Hans"]

UPDATES: dict[str, dict[str, str]] = {
    "going_tab_subtitle": {
        "en": "Your personal sports hub.",
        "es": "Tu centro deportivo personal.",
        "fr": "Votre hub sportif personnel.",
        "pt": "Seu hub esportivo pessoal.",
        "de": "Dein persönlicher Sport-Hub.",
        "it": "Il tuo hub sportivo personale.",
        "pl": "Twój osobisty hub sportowy.",
        "ru": "Ваш личный спортивный хаб.",
        "sq": "Qendra juaj personale e sportit.",
        "zh-Hans": "你的个人体育中心。",
        "nl": "Jouw persoonlijke sporthub.",
    },
    "going_signed_out_title": {
        "en": "Sign in to use My Sports",
        "es": "Inicia sesión para usar Mis deportes",
        "fr": "Connectez-vous pour utiliser Mes sports",
        "pt": "Entre para usar Meus esportes",
        "de": "Melde dich an, um Mein Sport zu nutzen",
        "it": "Accedi per usare I miei sport",
        "pl": "Zaloguj się, aby korzystać z Mój sport",
        "ru": "Войдите, чтобы открыть «Мой спорт»",
        "sq": "Hyni për të përdorur Sportet e mia",
        "zh-Hans": "登录以使用“我的体育”",
        "nl": "Log in om Mijn sport te gebruiken",
    },
    "going_signed_out_body": {
        "en": "Your personal hub for games you play, watch, follow, and save.",
        "es": "Tu centro personal para lo que juegas, ves, sigues y guardas.",
        "fr": "Votre hub personnel pour ce que vous jouez, regardez, suivez et enregistrez.",
        "pt": "Seu hub pessoal para o que você joga, assiste, acompanha e salva.",
        "de": "Dein persönlicher Hub für Spiele, die du spielst, schaust, verfolgst und speicherst.",
        "it": "Il tuo hub personale per ciò che giochi, guardi, segui e salvi.",
        "pl": "Twój osobisty hub gier, które grasz, oglądasz, śledzisz i zapisujesz.",
        "ru": "Личный хаб для игр, которые вы играете, смотрите, отслеживаете и сохраняете.",
        "sq": "Qendra juaj personale për lojërat që luani, shikoni, ndiqni dhe ruani.",
        "zh-Hans": "你的个人中心，汇集你参与、观看、关注和收藏的赛事。",
        "nl": "Jouw persoonlijke hub voor wedstrijden die je speelt, kijkt, volgt en bewaart.",
    },
    "guide_going_primary": {
        "en": "Your personal sports hub.",
        "es": "Tu centro deportivo personal.",
        "fr": "Votre hub sportif personnel.",
        "pt": "Seu hub esportivo pessoal.",
        "de": "Dein persönlicher Sport-Hub.",
        "it": "Il tuo hub sportivo personale.",
        "pl": "Twój osobisty hub sportowy.",
        "ru": "Ваш личный спортивный хаб.",
        "sq": "Qendra juaj personale e sportit.",
        "zh-Hans": "你的个人体育中心。",
        "nl": "Jouw persoonlijke sporthub.",
    },
    "guide_going_body": {
        "en": "My Sports is everything you care about — pickup games, team events, watch parties, saved pro games, favorite teams, and favorite sports spots.",
        "es": "Mis deportes reúne lo que te importa: pickup, eventos de equipo, watch parties, partidos pro, equipos favoritos y spots deportivos.",
        "fr": "Mes sports rassemble ce qui vous tient à cœur : pickups, événements d’équipe, watch parties, matchs pro, équipes favorites et spots sportifs.",
        "pt": "Meus esportes reúne o que importa: peladas, eventos de equipe, watch parties, jogos pro, times favoritos e spots esportivos.",
        "de": "Mein Sport ist alles, was dir wichtig ist — Pickup-Spiele, Team-Events, Watch Parties, Profi-Spiele, Lieblingsteams und Sportspots.",
        "it": "I miei sport raccoglie ciò che ti interessa: pickup, eventi di squadra, watch party, partite pro, squadre preferite e spot sportivi.",
        "pl": "Mój sport to wszystko, na czym Ci zależy — gry pickup, wydarzenia zespołu, watch party, mecze pro, ulubione drużyny i miejsca sportowe.",
        "ru": "«Мой спорт» — всё важное: пикап-игры, события команды, вотч-пати, про-матчи, любимые команды и спортивные места.",
        "sq": "Sportet e mia është gjithçka që të intereson — ndeshje pickup, evente ekipi, watch parties, ndeshje pro, ekipe të preferuara dhe vende sportive.",
        "zh-Hans": "“我的体育”汇集你关心的一切：约战、队伍活动、观赛派对、收藏的职业赛事、喜爱的球队和运动地点。",
        "nl": "Mijn sport is alles wat je volgt — pickupwedstrijden, teamevents, watch parties, pro-wedstrijden, favoriete teams en sportplekken.",
    },
    "guide_going_bullet_1": {
        "en": "Games you're playing",
        "es": "Partidos que juegas",
        "fr": "Matchs auxquels vous jouez",
        "pt": "Jogos que você joga",
        "de": "Spiele, die du spielst",
        "it": "Partite che giochi",
        "pl": "Gry, w które grasz",
        "ru": "Игры, в которых вы участвуете",
        "sq": "Ndeshje që luani",
        "zh-Hans": "你正在参加的比赛",
        "nl": "Wedstrijden die je speelt",
    },
    "guide_going_bullet_2": {
        "en": "Games you're watching",
        "es": "Partidos que ves",
        "fr": "Matchs que vous regardez",
        "pt": "Jogos que você assiste",
        "de": "Spiele, die du schaust",
        "it": "Partite che guardi",
        "pl": "Mecze, które oglądasz",
        "ru": "Игры, которые вы смотрите",
        "sq": "Ndeshje që shikoni",
        "zh-Hans": "你正在观看的比赛",
        "nl": "Wedstrijden die je kijkt",
    },
    "guide_going_bullet_3": {
        "en": "Favorite teams",
        "es": "Equipos favoritos",
        "fr": "Équipes favorites",
        "pt": "Times favoritos",
        "de": "Lieblingsteams",
        "it": "Squadre preferite",
        "pl": "Ulubione drużyny",
        "ru": "Любимые команды",
        "sq": "Ekipet e preferuara",
        "zh-Hans": "喜爱的球队",
        "nl": "Favoriete teams",
    },
    "guide_going_bullet_4": {
        "en": "Saved pro games",
        "es": "Partidos pro guardados",
        "fr": "Matchs pro enregistrés",
        "pt": "Jogos profissionais salvos",
        "de": "Gespeicherte Profi-Spiele",
        "it": "Partite pro salvate",
        "pl": "Zapisane mecze pro",
        "ru": "Сохранённые про-матчи",
        "sq": "Ndeshje pro të ruajtura",
        "zh-Hans": "已保存的职业比赛",
        "nl": "Opgeslagen pro-wedstrijden",
    },
    "guide_going_hero_a11y": {
        "en": "My Sports hub illustration showing pickup games, team events, pro games, and favorite sports spots",
        "es": "Ilustración de Mis deportes con pickup, eventos de equipo, partidos pro y spots favoritos",
        "fr": "Illustration de Mes sports avec pickups, événements d’équipe, matchs pro et spots favoris",
        "pt": "Ilustração de Meus esportes com peladas, eventos de equipe, jogos pro e spots favoritos",
        "de": "Illustration von Mein Sport mit Pickup-Spielen, Team-Events, Profi-Spielen und Sportspots",
        "it": "Illustrazione di I miei sport con pickup, eventi di squadra, partite pro e spot preferiti",
        "pl": "Ilustracja Mój sport z grami pickup, wydarzeniami zespołu, meczami pro i miejscami sportowymi",
        "ru": "Иллюстрация «Мой спорт» с пикап-играми, событиями команды, про-матчами и любимыми местами",
        "sq": "Ilustrim i Sporteve të mia me ndeshje pickup, evente ekipi, ndeshje pro dhe vende sportive",
        "zh-Hans": "“我的体育”插图，展示约战、队伍活动、职业赛事和喜爱的运动地点",
        "nl": "Illustratie van Mijn sport met pickupwedstrijden, teamevents, pro-wedstrijden en favoriete sportplekken",
    },
    "guide_going_demo_event_1": {
        "en": "Pickup Soccer",
        "es": "Fútbol pickup",
        "fr": "Foot pickup",
        "pt": "Futebol pickup",
        "de": "Pickup-Fußball",
        "it": "Calcetto pickup",
        "pl": "Piłka pickup",
        "ru": "Пикап-футбол",
        "sq": "Futboll pickup",
        "zh-Hans": "约战足球",
        "nl": "Pickupvoetbal",
    },
    "guide_going_demo_detail_1": {
        "en": "Tonight • Play",
        "es": "Esta noche • Jugar",
        "fr": "Ce soir • Jouer",
        "pt": "Hoje à noite • Jogar",
        "de": "Heute Abend • Spielen",
        "it": "Stasera • Gioca",
        "pl": "Dziś wieczorem • Graj",
        "ru": "Сегодня вечером • Играть",
        "sq": "Sot në mbrëmje • Luaj",
        "zh-Hans": "今晚 • 参赛",
        "nl": "Vanavond • Spelen",
    },
    "guide_going_demo_event_2": {
        "en": "IMC Team Practice",
        "es": "Entrenamiento del equipo IMC",
        "fr": "Entraînement de l’équipe IMC",
        "pt": "Treino do time IMC",
        "de": "IMC Team-Training",
        "it": "Allenamento squadra IMC",
        "pl": "Trening zespołu IMC",
        "ru": "Тренировка команды IMC",
        "sq": "Stërvitje e ekipit IMC",
        "zh-Hans": "IMC 队伍训练",
        "nl": "IMC-teamtraining",
    },
    "guide_going_demo_detail_2": {
        "en": "This week • Team",
        "es": "Esta semana • Equipo",
        "fr": "Cette semaine • Équipe",
        "pt": "Esta semana • Equipe",
        "de": "Diese Woche • Team",
        "it": "Questa settimana • Squadra",
        "pl": "W tym tygodniu • Zespół",
        "ru": "На этой неделе • Команда",
        "sq": "Këtë javë • Ekip",
        "zh-Hans": "本周 • 队伍",
        "nl": "Deze week • Team",
    },
    "guide_going_demo_detail_3": {
        "en": "Pro game",
        "es": "Partido profesional",
        "fr": "Match pro",
        "pt": "Jogo profissional",
        "de": "Profi-Spiel",
        "it": "Partita pro",
        "pl": "Mecz pro",
        "ru": "Про-матч",
        "sq": "Ndeshje pro",
        "zh-Hans": "职业赛事",
        "nl": "Pro-wedstrijd",
    },
    "guide_going_demo_event_3": {
        "en": "Lakers vs Jazz",
        "es": "Lakers vs Jazz",
        "fr": "Lakers vs Jazz",
        "pt": "Lakers vs Jazz",
        "de": "Lakers vs Jazz",
        "it": "Lakers vs Jazz",
        "pl": "Lakers vs Jazz",
        "ru": "Lakers — Jazz",
        "sq": "Lakers vs Jazz",
        "zh-Hans": "湖人 vs 爵士",
        "nl": "Lakers vs Jazz",
    },
    "How far ahead Going should look for your teams.": {
        "en": "How far ahead My Sports should look for your teams.",
        "es": "Hasta cuándo Mis deportes debe buscar partidos de tus equipos.",
        "fr": "Jusqu'où Mes sports doit chercher les matchs de vos équipes.",
        "pt": "Até quando Meus esportes deve buscar jogos dos seus times.",
        "de": "Wie weit Mein Sport im Voraus nach Spielen deiner Teams suchen soll.",
        "it": "Quanto in anticipo I miei sport deve cercare le partite delle tue squadre.",
        "pl": "Jak daleko wprzód Mój sport ma szukać meczów Twoich drużyn.",
        "ru": "Насколько заранее «Мой спорт» должен искать матчи ваших команд.",
        "sq": "Sa përpara Sportet e mia duhet të kërkojë ndeshjet e ekipeve tuaja.",
        "zh-Hans": "“我的体育”应提前多久查找你的球队赛事。",
        "nl": "Hoe ver vooruit Mijn sport naar wedstrijden van je teams moet kijken.",
    },
    "action_center_going_badge_a11y": {
        "en": "%lld My Sports updates",
        "es": "%lld actualizaciones de Mis deportes",
        "fr": "%lld mises à jour Mes sports",
        "pt": "%lld atualizações de Meus esportes",
        "de": "%lld Mein-Sport-Updates",
        "it": "%lld aggiornamenti I miei sport",
        "pl": "%lld aktualizacji Mój sport",
        "ru": "%lld обновлений «Мой спорт»",
        "sq": "%lld përditësime Sportet e mia",
        "zh-Hans": "%lld 条“我的体育”更新",
        "nl": "%lld Mijn sport-updates",
    },
    "action_center_schedule_change_subtitle": {
        "en": "A game you’re part of changed. Open My Sports to review.",
        "es": "Un partido en el que participas cambió. Abre Mis deportes.",
        "fr": "Un match auquel vous participez a changé. Ouvrez Mes sports.",
        "pt": "Um jogo em que você participa mudou. Abra Meus esportes.",
        "de": "Ein Spiel, an dem du teilnimmst, hat sich geändert. Öffne Mein Sport.",
        "it": "Una partita a cui partecipi è cambiata. Apri I miei sport.",
        "pl": "Zmieniła się gra, w której bierzesz udział. Otwórz Mój sport.",
        "ru": "Игра, в которой вы участвуете, изменилась. Откройте «Мой спорт».",
        "sq": "Një lojë ku merr pjesë ndryshoi. Hap Sportet e mia.",
        "zh-Hans": "你参加的比赛有变更。打开“我的体育”查看。",
        "nl": "Een wedstrijd waar je bij hoort is gewijzigd. Open Mijn sport.",
    },
    "going_action_needed_row_a11y_hint": {
        "en": "Opens the related My Sports screen",
        "es": "Abre la pantalla de Mis deportes relacionada",
        "fr": "Ouvre l’écran Mes sports correspondant",
        "pt": "Abre a tela Meus esportes relacionada",
        "de": "Öffnet die passende Mein-Sport-Ansicht",
        "it": "Apre la schermata I miei sport correlata",
        "pl": "Otwiera powiązany ekran Mój sport",
        "ru": "Открывает связанный экран «Мой спорт»",
        "sq": "Hap ekranin Sportet e mia përkatës",
        "zh-Hans": "打开相关的“我的体育”页面",
        "nl": "Opent het bijbehorende Mijn sport-scherm",
    },
    "going_play_declined_request_caption": {
        "en": "The organizer declined this request. You can clear it from My Sports.",
        "es": "El organizador rechazó esta solicitud. Puedes quitarla de Mis deportes.",
        "fr": "L’organisateur a refusé cette demande. Vous pouvez la retirer de Mes sports.",
        "pt": "O organizador recusou este pedido. Você pode removê-lo de Meus esportes.",
        "de": "Der Organizer hat diese Anfrage abgelehnt. Du kannst sie aus Mein Sport entfernen.",
        "it": "L’organizzatore ha rifiutato questa richiesta. Puoi rimuoverla da I miei sport.",
        "pl": "Organizator odrzucił tę prośbę. Możesz usunąć ją z Mój sport.",
        "ru": "Организатор отклонил заявку. Её можно убрать из «Мой спорт».",
        "sq": "Organizatori e refuzoi këtë kërkesë. Mund ta heqësh nga Sportet e mia.",
        "zh-Hans": "组织者拒绝了此请求。你可以从“我的体育”中清除。",
        "nl": "De organisator wees dit verzoek af. Je kunt het uit Mijn sport verwijderen.",
    },
    "pickup_playing_auto_clears_on_a11y_format": {
        "en": "This completed game automatically clears from My Sports on %@",
        "es": "Este partido completado se elimina automáticamente de Mis deportes el %@",
        "fr": "Cette partie terminée disparaîtra automatiquement de Mes sports le %@",
        "pt": "Este jogo concluído será removido automaticamente de Meus esportes em %@",
        "de": "Dieses abgeschlossene Spiel wird am %@ automatisch aus Mein Sport entfernt",
        "it": "Questa partita completata verrà rimossa automaticamente da I miei sport il %@",
        "pl": "Ta zakończona gra zostanie automatycznie usunięta z Mój sport %@",
        "ru": "Эта завершённая игра автоматически исчезнет из «Мой спорт» %@",
        "sq": "Kjo lojë e përfunduar hiqet automatikisht nga Sportet e mia më %@",
        "zh-Hans": "此已结束的比赛将于 %@ 自动从“我的体育”中清除",
        "nl": "Deze afgeronde wedstrijd verdwijnt automatisch uit Mijn sport op %@",
    },
    "pickup_playing_clear_confirm_rated_message": {
        "en": "This removes the game only from your My Sports list.",
        "es": "Esto solo elimina el partido de tu lista de Mis deportes.",
        "fr": "Cela retire la partie uniquement de votre liste Mes sports.",
        "pt": "Isso remove o jogo apenas da sua lista Meus esportes.",
        "de": "Dadurch wird das Spiel nur aus deiner Mein-Sport-Liste entfernt.",
        "it": "Questo rimuove la partita solo dalla tua lista I miei sport.",
        "pl": "Usuwa grę tylko z Twojej listy Mój sport.",
        "ru": "Игра будет удалена только из списка «Мой спорт».",
        "sq": "Kjo e heq lojën vetëm nga lista Sportet e mia.",
        "zh-Hans": "这只会从“我的体育”列表中移除该比赛。",
        "nl": "Dit verwijdert de wedstrijd alleen uit je Mijn sport-lijst.",
    },
    "pickup_playing_clear_confirm_unrated_message": {
        "en": "You can still rate the organizer before removing this game. This removes the game only from your My Sports list.",
        "es": "Aún puedes valorar al organizador antes de quitar este partido. Solo se elimina de tu lista de Mis deportes.",
        "fr": "Vous pouvez encore noter l’organisateur avant de retirer cette partie. Elle disparaît seulement de votre liste Mes sports.",
        "pt": "Você ainda pode avaliar o organizador antes de remover este jogo. Isso remove o jogo apenas da sua lista Meus esportes.",
        "de": "Du kannst den Organisator noch bewerten, bevor du dieses Spiel entfernst. Es wird nur aus deiner Mein-Sport-Liste entfernt.",
        "it": "Puoi ancora valutare l’organizzatore prima di rimuovere questa partita. Viene rimossa solo dalla tua lista I miei sport.",
        "pl": "Nadal możesz ocenić organizatora przed usunięciem tej gry. Usunie to grę tylko z Twojej listy Mój sport.",
        "ru": "Вы всё ещё можете оценить организатора, прежде чем убрать игру. Она исчезнет только из списка «Мой спорт».",
        "sq": "Mund ta vlerësosh ende organizatorin para se ta heqësh këtë lojë. Hiqet vetëm nga lista Sportet e mia.",
        "zh-Hans": "移除前仍可评价组织者。这只会从“我的体育”列表中移除该比赛。",
        "nl": "Je kunt de organisator nog beoordelen voordat je deze wedstrijd verwijdert. Dit haalt de wedstrijd alleen uit je Mijn sport-lijst.",
    },
    "pickup_playing_clear_from_going": {
        "en": "Clear from My Sports",
        "es": "Quitar de Mis deportes",
        "fr": "Retirer de Mes sports",
        "pt": "Remover de Meus esportes",
        "de": "Aus Mein Sport entfernen",
        "it": "Rimuovi da I miei sport",
        "pl": "Usuń z Mój sport",
        "ru": "Убрать из «Мой спорт»",
        "sq": "Hiqe nga Sportet e mia",
        "zh-Hans": "从“我的体育”清除",
        "nl": "Verwijderen uit Mijn sport",
    },
    "Pickup activity is waiting in Going.": {
        "en": "Pickup activity is waiting in My Sports.",
        "es": "Hay actividad de pickup esperando en Mis deportes.",
        "fr": "Une activité pickup vous attend dans Mes sports.",
        "pt": "Há atividade de pickup aguardando em Meus esportes.",
        "de": "Pickup-Aktivität wartet in Mein Sport.",
        "it": "C’è attività pickup in attesa in I miei sport.",
        "pl": "Aktywność pickup czeka w Mój sport.",
        "ru": "Активность пикапа ждёт в «Мой спорт».",
        "sq": "Aktiviteti pickup po pret te Sportet e mia.",
        "zh-Hans": "“我的体育”中有待处理的约战动态。",
        "nl": "Pickupactiviteit wacht in Mijn sport.",
    },
    "Show upcoming Pro Games involving your favorite teams in Going.": {
        "en": "Show upcoming Pro Games involving your favorite teams in My Sports.",
        "es": "Mostrar en Mis deportes los próximos partidos profesionales de tus equipos favoritos.",
        "fr": "Afficher dans Mes sports les prochains matchs professionnels de vos équipes favorites.",
        "pt": "Mostrar em Meus esportes os próximos jogos profissionais dos seus times favoritos.",
        "de": "Zeige bevorstehende Profi-Spiele deiner Lieblingsteams unter Mein Sport.",
        "it": "Mostra in I miei sport i prossimi match professionistici delle tue squadre preferite.",
        "pl": "Pokazuj nadchodzące mecze pro ulubionych drużyn w Mój sport.",
        "ru": "Показывать ближайшие про-матчи любимых команд в «Мой спорт».",
        "sq": "Shfaq ndeshjet pro të ardhshme të ekipeve të preferuara te Sportet e mia.",
        "zh-Hans": "在“我的体育”中显示你喜爱球队的即将到来的职业赛事。",
        "nl": "Toon aankomende pro-wedstrijden van je favoriete teams in Mijn sport.",
    },
    "Use your Account tab to sign in, then open Going again.": {
        "en": "Use your Account tab to sign in, then open My Sports again.",
        "es": "Usa la pestaña Cuenta para iniciar sesión y vuelve a abrir Mis deportes.",
        "fr": "Utilisez l’onglet Compte pour vous connecter, puis rouvrez Mes sports.",
        "pt": "Use a aba Conta para entrar e abra Meus esportes novamente.",
        "de": "Melde dich über den Konto-Tab an und öffne Mein Sport erneut.",
        "it": "Usa la scheda Account per accedere, poi apri di nuovo I miei sport.",
        "pl": "Użyj karty Konto, aby się zalogować, a następnie otwórz ponownie Mój sport.",
        "ru": "Войдите через вкладку «Аккаунт», затем снова откройте «Мой спорт».",
        "sq": "Përdor skedën Llogari për t’u futur, pastaj hap sërish Sportet e mia.",
        "zh-Hans": "使用“账户”标签登录，然后再次打开“我的体育”。",
        "nl": "Log in via het Account-tabblad en open Mijn sport opnieuw.",
    },
}

INSERTS: dict[str, dict[str, str]] = {
    "going_tab_title": {
        "en": "My Sports",
        "es": "Mis deportes",
        "fr": "Mes sports",
        "pt": "Meus esportes",
        "de": "Mein Sport",
        "it": "I miei sport",
        "pl": "Mój sport",
        "ru": "Мой спорт",
        "sq": "Sportet e mia",
        "zh-Hans": "我的体育",
        "nl": "Mijn sport",
    },
    "guide_going_bullet_5": {
        "en": "Favorite sports spots",
        "es": "Spots deportivos favoritos",
        "fr": "Spots sportifs favoris",
        "pt": "Spots esportivos favoritos",
        "de": "Lieblings-Sportspots",
        "it": "Spot sportivi preferiti",
        "pl": "Ulubione miejsca sportowe",
        "ru": "Любимые спортивные места",
        "sq": "Vendet sportive të preferuara",
        "zh-Hans": "喜爱的运动地点",
        "nl": "Favoriete sportplekken",
    },
    "guide_going_demo_event_4": {
        "en": "Favorite Sports Bar",
        "es": "Bar deportivo favorito",
        "fr": "Bar sportif favori",
        "pt": "Bar esportivo favorito",
        "de": "Lieblings-Sportsbar",
        "it": "Sports bar preferito",
        "pl": "Ulubiony sports bar",
        "ru": "Любимый спортбар",
        "sq": "Sports bar i preferuar",
        "zh-Hans": "喜爱的体育酒吧",
        "nl": "Favoriete sportsbar",
    },
    "guide_going_demo_detail_4": {
        "en": "Watch spot",
        "es": "Spot para ver",
        "fr": "Spot pour regarder",
        "pt": "Spot para assistir",
        "de": "Watch Spot",
        "it": "Watch spot",
        "pl": "Watch spot",
        "ru": "Watch spot",
        "sq": "Watch spot",
        "zh-Hans": "观赛地点",
        "nl": "Watch spot",
    },
    "saved_to_my_sports": {
        "en": "Saved to My Sports.",
        "es": "Guardado en Mis deportes.",
        "fr": "Enregistré dans Mes sports.",
        "pt": "Salvo em Meus esportes.",
        "de": "In Mein Sport gespeichert.",
        "it": "Salvato in I miei sport.",
        "pl": "Zapisano w Mój sport.",
        "ru": "Сохранено в «Мой спорт».",
        "sq": "U ruajt te Sportet e mia.",
        "zh-Hans": "已保存到“我的体育”。",
        "nl": "Opgeslagen in Mijn sport.",
    },
    "removed_from_my_sports": {
        "en": "Removed from My Sports",
        "es": "Eliminado de Mis deportes",
        "fr": "Retiré de Mes sports",
        "pt": "Removido de Meus esportes",
        "de": "Aus Mein Sport entfernt",
        "it": "Rimosso da I miei sport",
        "pl": "Usunięto z Mój sport",
        "ru": "Удалено из «Мой спорт»",
        "sq": "U hoq nga Sportet e mia",
        "zh-Hans": "已从“我的体育”移除",
        "nl": "Verwijderd uit Mijn sport",
    },
}


def unit_block(translations: dict[str, str]) -> str:
    parts = []
    for lang in LANGS:
        value = translations.get(lang, translations["en"])
        escaped = value.replace("\\", "\\\\").replace('"', '\\"')
        parts.append(
            f'''        "{lang}": {{
          "stringUnit": {{
            "state": "translated",
            "value": "{escaped}"
          }}
        }}'''
        )
    return ",\n".join(parts)


def entry_block(key: str, translations: dict[str, str]) -> str:
    escaped_key = key.replace("\\", "\\\\").replace('"', '\\"')
    return f'''    "{escaped_key}": {{
      "extractionState": "manual",
      "localizations": {{
{unit_block(translations)}
      }}
    }},
'''


def find_key_start(text: str, key: str) -> int:
    for marker in (f'    "{key}": {{', f'    "{key}" : {{'):
        start = text.find(marker)
        if start >= 0:
            return start
    return -1


def replace_object(text: str, key: str, translations: dict[str, str]) -> str | None:
    start = find_key_start(text, key)
    if start < 0:
        return None
    brace = text.find("{", start)
    depth = 0
    end = None
    for i, ch in enumerate(text[brace:], brace):
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                end = i + 1
                break
    if end is None:
        raise SystemExit(f"unclosed key {key}")
    replacement = entry_block(key, translations).rstrip("\n")
    if replacement.endswith(","):
        replacement = replacement[:-1]
    return text[:start] + replacement + text[end:]


def main() -> None:
    text = XCSTRINGS.read_text(encoding="utf-8")
    missing_updates: list[str] = []
    for key, translations in UPDATES.items():
        updated = replace_object(text, key, translations)
        if updated is None:
            missing_updates.append(key)
            print(f"missing update {key} -> insert")
            continue
        text = updated
        print(f"updated {key}")
    for key in missing_updates:
        INSERTS.setdefault(key, UPDATES[key])

    needle = None
    for candidate in ('    "going_tab_subtitle": {', '    "going_tab_subtitle" : {'):
        if candidate in text:
            needle = candidate
            break
    if needle is None:
        raise SystemExit("needle going_tab_subtitle not found")
    block = ""
    inserted = 0
    for key, translations in INSERTS.items():
        if find_key_start(text, key) >= 0:
            print(f"skip insert {key}")
            continue
        block += entry_block(key, translations)
        inserted += 1
    if block:
        text = text.replace(needle, block + needle, 1)
    XCSTRINGS.write_text(text, encoding="utf-8")
    print(f"inserted {inserted} My Sports keys")


if __name__ == "__main__":
    main()
