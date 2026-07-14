#!/usr/bin/env python3
"""Merge localization entries into GameOn/Localizable.xcstrings."""
from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
XCSTRINGS = ROOT / "GameOn" / "Localizable.xcstrings"
SUPPORTED = ["en", "es", "fr", "pt", "de", "it", "pl", "ru", "sq", "zh-Hans"]


def unit(value: str) -> dict:
    return {"stringUnit": {"state": "translated", "value": value}}


def locs_for(values: dict[str, str]) -> dict:
    return {lang: unit(values[lang]) for lang in SUPPORTED if lang in values}


# Semantic keys (snake_case) used via L10n.t(...)
SEMANTIC: dict[str, dict[str, str]] = {
    "business_venue_limit_reached": {
        "en": "You have reached the active venue limit for your current plan.",
        "es": "Has alcanzado el límite de locales activos de tu plan actual.",
        "fr": "Vous avez atteint la limite de lieux actifs de votre offre actuelle.",
        "pt": "Você atingiu o limite de locais ativos do seu plano atual.",
        "de": "Sie haben das Limit aktiver Standorte Ihres aktuellen Tarifs erreicht.",
        "it": "Hai raggiunto il limite di locali attivi del piano attuale.",
        "pl": "Osiągnięto limit aktywnych lokalizacji w obecnym planie.",
        "ru": "Вы достигли лимита активных площадок для текущего плана.",
        "sq": "Keni arritur kufirin e vendeve aktive për planin tuaj aktual.",
        "zh-Hans": "您已达到当前方案的活跃场馆上限。",
    },
    "business_hosted_game_limit_reached": {
        "en": "You’ve reached your hosted game cycle limit. Upgrade to FanGeo Pro for unlimited hosted games, or wait until your next reset.",
        "es": "Has alcanzado el límite del ciclo de partidos organizados. Actualiza a FanGeo Pro para partidos ilimitados o espera al próximo reinicio.",
        "fr": "Vous avez atteint la limite du cycle de matchs organisés. Passez à FanGeo Pro pour des matchs illimités, ou attendez la prochaine réinitialisation.",
        "pt": "Você atingiu o limite do ciclo de jogos organizados. Atualize para o FanGeo Pro para jogos ilimitados ou aguarde a próxima redefinição.",
        "de": "Sie haben das Limit für gehostete Spiele erreicht. Upgrade auf FanGeo Pro für unbegrenzte Spiele oder warten Sie auf die nächste Zurücksetzung.",
        "it": "Hai raggiunto il limite del ciclo di partite ospitate. Passa a FanGeo Pro per partite illimitate oppure attendi il prossimo reset.",
        "pl": "Osiągnięto limit cyklu organizowanych meczów. Przejdź na FanGeo Pro, aby mieć nieograniczoną liczbę meczów, lub poczekaj na następny reset.",
        "ru": "Вы достигли лимита цикла проводимых игр. Перейдите на FanGeo Pro для неограниченного числа игр или дождитесь следующего сброса.",
        "sq": "Keni arritur kufirin e ciklit të ndeshjeve të organizuara. Përmirësoni në FanGeo Pro për ndeshje të pakufizuara ose prisni rivendosjen e ardhshme.",
        "zh-Hans": "您已达到主办赛事周期上限。升级至 FanGeo Pro 可无限主办赛事，或等待下次重置。",
    },
    "business_plan_locked_venue_banner": {
        "en": "Some of your venues are locked because your business exceeds the free plan limit. Upgrade to FanGeo Pro to reactivate all locations.",
        "es": "Algunos de tus locales están bloqueados porque tu negocio supera el límite del plan gratuito. Actualiza a FanGeo Pro para reactivar todas las ubicaciones.",
        "fr": "Certains de vos lieux sont verrouillés car votre entreprise dépasse la limite du plan gratuit. Passez à FanGeo Pro pour réactiver tous les emplacements.",
        "pt": "Alguns dos seus locais estão bloqueados porque seu negócio excede o limite do plano gratuito. Atualize para o FanGeo Pro para reativar todos os locais.",
        "de": "Einige Ihrer Standorte sind gesperrt, weil Ihr Unternehmen das Limit des kostenlosen Plans überschreitet. Upgrade auf FanGeo Pro, um alle Standorte zu reaktivieren.",
        "it": "Alcuni dei tuoi locali sono bloccati perché la tua attività supera il limite del piano gratuito. Passa a FanGeo Pro per riattivare tutte le sedi.",
        "pl": "Niektóre lokalizacje są zablokowane, ponieważ firma przekroczyła limit planu bezpłatnego. Przejdź na FanGeo Pro, aby ponownie aktywować wszystkie miejsca.",
        "ru": "Некоторые площадки заблокированы, так как ваш бизнес превысил лимит бесплатного плана. Перейдите на FanGeo Pro, чтобы снова активировать все локации.",
        "sq": "Disa nga vendet tuaja janë të bllokuara sepse biznesi juaj e tejkalon kufirin e planit falas. Përmirësoni në FanGeo Pro për të riaktivizuar të gjitha vendet.",
        "zh-Hans": "部分场馆已被锁定，因为您的企业超出了免费方案限制。升级至 FanGeo Pro 可重新激活所有场馆。",
    },
    "business_plan_locked_venue_badge": {
        "en": "Plan locked",
        "es": "Plan bloqueado",
        "fr": "Plan verrouillé",
        "pt": "Plano bloqueado",
        "de": "Plan gesperrt",
        "it": "Piano bloccato",
        "pl": "Plan zablokowany",
        "ru": "План заблокирован",
        "sq": "Plan i bllokuar",
        "zh-Hans": "方案已锁定",
    },
    "business_plan_locked_venue_subtitle": {
        "en": "This venue is inactive under your current plan.",
        "es": "Este local está inactivo con tu plan actual.",
        "fr": "Ce lieu est inactif avec votre offre actuelle.",
        "pt": "Este local está inativo no seu plano atual.",
        "de": "Dieser Standort ist unter Ihrem aktuellen Tarif inaktiv.",
        "it": "Questo locale è inattivo con il piano attuale.",
        "pl": "Ta lokalizacja jest nieaktywna w Twoim obecnym planie.",
        "ru": "Эта площадка неактивна в рамках вашего текущего плана.",
        "sq": "Ky vend është joaktiv sipas planit tuaj aktual.",
        "zh-Hans": "该场馆在当前方案下未激活。",
    },
    "business_plan_locked_venue_hosted_game_blocked": {
        "en": "This venue is locked under the current business plan. Upgrade to FanGeo Pro to host games here.",
        "es": "Este local está bloqueado con el plan empresarial actual. Actualiza a FanGeo Pro para organizar partidos aquí.",
        "fr": "Ce lieu est verrouillé avec le plan professionnel actuel. Passez à FanGeo Pro pour organiser des matchs ici.",
        "pt": "Este local está bloqueado no plano empresarial atual. Atualize para o FanGeo Pro para organizar jogos aqui.",
        "de": "Dieser Standort ist im aktuellen Business-Plan gesperrt. Upgrade auf FanGeo Pro, um hier Spiele zu hosten.",
        "it": "Questo locale è bloccato con il piano business attuale. Passa a FanGeo Pro per ospitare partite qui.",
        "pl": "Ta lokalizacja jest zablokowana w bieżącym planie biznesowym. Przejdź na FanGeo Pro, aby organizować tu mecze.",
        "ru": "Эта площадка заблокирована в текущем бизнес-плане. Перейдите на FanGeo Pro, чтобы проводить здесь игры.",
        "sq": "Ky vend është i bllokuar në planin aktual të biznesit. Përmirësoni në FanGeo Pro për të organizuar ndeshje këtu.",
        "zh-Hans": "该场馆在当前企业方案下已被锁定。升级至 FanGeo Pro 即可在此主办赛事。",
    },
    "business_backend_compatibility_required": {
        "en": "FanGeo needs a quick update before this business feature can be used. Please update the app and try again.",
        "es": "FanGeo necesita una actualización rápida antes de usar esta función empresarial. Actualiza la app e inténtalo de nuevo.",
        "fr": "FanGeo a besoin d’une mise à jour rapide avant d’utiliser cette fonction professionnelle. Mettez l’app à jour et réessayez.",
        "pt": "O FanGeo precisa de uma atualização rápida antes de usar este recurso empresarial. Atualize o app e tente novamente.",
        "de": "FanGeo benötigt ein kurzes Update, bevor diese Business-Funktion genutzt werden kann. Bitte aktualisieren Sie die App und versuchen Sie es erneut.",
        "it": "FanGeo richiede un aggiornamento rapido prima di usare questa funzione business. Aggiorna l’app e riprova.",
        "pl": "FanGeo wymaga szybkiej aktualizacji, zanim można użyć tej funkcji biznesowej. Zaktualizuj aplikację i spróbuj ponownie.",
        "ru": "FanGeo нуждается в быстром обновлении, прежде чем можно будет использовать эту бизнес-функцию. Обновите приложение и попробуйте снова.",
        "sq": "FanGeo ka nevojë për një përditësim të shpejtë para se të përdoret kjo veçori biznesi. Përditësoni aplikacionin dhe provoni përsëri.",
        "zh-Hans": "使用此企业功能前，FanGeo 需要快速更新。请更新应用后重试。",
    },
    "business_unlimited_active_venues": {
        "en": "Unlimited active venues",
        "es": "Locales activos ilimitados",
        "fr": "Lieux actifs illimités",
        "pt": "Locais ativos ilimitados",
        "de": "Unbegrenzte aktive Standorte",
        "it": "Locali attivi illimitati",
        "pl": "Nieograniczona liczba aktywnych lokalizacji",
        "ru": "Неограниченное число активных площадок",
        "sq": "Vende aktive të pakufizuara",
        "zh-Hans": "无限活跃场馆",
    },
    "business_up_to_active_venues_format": {
        "en": "Up to %lld active venues",
        "es": "Hasta %lld locales activos",
        "fr": "Jusqu’à %lld lieux actifs",
        "pt": "Até %lld locais ativos",
        "de": "Bis zu %lld aktive Standorte",
        "it": "Fino a %lld locali attivi",
        "pl": "Do %lld aktywnych lokalizacji",
        "ru": "До %lld активных площадок",
        "sq": "Deri në %lld vende aktive",
        "zh-Hans": "最多 %lld 个活跃场馆",
    },
    "business_unlimited_hosted_games": {
        "en": "Unlimited hosted games",
        "es": "Partidos organizados ilimitados",
        "fr": "Matchs organisés illimités",
        "pt": "Jogos organizados ilimitados",
        "de": "Unbegrenzte gehostete Spiele",
        "it": "Partite ospitate illimitate",
        "pl": "Nieograniczona liczba organizowanych meczów",
        "ru": "Неограниченное число проводимых игр",
        "sq": "Ndeshje të organizuara të pakufizuara",
        "zh-Hans": "无限主办赛事",
    },
    "business_up_to_hosted_games_month_format": {
        "en": "Up to %lld hosted games per month",
        "es": "Hasta %lld partidos organizados al mes",
        "fr": "Jusqu’à %lld matchs organisés par mois",
        "pt": "Até %lld jogos organizados por mês",
        "de": "Bis zu %lld gehostete Spiele pro Monat",
        "it": "Fino a %lld partite ospitate al mese",
        "pl": "Do %lld organizowanych meczów miesięcznie",
        "ru": "До %lld проводимых игр в месяц",
        "sq": "Deri në %lld ndeshje të organizuara në muaj",
        "zh-Hans": "每月最多 %lld 场主办赛事",
    },
    "business_active_venues_count_format": {
        "en": "%d active venues",
        "es": "%d locales activos",
        "fr": "%d lieux actifs",
        "pt": "%d locais ativos",
        "de": "%d aktive Standorte",
        "it": "%d locali attivi",
        "pl": "%d aktywnych lokalizacji",
        "ru": "%d активных площадок",
        "sq": "%d vende aktive",
        "zh-Hans": "%d 个活跃场馆",
    },
    "business_hosted_games_count_month_format": {
        "en": "%d hosted games/month",
        "es": "%d partidos organizados/mes",
        "fr": "%d matchs organisés/mois",
        "pt": "%d jogos organizados/mês",
        "de": "%d gehostete Spiele/Monat",
        "it": "%d partite ospitate/mese",
        "pl": "%d organizowanych meczów/mies.",
        "ru": "%d проводимых игр/мес.",
        "sq": "%d ndeshje të organizuara/muaj",
        "zh-Hans": "每月 %d 场主办赛事",
    },
    "business_regular": {
        "en": "Regular Business",
        "es": "Negocio Regular",
        "fr": "Business standard",
        "pt": "Negócio Regular",
        "de": "Reguläres Business",
        "it": "Business Regular",
        "pl": "Zwykły Business",
        "ru": "Обычный бизнес",
        "sq": "Biznes i rregullt",
        "zh-Hans": "普通商家",
    },
    "business_pro": {
        "en": "Business Pro",
        "es": "Business Pro",
        "fr": "Business Pro",
        "pt": "Business Pro",
        "de": "Business Pro",
        "it": "Business Pro",
        "pl": "Business Pro",
        "ru": "Business Pro",
        "sq": "Business Pro",
        "zh-Hans": "Business Pro",
    },
    "business_pro_active": {
        "en": "Business Pro Active",
        "es": "Business Pro activo",
        "fr": "Business Pro actif",
        "pt": "Business Pro ativo",
        "de": "Business Pro aktiv",
        "it": "Business Pro attivo",
        "pl": "Business Pro aktywny",
        "ru": "Business Pro активен",
        "sq": "Business Pro aktiv",
        "zh-Hans": "Business Pro 已激活",
    },
    "business_launch_promotion_complimentary_access": {
        "en": "Launch Promotion (Complimentary Access)",
        "es": "Promoción de lanzamiento (acceso gratuito)",
        "fr": "Promotion de lancement (accès offert)",
        "pt": "Promoção de lançamento (acesso gratuito)",
        "de": "Launch-Aktion (kostenloser Zugang)",
        "it": "Promozione di lancio (accesso gratuito)",
        "pl": "Promocja startowa (bezpłatny dostęp)",
        "ru": "Стартовая акция (бесплатный доступ)",
        "sq": "Promovim lançimi (qasje falas)",
        "zh-Hans": "上线推广（免费访问）",
    },
    "business_expires_format": {
        "en": "Expires %@",
        "es": "Vence el %@",
        "fr": "Expire le %@",
        "pt": "Expira em %@",
        "de": "Läuft ab am %@",
        "it": "Scade il %@",
        "pl": "Wygasa %@",
        "ru": "Истекает %@",
        "sq": "Skadon më %@",
        "zh-Hans": "将于 %@ 到期",
    },
    "business_promotion_ends_format": {
        "en": "Promotion ends %@",
        "es": "La promoción termina el %@",
        "fr": "La promotion se termine le %@",
        "pt": "A promoção termina em %@",
        "de": "Aktion endet am %@",
        "it": "La promozione termina il %@",
        "pl": "Promocja kończy się %@",
        "ru": "Акция заканчивается %@",
        "sq": "Promovimi përfundon më %@",
        "zh-Hans": "推广将于 %@ 结束",
    },
    "business_pro_included_through_format": {
        "en": "Business Pro included through %@.",
        "es": "Business Pro incluido hasta el %@.",
        "fr": "Business Pro inclus jusqu’au %@.",
        "pt": "Business Pro incluído até %@.",
        "de": "Business Pro inklusive bis %@.",
        "it": "Business Pro incluso fino al %@.",
        "pl": "Business Pro w cenie do %@.",
        "ru": "Business Pro включён до %@.",
        "sq": "Business Pro përfshihet deri më %@.",
        "zh-Hans": "Business Pro 包含至 %@。",
    },
    "business_pro_promo_active_until_format": {
        "en": "Business Pro promo active until %@",
        "es": "Promoción Business Pro activa hasta el %@",
        "fr": "Promo Business Pro active jusqu’au %@",
        "pt": "Promoção Business Pro ativa até %@",
        "de": "Business-Pro-Aktion aktiv bis %@",
        "it": "Promo Business Pro attiva fino al %@",
        "pl": "Promocja Business Pro aktywna do %@",
        "ru": "Промо Business Pro активно до %@",
        "sq": "Promo Business Pro aktive deri më %@",
        "zh-Hans": "Business Pro 推广有效至 %@",
    },
    "business_apple_subscription": {
        "en": "Apple Subscription",
        "es": "Suscripción de Apple",
        "fr": "Abonnement Apple",
        "pt": "Assinatura Apple",
        "de": "Apple-Abonnement",
        "it": "Abbonamento Apple",
        "pl": "Subskrypcja Apple",
        "ru": "Подписка Apple",
        "sq": "Abonim Apple",
        "zh-Hans": "Apple 订阅",
    },
    "business_status_active": {
        "en": "active",
        "es": "activo",
        "fr": "actif",
        "pt": "ativo",
        "de": "aktiv",
        "it": "attivo",
        "pl": "aktywny",
        "ru": "активен",
        "sq": "aktiv",
        "zh-Hans": "活跃",
    },
    "business_account_deleted_title": {
        "en": "Business account deleted",
        "es": "Cuenta empresarial eliminada",
        "fr": "Compte professionnel supprimé",
        "pt": "Conta empresarial excluída",
        "de": "Business-Konto gelöscht",
        "it": "Account business eliminato",
        "pl": "Konto firmowe usunięte",
        "ru": "Бизнес-аккаунт удалён",
        "sq": "Llogaria e biznesit u fshi",
        "zh-Hans": "企业账户已删除",
    },
    "business_account_deleted_message": {
        "en": "This FanGeo business account has been permanently deleted and cannot be used. To request account reactivation, contact FanGeo Support.",
        "es": "Esta cuenta empresarial de FanGeo se eliminó permanentemente y no se puede usar. Para solicitar la reactivación, contacta con el soporte de FanGeo.",
        "fr": "Ce compte professionnel FanGeo a été définitivement supprimé et ne peut pas être utilisé. Pour demander une réactivation, contactez le support FanGeo.",
        "pt": "Esta conta empresarial do FanGeo foi excluída permanentemente e não pode ser usada. Para solicitar reativação, entre em contato com o suporte FanGeo.",
        "de": "Dieses FanGeo-Business-Konto wurde dauerhaft gelöscht und kann nicht verwendet werden. Für eine Reaktivierung wenden Sie sich an den FanGeo-Support.",
        "it": "Questo account business FanGeo è stato eliminato definitivamente e non può essere usato. Per richiedere la riattivazione, contatta il supporto FanGeo.",
        "pl": "To konto firmowe FanGeo zostało trwale usunięte i nie można go używać. Aby poprosić o reaktywację, skontaktuj się z pomocą FanGeo.",
        "ru": "Этот бизнес-аккаунт FanGeo был безвозвратно удалён и не может использоваться. Чтобы запросить повторную активацию, обратитесь в поддержку FanGeo.",
        "sq": "Kjo llogari biznesi FanGeo është fshirë përgjithmonë dhe nuk mund të përdoret. Për të kërkuar riaktivizim, kontaktoni mbështetjen FanGeo.",
        "zh-Hans": "此 FanGeo 企业账户已被永久删除，无法使用。如需申请重新激活，请联系 FanGeo 支持。",
    },
    "business_limit_reached": {
        "en": "Venue limit reached",
        "es": "Límite de locales alcanzado",
        "fr": "Limite de lieux atteinte",
        "pt": "Limite de locais atingido",
        "de": "Standortlimit erreicht",
        "it": "Limite locali raggiunto",
        "pl": "Osiągnięto limit lokalizacji",
        "ru": "Достигнут лимит площадок",
        "sq": "Kufiri i vendeve u arrit",
        "zh-Hans": "已达场馆上限",
    },
    "business_checking_plan_status": {
        "en": "Checking plan status…",
        "es": "Comprobando el estado del plan…",
        "fr": "Vérification du statut du plan…",
        "pt": "Verificando o status do plano…",
        "de": "Planstatus wird geprüft…",
        "it": "Verifica dello stato del piano…",
        "pl": "Sprawdzanie statusu planu…",
        "ru": "Проверка статуса плана…",
        "sq": "Duke kontrolluar statusin e planit…",
        "zh-Hans": "正在检查方案状态…",
    },
    "business_checking_access": {
        "en": "Checking access...",
        "es": "Comprobando acceso...",
        "fr": "Vérification de l’accès...",
        "pt": "Verificando acesso...",
        "de": "Zugriff wird geprüft...",
        "it": "Verifica dell’accesso...",
        "pl": "Sprawdzanie dostępu...",
        "ru": "Проверка доступа...",
        "sq": "Duke kontrolluar qasjen...",
        "zh-Hans": "正在检查访问权限...",
    },
    "business_pro_required": {
        "en": "Business Pro required",
        "es": "Se requiere Business Pro",
        "fr": "Business Pro requis",
        "pt": "Business Pro necessário",
        "de": "Business Pro erforderlich",
        "it": "Business Pro richiesto",
        "pl": "Wymagany Business Pro",
        "ru": "Требуется Business Pro",
        "sq": "Kërkohet Business Pro",
        "zh-Hans": "需要 Business Pro",
    },
    "business_limit_or_venue_locked": {
        "en": "Limit reached or venue locked",
        "es": "Límite alcanzado o local bloqueado",
        "fr": "Limite atteinte ou lieu verrouillé",
        "pt": "Limite atingido ou local bloqueado",
        "de": "Limit erreicht oder Standort gesperrt",
        "it": "Limite raggiunto o locale bloccato",
        "pl": "Osiągnięto limit lub lokalizacja zablokowana",
        "ru": "Лимит достигнут или площадка заблокирована",
        "sq": "Kufiri u arrit ose vendi është i bllokuar",
        "zh-Hans": "已达上限或场馆已锁定",
    },
    "analytics_access": {
        "en": "Analytics access",
        "es": "Acceso a analíticas",
        "fr": "Accès aux analyses",
        "pt": "Acesso a análises",
        "de": "Analytics-Zugang",
        "it": "Accesso alle analisi",
        "pl": "Dostęp do analityki",
        "ru": "Доступ к аналитике",
        "sq": "Qasje në analitikë",
        "zh-Hans": "分析功能访问",
    },
    "free_business_tools_for_sports_venues": {
        "en": "Free business tools for sports venues",
        "es": "Herramientas empresariales gratuitas para locales deportivos",
        "fr": "Outils professionnels gratuits pour lieux sportifs",
        "pt": "Ferramentas empresariais gratuitas para locais esportivos",
        "de": "Kostenlose Business-Tools für Sportstätten",
        "it": "Strumenti business gratuiti per locali sportivi",
        "pl": "Bezpłatne narzędzia biznesowe dla obiektów sportowych",
        "ru": "Бесплатные бизнес-инструменты для спортивных площадок",
        "sq": "Mjete falas biznesi për vende sportive",
        "zh-Hans": "面向体育场馆的免费企业工具",
    },
    "free_badge": {
        "en": "FREE",
        "es": "GRATIS",
        "fr": "GRATUIT",
        "pt": "GRÁTIS",
        "de": "KOSTENLOS",
        "it": "GRATIS",
        "pl": "BEZPŁATNY",
        "ru": "БЕСПЛАТНО",
        "sq": "FALAS",
        "zh-Hans": "免费",
    },
    "free_plan": {
        "en": "Free plan",
        "es": "Plan gratuito",
        "fr": "Plan gratuit",
        "pt": "Plano gratuito",
        "de": "Kostenloser Plan",
        "it": "Piano gratuito",
        "pl": "Plan bezpłatny",
        "ru": "Бесплатный план",
        "sq": "Plan falas",
        "zh-Hans": "免费方案",
    },
    "refreshing_entitlement": {
        "en": "Refreshing entitlement",
        "es": "Actualizando derechos",
        "fr": "Actualisation des droits",
        "pt": "Atualizando direitos",
        "de": "Berechtigung wird aktualisiert",
        "it": "Aggiornamento diritti",
        "pl": "Odświeżanie uprawnień",
        "ru": "Обновление прав",
        "sq": "Duke rifreskuar të drejtat",
        "zh-Hans": "正在刷新权益",
    },
    "business_account_deleted_success": {
        "en": "Business account deleted.",
        "es": "Cuenta empresarial eliminada.",
        "fr": "Compte professionnel supprimé.",
        "pt": "Conta empresarial excluída.",
        "de": "Business-Konto gelöscht.",
        "it": "Account business eliminato.",
        "pl": "Konto firmowe usunięte.",
        "ru": "Бизнес-аккаунт удалён.",
        "sq": "Llogaria e biznesit u fshi.",
        "zh-Hans": "企业账户已删除。",
    },
    "business_inactive_venue_selection_notice": {
        "en": "This venue is inactive on the Regular plan and cannot be managed until activated by FanGeo or Business Pro.",
        "es": "Este local está inactivo en el plan Regular y no se puede gestionar hasta que FanGeo o Business Pro lo active.",
        "fr": "Ce lieu est inactif sur le plan Regular et ne peut pas être géré tant qu’il n’est pas activé par FanGeo ou Business Pro.",
        "pt": "Este local está inativo no plano Regular e não pode ser gerenciado até ser ativado pelo FanGeo ou Business Pro.",
        "de": "Dieser Standort ist im Regular-Plan inaktiv und kann erst verwaltet werden, wenn FanGeo oder Business Pro ihn aktiviert.",
        "it": "Questo locale è inattivo sul piano Regular e non può essere gestito finché FanGeo o Business Pro non lo attiva.",
        "pl": "Ta lokalizacja jest nieaktywna w planie Regular i nie może być zarządzana, dopóki FanGeo lub Business Pro jej nie aktywuje.",
        "ru": "Эта площадка неактивна в плане Regular и не может управляться, пока FanGeo или Business Pro не активируют её.",
        "sq": "Ky vend është joaktiv në planin Regular dhe nuk mund të menaxhohet derisa të aktivizohet nga FanGeo ose Business Pro.",
        "zh-Hans": "该场馆在 Regular 方案下未激活，需由 FanGeo 或 Business Pro 激活后才能管理。",
    },
    "contact_support": {
        "en": "Contact Support",
        "es": "Contactar soporte",
        "fr": "Contacter le support",
        "pt": "Contatar suporte",
        "de": "Support kontaktieren",
        "it": "Contatta il supporto",
        "pl": "Skontaktuj się z pomocą",
        "ru": "Связаться с поддержкой",
        "sq": "Kontakto mbështetjen",
        "zh-Hans": "联系支持",
    },
    # Complete partial existing L10n keys
    "cancel": {
        "sq": "Anulo",
        "zh-Hans": "取消",
    },
    "close": {
        "sq": "Mbyll",
        "zh-Hans": "关闭",
    },
    "fan_updates": {
        "sq": "Përditësime për tifozët",
        "zh-Hans": "球迷动态",
    },
    "home_crowd": {
        "sq": "Tifozët e shtëpisë",
        "zh-Hans": "主场球迷",
    },
    "im_going": {
        "sq": "Po shkoj",
        "zh-Hans": "我要去",
    },
}


