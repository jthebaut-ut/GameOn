#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import json
from pathlib import Path

path = Path(__file__).resolve().parent / "ui_hand_translations.json"
data = json.loads(path.read_text(encoding="utf-8"))


def setT(key, es, fr, pt, de, it, pl, ru, sq, zh):
    data[key] = {
        "es": es, "fr": fr, "pt": pt, "de": de, "it": it,
        "pl": pl, "ru": ru, "sq": sq, "zh-Hans": zh,
    }


setT("Business", "Negocio", "Entreprise", "Negócio", "Business", "Business", "Business", "Бизнес", "Biznes", "企业")
setT("Regular", "Regular", "Regular", "Regular", "Regular", "Regular", "Regular", "Regular", "Regular", "Regular")
setT(
    "Regular account • Ads may appear",
    "Cuenta Regular • Pueden aparecer anuncios",
    "Compte Regular • Des publicités peuvent s'afficher",
    "Conta Regular • Anúncios podem aparecer",
    "Regular-Konto • Werbung kann angezeigt werden",
    "Account Regular • Potrebbero apparire annunci",
    "Konto Regular • Mogą pojawiać się reklamy",
    "Аккаунт Regular • Может показываться реклама",
    "Llogari Regular • Mund të shfaqen reklama",
    "Regular 账户 • 可能会显示广告",
)
setT(
    "Regular business • Ads may appear",
    "Business Regular • Pueden aparecer anuncios",
    "Business Regular • Des publicités peuvent s'afficher",
    "Business Regular • Anúncios podem aparecer",
    "Business Regular • Werbung kann angezeigt werden",
    "Business Regular • Potrebbero apparire annunci",
    "Business Regular • Mogą pojawiać się reklamy",
    "Business Regular • Может показываться реклама",
    "Business Regular • Mund të shfaqen reklama",
    "Business Regular • 可能会显示广告",
)
setT("Contact FanGeo Support", "Contactar soporte de FanGeo", "Contacter le support FanGeo", "Contatar o suporte FanGeo", "FanGeo Support kontaktieren", "Contatta il supporto FanGeo", "Skontaktuj się z pomocą FanGeo", "Связаться с поддержкой FanGeo", "Kontakto mbështetjen FanGeo", "联系 FanGeo 客服")
setT("Contact Support", "Contactar soporte", "Contacter le support", "Contatar suporte", "Support kontaktieren", "Contatta il supporto", "Skontaktuj się z pomocą", "Связаться с поддержкой", "Kontakto mbështetjen", "联系客服")
setT("FanGeo Support", "Soporte FanGeo", "Support FanGeo", "Suporte FanGeo", "FanGeo Support", "Supporto FanGeo", "Pomoc FanGeo", "Поддержка FanGeo", "Mbështetja FanGeo", "FanGeo 客服")
setT("Support", "Soporte", "Support", "Suporte", "Support", "Supporto", "Pomoc", "Поддержка", "Mbështetje", "客服")
setT("Official Support Team", "Equipo oficial de soporte", "Équipe officielle du support", "Equipe oficial de suporte", "Offizielles Support-Team", "Team di supporto ufficiale", "Oficjalny zespół pomocy", "Официальная служба поддержки", "Ekipa zyrtare e mbështetjes", "官方客服团队")
setT("💬 Support Center", "💬 Centro de soporte", "💬 Centre d'assistance", "💬 Central de suporte", "💬 Support-Center", "💬 Centro assistenza", "💬 Centrum pomocy", "💬 Центр поддержки", "💬 Qendra e mbështetjes", "💬 客服中心")
setT("Pickup", "Pickup", "Pickup", "Pickup", "Pickup", "Pickup", "Pickup", "Пикап", "Pickup", "友谊赛")
setT("Create Pickup Game Here", "Crear pickup game aquí", "Créer un pickup game ici", "Criar pickup game aqui", "Pickup Game hier erstellen", "Crea un pickup game qui", "Utwórz pickup game tutaj", "Создать pickup game здесь", "Krijo pickup game këtu", "在此创建友谊赛")
setT("Pickup Organizer", "Organizador de pickup game", "Organisateur de pickup game", "Organizador de pickup game", "Pickup-Organisator", "Organizzatore pickup game", "Organizator pickup game", "Организатор pickup game", "Organizues i pickup game", "友谊赛组织者")
setT("Delete Your FanGeo Account", "Eliminar tu cuenta FanGeo", "Supprimer votre compte FanGeo", "Excluir sua conta FanGeo", "FanGeo-Konto löschen", "Elimina il tuo account FanGeo", "Usuń konto FanGeo", "Удалить аккаунт FanGeo", "Fshi llogarinë FanGeo", "删除 FanGeo 账户")
setT("Delete account permanently", "Eliminar cuenta permanentemente", "Supprimer le compte définitivement", "Excluir conta permanentemente", "Konto dauerhaft löschen", "Elimina account in modo permanente", "Usuń konto na stałe", "Удалить аккаунт навсегда", "Fshi llogarinë përgjithmonë", "永久删除账户")
setT(
    "This one-time choice is saved to your business account. You can upgrade to Business Pro to reactivate every approved venue.",
    "Esta elección única se guarda en tu cuenta empresarial. Puedes actualizar a Business Pro para reactivar cada local aprobado.",
    "Ce choix unique est enregistré sur votre compte professionnel. Passez à Business Pro pour réactiver chaque lieu approuvé.",
    "Esta escolha única é salva na sua conta empresarial. Faça upgrade para Business Pro para reativar cada local aprovado.",
    "Diese einmalige Auswahl wird in deinem Business-Konto gespeichert. Mit Business Pro kannst du jeden genehmigten Standort reaktivieren.",
    "Questa scelta una tantum viene salvata nel tuo account business. Passa a Business Pro per riattivare ogni locale approvato.",
    "Ten jednorazowy wybór jest zapisywany na koncie firmowym. Ulepsz do Business Pro, aby reaktywować każde zatwierdzone miejsce.",
    "Этот разовый выбор сохраняется в бизнес-аккаунте. Перейдите на Business Pro, чтобы реактивировать каждую одобренную площадку.",
    "Kjo zgjedhje njëherëshe ruhet në llogarinë e biznesit. Përmirëso në Business Pro për të riaktivizuar çdo vend të miratuar.",
    "此一次性选择会保存到你的企业账户。升级到 Business Pro 可重新激活每个已批准的场馆。",
)
setT("Business @handle", "Negocio @handle", "Entreprise @handle", "Negócio @handle", "Business @handle", "Business @handle", "Business @handle", "Бизнес @handle", "Biznes @handle", "企业 @handle")
setT("Business name", "Nombre del negocio", "Nom de l'entreprise", "Nome do negócio", "Geschäftsname", "Nome business", "Nazwa firmy", "Название бизнеса", "Emri i biznesit", "企业名称")
setT("Business venue • Pending review", "Local empresarial • Pendiente de revisión", "Lieu professionnel • En attente de validation", "Local empresarial • Aguardando revisão", "Business-Standort • Ausstehende Prüfung", "Locale business • In revisione", "Miejsce firmowe • Oczekuje na weryfikację", "Площадка бизнеса • На проверке", "Vendi i biznesit • Në pritje të shqyrtimit", "企业场馆 • 待审核")
setT("Business Tools", "Herramientas empresariales", "Outils professionnels", "Ferramentas empresariais", "Business-Tools", "Strumenti business", "Narzędzia firmowe", "Инструменты для бизнеса", "Mjetet e biznesit", "企业工具")
setT("Business Owners", "Propietarios de negocios", "Propriétaires d'entreprise", "Proprietários de negócios", "Geschäftsinhaber", "Titolari business", "Właściciele firm", "Владельцы бизнеса", "Pronarët e bizneseve", "企业主")
setT("Complete your business setup", "Completa la configuración de tu negocio", "Terminez la configuration de votre entreprise", "Conclua a configuração do seu negócio", "Business-Einrichtung abschließen", "Completa la configurazione business", "Dokończ konfigurację firmy", "Завершите настройку бизнеса", "Përfundo konfigurimin e biznesit", "完成企业设置")
setT("Your public business identity", "Tu identidad empresarial pública", "Votre identité professionnelle publique", "Sua identidade empresarial pública", "Deine öffentliche Business-Identität", "La tua identità business pubblica", "Twoja publiczna tożsamość firmowa", "Ваша публичная бизнес-идентичность", "Identiteti publik i biznesit", "你的公开企业身份")

path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(f"Patched priority entries in {path}")