def is_ui_key(key: str) -> bool:
    if not key or len(key.strip()) < 2:
        return False
    if re.fullmatch(r"[\s\W\d]+", key):
        return False
    if key in {"@alexmorgan", "@fangeosports", "you@email.com"}:
        return False
    return True


def merge_key(strings: dict, key: str, values: dict[str, str]) -> None:
    if "en" not in values and key:
        values = {**values, "en": key}
    entry = strings.setdefault(key, {})
    locs = entry.setdefault("localizations", {})
    for lang in SUPPORTED:
        if lang not in values:
            continue
        locs[lang] = unit(values[lang])
    entry["extractionState"] = "manual"


def main() -> None:
    data = json.loads(XCSTRINGS.read_text(encoding="utf-8"))
    strings = data.setdefault("strings", {})

    added_keys = 0
    completed_locales = 0

    for key, values in SEMANTIC.items():
        before = set(strings.get(key, {}).get("localizations", {}).keys())
        merge_key(strings, key, values)
        after = set(strings.get(key, {}).get("localizations", {}).keys())
        if key not in before:
            added_keys += 1
        completed_locales += len(after - before)

    # Load optional bulk English-key translations
    bulk_paths = [
        Path(__file__).with_name("ui_translations_bulk.json"),
        Path(__file__).with_name("ui_hand_translations.json"),
    ]
    for bulk_path in bulk_paths:
        if not bulk_path.exists():
            continue
        bulk = json.loads(bulk_path.read_text(encoding="utf-8"))
        for key, values in bulk.items():
            if not is_ui_key(key):
                continue
            before = set(strings.get(key, {}).get("localizations", {}).keys())
            merge_key(strings, key, values)
            after = set(strings.get(key, {}).get("localizations", {}).keys())
            completed_locales += len(after - before)

    XCSTRINGS.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Semantic keys merged: {len(SEMANTIC)}")
    print(f"New semantic keys: {added_keys}")
    print(f"Locale entries added: {completed_locales}")


if __name__ == "__main__":
    main()
