#!/usr/bin/env python3
"""Write native legal translations for FanGeo in-app policy documents.

Each language is defined as four ordered lists (privacyPolicy, termsOfService,
communityGuidelines, safetyReporting) of (heading, body) tuples that mirror the
English source (legal_en.json) section-for-section, preserving bullet lists and
paragraph breaks.
"""

import json
import os

OUT_DIR = "/Users/jthebaut/Desktop/GameOn_RECOVERY_FINAL/GameOn/GameOn/LegalDocuments"

DOC_KEYS = ["privacyPolicy", "termsOfService", "communityGuidelines", "safetyReporting"]


def build(last_updated, pp, tos, cg, sr):
    def sections(pairs):
        return [{"heading": h, "body": b} for (h, b) in pairs]

    return {
        "lastUpdatedLabel": last_updated,
        "documents": {
            "privacyPolicy": sections(pp),
            "termsOfService": sections(tos),
            "communityGuidelines": sections(cg),
            "safetyReporting": sections(sr),
        },
    }


LANGUAGES = {}

# ---------------------------------------------------------------------------
# SPANISH (es)
# ---------------------------------------------------------------------------
LANGUAGES["es"] = build(
    "Última actualización: 18 de junio de 2026",
    # privacyPolicy
    [
        ("Descripción general",
         "Esta Política de Privacidad explica cómo FanGeo recopila, usa, comparte y conserva la información cuando utilizas la aplicación FanGeo."),
        ("Datos de la cuenta y del perfil",
         "Recopilamos la información que proporcionas o creas para tu cuenta, como la dirección de correo electrónico, el nombre visible, el nombre de usuario, la biografía, el avatar, los identificadores de autenticación, los equipos favoritos, los locales guardados, los partidos guardados, las señales de asistencia o interés, las preferencias de notificaciones, la configuración de visibilidad en vivo, los bloqueos, los reportes y datos de perfil o preferencias similares."),
        ("Ubicación y descubrimiento",
         "FanGeo puede usar la ubicación de tu dispositivo, la región del mapa, la ciudad buscada o la ubicación de un local para mostrarte bares deportivos cercanos, partidos, actividad de partidos improvisados y actividad local de aficionados. Puedes controlar el acceso a la ubicación del dispositivo en los Ajustes de iOS. Las fichas de locales y negocios pueden incluir direcciones, coordenadas, fotos, horarios, datos de contacto e información de reclamación o titularidad enviada por los propietarios de los locales."),
        ("Mensajes, Fan Chats y contenido de usuarios",
         "FanGeo procesa contenido generado por los usuarios, como mensajes directos, conversaciones privadas, Fan Chats, comentarios, publicaciones sobre locales o eventos, fotos, reportes y metadatos relacionados, para que la aplicación pueda entregar las conversaciones, conservar el contexto de los hilos, hacer cumplir las reglas de seguridad, investigar abusos y mantener la integridad del servicio."),
        ("Reportes y moderación",
         "Cuando reportas a un usuario, un comentario, un mensaje, una conversación, un local u otro contenido, procesamos tu reporte, el motivo seleccionado, los detalles opcionales, el contenido reportado, el contexto del mensaje o de la conversación cuando se admite, las marcas de tiempo, los identificadores de cuenta y el estado de moderación. Los registros de moderación pueden conservarse para proteger a los usuarios, hacer cumplir las reglas y cumplir con obligaciones legales o de la App Store."),
        ("Anuncios, análisis y diagnósticos",
         "FanGeo usa Google AdMob para mostrar anuncios. AdMob puede recibir información sobre el dispositivo, la interacción con los anuncios, la ubicación aproximada y el identificador de publicidad según la configuración de tu dispositivo y tus opciones de consentimiento. FanGeo también puede usar diagnósticos de la aplicación, registros, datos de rendimiento e información relacionada con fallos para depurar, prevenir abusos y mejorar la fiabilidad. Los registros de depuración están destinados a operaciones y pruebas, no a la venta de información personal."),
        ("Servicios de terceros",
         "FanGeo se apoya en proveedores de servicios como Supabase para la autenticación, la base de datos, el almacenamiento, las funciones en tiempo real y las funciones edge; Google AdMob para los anuncios; los servicios de la plataforma de Apple; y proveedores de datos deportivos como TheSportsDB para los calendarios y los datos de partidos en directo. Estos proveedores procesan los datos según sea necesario para prestar sus servicios."),
        ("Eliminación de la cuenta",
         "Al eliminar tu cuenta se eliminan o se anonimizan tu perfil público y tus preferencias personales. Algunos mensajes, comentarios, reportes y registros de moderación pueden conservarse y mostrarse como «Deleted User» para preservar la integridad de las conversaciones, la seguridad y los registros legales o de cumplimiento. Las cuentas eliminadas no pueden volver a iniciar sesión, a menos que el soporte de FanGeo restaure o reactive la cuenta."),
        ("Conservación de datos",
         "Conservamos los datos de la cuenta y de la aplicación mientras sea necesario para operar FanGeo, ofrecer las funciones solicitadas, prevenir abusos, resolver disputas, cumplir con la ley y mantener registros de seguridad. Los plazos de conservación varían según el tipo de dato. El contenido público o compartido puede permanecer tras la eliminación cuando sea necesario para preservar conversaciones, reportes, historial de moderación, registros de locales, reclamaciones de negocios o registros legales o de cumplimiento."),
        ("Contacto",
         "Para preguntas sobre privacidad o eliminación, escribe a support@fangeosports.com o utiliza el canal de soporte disponible en la aplicación."),
    ],
    # termsOfService
    [
        ("Descripción general",
         "Estos Términos de Servicio rigen tu uso de FanGeo. Al usar la aplicación, crear una cuenta, publicar contenido, enviar mensajes, presentar reportes, reclamar un local o gestionar la ficha de un negocio, aceptas cumplir estos términos."),
        ("Normas de la comunidad y uso aceptable",
         "FanGeo tiene tolerancia cero con el contenido objetable o los usuarios abusivos. Los usuarios no pueden publicar, subir, enviar ni compartir contenido que incluya acoso, discurso de odio, amenazas, intimidación, explotación sexual, contenido ilegal, spam, suplantación de identidad, comportamiento abusivo u otro material objetable.\n\nLos usuarios pueden reportar contenido objetable o usuarios abusivos en la aplicación. FanGeo puede eliminar contenido, restringir el acceso, suspender cuentas o cancelar permanentemente las cuentas que infrinjan estos Términos o las Normas de la Comunidad."),
        ("Uso aceptable",
         "Usa FanGeo únicamente con fines lícitos, personales y legítimos relacionados con las fichas de negocios. No hagas un uso indebido del servicio, ni envíes spam, ni realices scraping, rastreo o recolección de datos, ni manipules la asistencia o las valoraciones, ni interfieras con la seguridad de la aplicación, ni eludas los controles de acceso, ni intentes acceder a cuentas, mensajes, reportes, herramientas de administración, herramientas de locales o datos que no estés autorizado a usar."),
        ("Contenido del usuario",
         "Eres responsable del contenido que creas, subes, envías o presentas, incluidos los datos de perfil, los avatares, los Fan Chats, los mensajes directos, los reportes, la actividad de partidos improvisados, las fotos de locales, la información de negocios y los calendarios de partidos de los locales. Conservas tus derechos de propiedad, pero otorgas a FanGeo permiso para alojar, mostrar, almacenar, moderar, reproducir y distribuir tu contenido según sea necesario para operar, mejorar y proteger el servicio."),
        ("Sin acoso ni conductas inseguras",
         "La rivalidad deportiva y el debate apasionado son bienvenidos. No se permiten el acoso, las amenazas, el discurso de odio, el doxxing, la explotación sexual, el abuso dirigido, la suplantación de identidad, el acecho, las estafas ni el fomento de comportamientos ilegales o inseguros. No uses FanGeo para organizar encuentros inseguros ni para presionar a los usuarios a compartir información privada."),
        ("Reclamaciones de locales y negocios",
         "Si reclamas o gestionas un local, una cuenta de negocio o una ubicación, confirmas que estás autorizado para hacerlo y que la información que envías es precisa. FanGeo puede revisar, rechazar, aprobar, archivar, eliminar o limitar las reclamaciones o fichas de locales y negocios que sean inexactas, fraudulentas, duplicadas, inseguras, inactivas o que infrinjan estos términos."),
        ("Moderación y aplicación",
         "FanGeo puede revisar reportes, eliminar u ocultar contenido, restringir funciones, bloquear el acceso, suspender cuentas, eliminar cuentas, conservar registros o tomar otras medidas cuando consideremos que se han infringido estos términos, las Normas de la Comunidad, las reglas de seguridad, la ley o los requisitos de la App Store. También podemos conservar contenido o registros cuando sea necesario por motivos de seguridad, cumplimiento, resolución de disputas o razones legales."),
        ("Limitaciones de la aplicación",
         "FanGeo se ofrece «tal cual» en la medida en que lo permita la ley. No garantizamos un servicio ininterrumpido, datos exactos de los locales, calendarios deportivos completos, disponibilidad de anuncios, resultados de los reportes ni que todos los usuarios o locales actúen de forma segura. Las funciones pueden cambiar, limitarse o descontinuarse."),
    ],
    # communityGuidelines
    [
        ("La rivalidad deportiva está bien; el abuso no",
         "Anima con fuerza, debate sobre los equipos y burlate del marcador, pero no ataques a las personas con acoso, amenazas, discurso de odio, insultos, intimidación, acecho, comentarios sexuales o contacto no deseado repetido."),
        ("No está permitido",
         "- Acoso, intimidación, amenazas o abuso dirigido\n- Discurso de odio, racismo, insultos o discriminación\n- Doxxing, compartir información privada o presionar a los usuarios para que revelen datos personales\n- Suplantar a usuarios, locales, equipos, ligas, FanGeo o figuras públicas\n- Spam, estafas, phishing, promociones falsas, scraping o publicaciones disruptivas repetidas\n- Comportamiento inseguro en encuentros, coacción, acecho o incitación a la violencia o a actos ilegales\n- Explotación sexual, contenido explícito o contenido que involucre a menores"),
        ("Fan Chats y comentarios",
         "Mantén los Fan Chats y los comentarios sobre locales o eventos útiles para la afición deportiva local. No desvíes los hilos con spam, ataques personales, información falsa sobre locales o abuso coordinado. Los comentarios pueden ocultarse, eliminarse o revisarse cuando se reporten o cuando parezcan infringir estas normas."),
        ("DMs e interacciones entre amigos",
         "Los mensajes directos son para conversar con respeto con personas que aceptaron una conexión de amistad. No envíes mensajes abusivos, amenazantes, sexuales, fraudulentos, de spam o no deseados de forma repetida. Si alguien te pide que pares, para."),
        ("Reportar y bloquear",
         "Reporta a los usuarios, comentarios, mensajes o conversaciones abusivas usando las herramientas de reporte de la aplicación cuando estén disponibles. Bloquea a los usuarios que no deberían contactarte. Los reportes ayudan a FanGeo a revisar los problemas de seguridad, pero deben ser veraces y hacerse de buena fe."),
        ("Aplicación de las normas",
         "FanGeo puede advertir a los usuarios, eliminar contenido, ocultar comentarios, restringir la mensajería, suspender cuentas, eliminar cuentas, conservar reportes o tomar otras medidas según la gravedad, el contexto y la reincidencia."),
        ("Tu acuerdo",
         "Al usar FanGeo, aceptas seguir estas normas y ayudar a mantener una comunidad deportiva respetuosa."),
    ],
    # safetyReporting
    [
        ("Descripción general",
         "Tu seguridad importa. FanGeo ofrece herramientas de reporte y bloqueo para comportamientos abusivos, UGC, DMs, Fan Chats, comentarios, conversaciones y problemas relacionados con locales cuando se admiten en la aplicación. Los reportes se revisan conforme a las Normas de la Comunidad de FanGeo."),
        ("Qué puedes reportar",
         "Usa las acciones de reporte o marcado dentro de la aplicación cuando estén disponibles, incluidos los reportes de usuarios, los comentarios de Fan Chats, los mensajes directos, las conversaciones, las fichas de locales y el contenido de locales o eventos. Detalles claros y precisos ayudan a los moderadores a entender lo ocurrido."),
        ("Comentarios y novedades de la afición",
         "Cada usuario puede tener un reporte activo por comentario. Puedes retirar un reporte accidental tocando de nuevo la bandera roja antes de que se apliquen los umbrales. Varios reportes activos únicos pueden provocar la ocultación automática de la vista pública mientras se revisa el contenido. Si un comentario ya se ocultó automáticamente, retirar un reporte no lo restaura de forma automática."),
        ("Reporte de conversaciones privadas",
         "Desde un chat directo, puedes reportar la conversación o el contenido de mensajes admitido para su revisión por un moderador. Los reportes de DMs pueden incluir únicamente la ventana de revisión seleccionada, junto con los metadatos relacionados necesarios para evaluar el reporte. Enviar un reporte no expulsa automáticamente a un usuario, ni elimina mensajes, ni oculta el chat, ni notifica a la persona que reportaste. FanGeo puede aplicar tiempos de espera, límites de reportes duplicados y comprobaciones de prevención de abusos."),
        ("Bloqueo",
         "Los usuarios pueden bloquear a otros usuarios para impedir que interactúen con ellos donde el bloqueo esté disponible, incluidas las superficies de chat directo. El bloqueo limita el contacto no deseado en FanGeo; no impide que alguien te contacte fuera de FanGeo."),
        ("Revisión de moderación",
         "La revisión de moderación puede incluir los detalles del reporte, los identificadores de la cuenta del denunciante y de la denunciada, las marcas de tiempo, los motivos seleccionados, los comentarios o mensajes reportados, un contexto circundante limitado, las decisiones de moderación y los registros necesarios para la seguridad o el cumplimiento. Los registros de moderación pueden conservarse por motivos de seguridad. Los moderadores pueden advertir a los usuarios, ocultar o eliminar contenido, restringir funciones, restringir a usuarios abusivos, suspender cuentas, eliminar cuentas o conservar registros según la gravedad y la reincidencia."),
        ("Cumplimiento de la App Store",
         "FanGeo incluye mecanismos de reporte dentro de la aplicación y de escalamiento de moderación para el UGC y la mensajería privada. Los usuarios pueden bloquear a otros usuarios para impedir que interactúen con ellos donde el bloqueo esté disponible en la aplicación."),
        ("Emergencias",
         "Si tú u otra persona estáis en peligro inmediato, contacta de inmediato con los servicios de emergencia locales. FanGeo no es un servicio de crisis y no puede sustituir a la policía, a los servicios médicos ni a otros equipos de emergencia."),
    ],
)

# ---------------------------------------------------------------------------
# FRENCH (fr)
# ---------------------------------------------------------------------------
LANGUAGES["fr"] = build(
    "Dernière mise à jour : 18 juin 2026",
    [
        ("Aperçu",
         "La présente Politique de confidentialité explique comment FanGeo collecte, utilise, partage et conserve les informations lorsque vous utilisez l'application FanGeo."),
        ("Données de compte et de profil",
         "Nous collectons les informations que vous fournissez ou créez pour votre compte, telles que l'adresse e-mail, le nom affiché, le nom d'utilisateur, la biographie, l'avatar, les identifiants d'authentification, les équipes favorites, les lieux enregistrés, les matchs enregistrés, les signaux de présence ou d'intérêt, les préférences de notification, les paramètres de visibilité en direct, les blocages, les signalements et d'autres données de profil ou de préférences similaires."),
        ("Localisation et découverte",
         "FanGeo peut utiliser la localisation de votre appareil, la région de la carte, la ville recherchée ou l'emplacement d'un lieu pour vous montrer les bars sportifs à proximité, les matchs, l'activité de matchs improvisés et l'activité locale des supporters. Vous pouvez contrôler l'accès à la localisation de l'appareil dans les Réglages iOS. Les fiches de lieux et d'établissements peuvent inclure des adresses, des coordonnées, des photos, des horaires, des coordonnées de contact ainsi que des informations de revendication ou de propriété soumises par les propriétaires des lieux."),
        ("Messages, Fan Chats et contenu des utilisateurs",
         "FanGeo traite le contenu généré par les utilisateurs, tel que les messages directs, les conversations privées, les Fan Chats, les commentaires, les publications sur les lieux ou les événements, les photos, les signalements et les métadonnées associées, afin que l'application puisse acheminer les conversations, préserver le contexte des fils de discussion, faire respecter les règles de sécurité, enquêter sur les abus et maintenir l'intégrité du service."),
        ("Signalements et modération",
         "Lorsque vous signalez un utilisateur, un commentaire, un message, une conversation, un lieu ou un autre contenu, nous traitons votre signalement, le motif sélectionné, les détails facultatifs, le contenu signalé, le contexte du message ou de la conversation lorsque cela est pris en charge, les horodatages, les identifiants de compte et le statut de modération. Les enregistrements de modération peuvent être conservés afin de protéger les utilisateurs, de faire respecter les règles et de se conformer aux obligations légales ou à celles de l'App Store."),
        ("Publicités, analyse et diagnostics",
         "FanGeo utilise Google AdMob pour afficher des publicités. AdMob peut recevoir des informations sur l'appareil, l'interaction publicitaire, la localisation approximative et l'identifiant publicitaire selon les réglages de votre appareil et vos choix de consentement. FanGeo peut également utiliser des diagnostics de l'application, des journaux, des données de performance et des informations liées aux plantages afin de déboguer, de prévenir les abus et d'améliorer la fiabilité. Les journaux de débogage sont destinés à l'exploitation et aux tests, et non à la vente d'informations personnelles."),
        ("Services tiers",
         "FanGeo s'appuie sur des prestataires de services tels que Supabase pour l'authentification, la base de données, le stockage, les fonctionnalités en temps réel et les fonctions edge ; Google AdMob pour les publicités ; les services de la plateforme Apple ; et des fournisseurs de données sportives tels que TheSportsDB pour les calendriers et les données de matchs en direct. Ces prestataires traitent les données dans la mesure nécessaire à la fourniture de leurs services."),
        ("Suppression du compte",
         "La suppression de votre compte supprime ou anonymise votre profil public et vos préférences personnelles. Certains messages, commentaires, signalements et enregistrements de modération peuvent être conservés et affichés comme « Deleted User » afin de préserver l'intégrité des conversations, la sécurité et les enregistrements légaux ou de conformité. Les comptes supprimés ne peuvent pas se reconnecter, sauf si le support FanGeo restaure ou réactive le compte."),
        ("Conservation des données",
         "Nous conservons les données de compte et d'application aussi longtemps que nécessaire pour exploiter FanGeo, fournir les fonctionnalités demandées, prévenir les abus, résoudre les litiges, respecter la loi et maintenir des enregistrements de sécurité. Les durées de conservation varient selon le type de données. Le contenu public ou partagé peut subsister après la suppression lorsque cela est nécessaire pour préserver les conversations, les signalements, l'historique de modération, les enregistrements de lieux, les revendications d'établissements ou les enregistrements légaux ou de conformité."),
        ("Contact",
         "Pour toute question relative à la confidentialité ou à la suppression, contactez support@fangeosports.com ou utilisez le canal d'assistance disponible dans l'application."),
    ],
    [
        ("Aperçu",
         "Les présentes Conditions d'utilisation régissent votre utilisation de FanGeo. En utilisant l'application, en créant un compte, en publiant du contenu, en envoyant des messages, en soumettant des signalements, en revendiquant un lieu ou en gérant une fiche d'établissement, vous acceptez de respecter ces conditions."),
        ("Normes de la communauté et utilisation acceptable",
         "FanGeo applique une tolérance zéro à l'égard des contenus répréhensibles ou des utilisateurs abusifs. Les utilisateurs ne peuvent pas publier, téléverser, envoyer ou partager de contenu comportant du harcèlement, des propos haineux, des menaces, de l'intimidation, de l'exploitation sexuelle, du contenu illégal, du spam, de l'usurpation d'identité, un comportement abusif ou tout autre contenu répréhensible.\n\nLes utilisateurs peuvent signaler dans l'application les contenus répréhensibles ou les utilisateurs abusifs. FanGeo peut supprimer du contenu, restreindre l'accès, suspendre des comptes ou résilier définitivement les comptes qui enfreignent les présentes Conditions ou les Règles de la communauté."),
        ("Utilisation acceptable",
         "N'utilisez FanGeo qu'à des fins licites, personnelles et légitimes liées aux fiches d'établissements. N'utilisez pas le service de manière abusive, n'envoyez pas de spam, ne procédez pas à du scraping, de l'exploration ou de la collecte de données, ne manipulez pas la fréquentation ou les évaluations, n'interférez pas avec la sécurité de l'application, ne contournez pas les contrôles d'accès et ne tentez pas d'accéder à des comptes, des messages, des signalements, des outils d'administration, des outils de lieux ou des données que vous n'êtes pas autorisé à utiliser."),
        ("Contenu de l'utilisateur",
         "Vous êtes responsable du contenu que vous créez, téléversez, envoyez ou soumettez, y compris les informations de profil, les avatars, les Fan Chats, les messages directs, les signalements, l'activité de matchs improvisés, les photos de lieux, les informations d'établissement et les calendriers de matchs des lieux. Vous conservez vos droits de propriété, mais vous accordez à FanGeo l'autorisation d'héberger, d'afficher, de stocker, de modérer, de reproduire et de distribuer votre contenu dans la mesure nécessaire pour exploiter, améliorer et protéger le service."),
        ("Aucun harcèlement ni comportement dangereux",
         "La rivalité sportive et les débats passionnés sont les bienvenus. Le harcèlement, les menaces, les propos haineux, le doxxing, l'exploitation sexuelle, les abus ciblés, l'usurpation d'identité, le harcèlement obsessionnel, les escroqueries et l'incitation à des comportements illégaux ou dangereux ne sont pas autorisés. N'utilisez pas FanGeo pour organiser des rencontres dangereuses ni pour faire pression sur les utilisateurs afin qu'ils partagent des informations privées."),
        ("Revendications de lieux et d'établissements",
         "Si vous revendiquez ou gérez un lieu, un compte d'établissement ou un emplacement, vous confirmez que vous êtes autorisé à le faire et que les informations que vous soumettez sont exactes. FanGeo peut examiner, refuser, approuver, archiver, supprimer ou limiter les revendications ou fiches de lieux et d'établissements qui sont inexactes, frauduleuses, en double, dangereuses, inactives ou contraires aux présentes conditions."),
        ("Modération et application",
         "FanGeo peut examiner les signalements, supprimer ou masquer du contenu, restreindre des fonctionnalités, bloquer l'accès, suspendre des comptes, supprimer des comptes, conserver des enregistrements ou prendre d'autres mesures lorsque nous estimons que les présentes conditions, les Règles de la communauté, les règles de sécurité, la loi ou les exigences de l'App Store ont été enfreintes. Nous pouvons également conserver du contenu ou des enregistrements lorsque cela est nécessaire pour des raisons de sécurité, de conformité, de résolution de litiges ou pour des motifs légaux."),
        ("Limitations de l'application",
         "FanGeo est fourni « en l'état » dans la mesure permise par la loi. Nous ne garantissons pas un service ininterrompu, des données de lieux exactes, des calendriers sportifs complets, la disponibilité des publicités, les résultats des signalements, ni que chaque utilisateur ou lieu agira de manière sûre. Les fonctionnalités peuvent être modifiées, limitées ou interrompues."),
    ],
    [
        ("La rivalité sportive, oui ; les abus, non",
         "Encouragez à fond, débattez des équipes et chambrez sur le tableau d'affichage, mais ne prenez pas les personnes pour cible avec du harcèlement, des menaces, des propos haineux, des insultes, de l'intimidation, du harcèlement obsessionnel, des commentaires à caractère sexuel ou des contacts répétés et non désirés."),
        ("Non autorisé",
         "- Harcèlement, intimidation, menaces ou abus ciblés\n- Propos haineux, racisme, insultes ou discrimination\n- Doxxing, partage d'informations privées ou pression exercée sur les utilisateurs pour qu'ils révèlent des données personnelles\n- Usurpation de l'identité d'utilisateurs, de lieux, d'équipes, de ligues, de FanGeo ou de personnalités publiques\n- Spam, escroqueries, hameçonnage, fausses promotions, scraping ou publications perturbatrices répétées\n- Comportement dangereux lors de rencontres, coercition, harcèlement obsessionnel ou incitation à la violence ou à des actes illégaux\n- Exploitation sexuelle, contenu explicite ou contenu impliquant des mineurs"),
        ("Fan Chats et commentaires",
         "Faites en sorte que les Fan Chats et les commentaires sur les lieux ou les événements restent utiles pour le public sportif local. Ne détournez pas les fils de discussion avec du spam, des attaques personnelles, de fausses informations sur les lieux ou des abus coordonnés. Les commentaires peuvent être masqués, supprimés ou examinés lorsqu'ils sont signalés ou lorsqu'ils semblent enfreindre ces règles."),
        ("DMs et interactions entre amis",
         "Les messages directs servent à échanger de manière respectueuse avec les personnes ayant accepté une connexion d'ami. N'envoyez pas de messages abusifs, menaçants, à caractère sexuel, frauduleux, de spam ni de messages répétés et non désirés. Si quelqu'un vous demande d'arrêter, arrêtez."),
        ("Signaler et bloquer",
         "Signalez les utilisateurs, commentaires, messages ou conversations abusifs à l'aide des outils de signalement de l'application lorsqu'ils sont disponibles. Bloquez les utilisateurs qui ne devraient pas vous contacter. Les signalements aident FanGeo à examiner les problèmes de sécurité, mais ils doivent être véridiques et faits de bonne foi."),
        ("Application des règles",
         "FanGeo peut avertir les utilisateurs, supprimer du contenu, masquer des commentaires, restreindre la messagerie, suspendre des comptes, supprimer des comptes, conserver des signalements ou prendre d'autres mesures selon la gravité, le contexte et la récidive."),
        ("Votre accord",
         "En utilisant FanGeo, vous acceptez de respecter ces règles et de contribuer à maintenir une communauté sportive respectueuse."),
    ],
    [
        ("Aperçu",
         "Votre sécurité compte. FanGeo propose des outils de signalement et de blocage pour les comportements abusifs, l'UGC, les DMs, les Fan Chats, les commentaires, les conversations et les problèmes liés aux lieux lorsque cela est pris en charge dans l'application. Les signalements sont examinés au regard des Règles de la communauté de FanGeo."),
        ("Ce que vous pouvez signaler",
         "Utilisez les actions de signalement ou de marquage dans l'application lorsqu'elles sont disponibles, y compris les signalements d'utilisateurs, les commentaires de Fan Chats, les messages directs, les conversations, les fiches de lieux et le contenu des lieux ou événements. Des détails clairs et précis aident les modérateurs à comprendre ce qui s'est passé."),
        ("Commentaires et actualités des supporters",
         "Chaque utilisateur peut avoir un seul signalement actif par commentaire. Vous pouvez retirer un signalement accidentel en touchant de nouveau le drapeau rouge avant que les seuils ne s'appliquent. Plusieurs signalements actifs distincts peuvent déclencher un masquage automatique de la vue publique pendant l'examen du contenu. Si un commentaire a déjà été masqué automatiquement, retirer un signalement ne le rétablit pas automatiquement."),
        ("Signalement des conversations privées",
         "Depuis un chat direct, vous pouvez signaler la conversation ou le contenu de message pris en charge pour examen par un modérateur. Les signalements de DMs peuvent inclure uniquement la fenêtre d'examen sélectionnée, ainsi que les métadonnées associées nécessaires à l'évaluation du signalement. La soumission d'un signalement ne bannit pas automatiquement un utilisateur, ne supprime pas de messages, ne masque pas le chat et n'avertit pas la personne que vous avez signalée. FanGeo peut appliquer des délais d'attente, des limites de signalements en double et des vérifications de prévention des abus."),
        ("Blocage",
         "Les utilisateurs peuvent empêcher d'autres utilisateurs d'interagir avec eux là où le blocage est pris en charge, y compris les surfaces de chat direct. Le blocage limite les contacts indésirables dans FanGeo ; il n'empêche pas quelqu'un de vous contacter en dehors de FanGeo."),
        ("Examen de modération",
         "L'examen de modération peut inclure les détails du signalement, les identifiants de compte de l'auteur du signalement et de la personne signalée, les horodatages, les motifs sélectionnés, les commentaires ou messages signalés, un contexte environnant limité, les décisions de modération et les enregistrements nécessaires à la sécurité ou à la conformité. Les enregistrements de modération peuvent être conservés à des fins de sécurité. Les modérateurs peuvent avertir les utilisateurs, masquer ou supprimer du contenu, restreindre des fonctionnalités, restreindre les utilisateurs abusifs, suspendre des comptes, supprimer des comptes ou conserver des enregistrements selon la gravité et la récidive."),
        ("Conformité à l'App Store",
         "FanGeo comprend des mécanismes de signalement dans l'application et d'escalade de modération pour l'UGC et la messagerie privée. Les utilisateurs peuvent empêcher d'autres utilisateurs d'interagir avec eux là où le blocage est pris en charge dans l'application."),
        ("Urgences",
         "Si vous-même ou une autre personne êtes en danger immédiat, contactez immédiatement les services d'urgence locaux. FanGeo n'est pas un service de crise et ne peut pas remplacer la police, les secours médicaux ou d'autres intervenants d'urgence."),
    ],
)

# ---------------------------------------------------------------------------
# PORTUGUESE (pt)
# ---------------------------------------------------------------------------
LANGUAGES["pt"] = build(
    "Última atualização: 18 de junho de 2026",
    [
        ("Visão geral",
         "Esta Política de Privacidade explica como a FanGeo recolhe, utiliza, partilha e conserva informações quando utiliza a aplicação FanGeo."),
        ("Dados da conta e do perfil",
         "Recolhemos as informações que fornece ou cria para a sua conta, tais como endereço de e-mail, nome apresentado, nome de utilizador, biografia, avatar, identificadores de autenticação, equipas favoritas, locais guardados, jogos guardados, sinais de presença ou interesse, preferências de notificações, definições de visibilidade em direto, bloqueios, denúncias e dados de perfil ou preferências semelhantes."),
        ("Localização e descoberta",
         "A FanGeo pode utilizar a localização do seu dispositivo, a região do mapa, a cidade pesquisada ou a localização de um local para lhe mostrar bares desportivos próximos, jogos, atividade de jogos improvisados e atividade local de adeptos. Pode controlar o acesso à localização do dispositivo nas Definições do iOS. As fichas de locais e de negócios podem incluir moradas, coordenadas, fotografias, horários, dados de contacto e informações de reivindicação ou de propriedade submetidas pelos proprietários dos locais."),
        ("Mensagens, Fan Chats e conteúdo dos utilizadores",
         "A FanGeo processa conteúdo gerado pelos utilizadores, como mensagens diretas, conversas privadas, Fan Chats, comentários, publicações sobre locais ou eventos, fotografias, denúncias e metadados relacionados, para que a aplicação possa entregar as conversas, preservar o contexto das discussões, fazer cumprir as regras de segurança, investigar abusos e manter a integridade do serviço."),
        ("Denúncias e moderação",
         "Quando denuncia um utilizador, comentário, mensagem, conversa, local ou outro conteúdo, processamos a sua denúncia, o motivo selecionado, os detalhes opcionais, o conteúdo denunciado, o contexto da mensagem ou da conversa quando suportado, os registos de data e hora, os identificadores de conta e o estado de moderação. Os registos de moderação podem ser conservados para proteger os utilizadores, fazer cumprir as regras e cumprir obrigações legais ou da App Store."),
        ("Anúncios, análise e diagnósticos",
         "A FanGeo utiliza o Google AdMob para apresentar anúncios. O AdMob pode receber informações sobre o dispositivo, a interação com os anúncios, a localização aproximada e o identificador de publicidade, consoante as definições do seu dispositivo e as suas escolhas de consentimento. A FanGeo também pode utilizar diagnósticos da aplicação, registos, dados de desempenho e informações relacionadas com falhas para depurar, prevenir abusos e melhorar a fiabilidade. Os registos de depuração destinam-se a operações e testes, não à venda de informações pessoais."),
        ("Serviços de terceiros",
         "A FanGeo apoia-se em prestadores de serviços como a Supabase para autenticação, base de dados, armazenamento, funcionalidades em tempo real e funções edge; a Google AdMob para anúncios; os serviços da plataforma Apple; e fornecedores de dados desportivos como a TheSportsDB para calendários e dados de jogos em direto. Estes prestadores processam os dados na medida necessária para fornecer os seus serviços."),
        ("Eliminação da conta",
         "Ao eliminar a sua conta, o seu perfil público e as suas preferências pessoais são removidos ou anonimizados. Algumas mensagens, comentários, denúncias e registos de moderação podem ser conservados e apresentados como «Deleted User» para preservar a integridade das conversas, a segurança e os registos legais ou de conformidade. As contas eliminadas não podem voltar a iniciar sessão, a menos que o suporte da FanGeo restaure ou reative a conta."),
        ("Conservação de dados",
         "Conservamos os dados da conta e da aplicação enquanto for necessário para operar a FanGeo, fornecer as funcionalidades solicitadas, prevenir abusos, resolver litígios, cumprir a lei e manter registos de segurança. Os prazos de conservação variam consoante o tipo de dados. O conteúdo público ou partilhado pode permanecer após a eliminação quando for necessário para preservar conversas, denúncias, histórico de moderação, registos de locais, reivindicações de negócios ou registos legais ou de conformidade."),
        ("Contacto",
         "Para questões de privacidade ou eliminação, contacte support@fangeosports.com ou utilize o canal de suporte disponível na aplicação."),
    ],
    [
        ("Visão geral",
         "Estes Termos de Serviço regem a sua utilização da FanGeo. Ao utilizar a aplicação, criar uma conta, publicar conteúdo, enviar mensagens, submeter denúncias, reivindicar um local ou gerir a ficha de um negócio, concorda em cumprir estes termos."),
        ("Normas da comunidade e utilização aceitável",
         "A FanGeo tem tolerância zero para conteúdo censurável ou utilizadores abusivos. Os utilizadores não podem publicar, carregar, enviar ou partilhar conteúdo que inclua assédio, discurso de ódio, ameaças, intimidação, exploração sexual, conteúdo ilegal, spam, personificação, comportamento abusivo ou outro material censurável.\n\nOs utilizadores podem denunciar conteúdo censurável ou utilizadores abusivos na aplicação. A FanGeo pode remover conteúdo, restringir o acesso, suspender contas ou encerrar permanentemente as contas que violem estes Termos ou as Normas da Comunidade."),
        ("Utilização aceitável",
         "Utilize a FanGeo apenas para fins lícitos, pessoais e legítimos relacionados com fichas de negócios. Não faça uso indevido do serviço, não envie spam, não realize scraping, rastreio ou recolha de dados, não manipule a afluência ou as avaliações, não interfira com a segurança da aplicação, não contorne os controlos de acesso, nem tente aceder a contas, mensagens, denúncias, ferramentas de administração, ferramentas de locais ou dados que não está autorizado a utilizar."),
        ("Conteúdo do utilizador",
         "É responsável pelo conteúdo que cria, carrega, envia ou submete, incluindo dados de perfil, avatares, Fan Chats, mensagens diretas, denúncias, atividade de jogos improvisados, fotografias de locais, informações de negócios e calendários de jogos dos locais. Mantém os seus direitos de propriedade, mas concede à FanGeo autorização para alojar, apresentar, armazenar, moderar, reproduzir e distribuir o seu conteúdo na medida necessária para operar, melhorar e proteger o serviço."),
        ("Sem assédio nem condutas inseguras",
         "A rivalidade desportiva e o debate acalorado são bem-vindos. Não são permitidos o assédio, as ameaças, o discurso de ódio, o doxxing, a exploração sexual, o abuso direcionado, a personificação, a perseguição, as fraudes nem o incentivo a comportamentos ilegais ou inseguros. Não utilize a FanGeo para organizar encontros inseguros nem para pressionar os utilizadores a partilharem informações privadas."),
        ("Reivindicações de locais e de negócios",
         "Se reivindicar ou gerir um local, uma conta de negócio ou uma localização, confirma que está autorizado a fazê-lo e que as informações que submete são exatas. A FanGeo pode analisar, recusar, aprovar, arquivar, remover ou limitar reivindicações ou fichas de locais e negócios que sejam inexatas, fraudulentas, duplicadas, inseguras, inativas ou que violem estes termos."),
        ("Moderação e aplicação",
         "A FanGeo pode analisar denúncias, remover ou ocultar conteúdo, restringir funcionalidades, bloquear o acesso, suspender contas, eliminar contas, conservar registos ou tomar outras medidas quando considerar que estes termos, as Normas da Comunidade, as regras de segurança, a lei ou os requisitos da App Store foram violados. Também podemos conservar conteúdo ou registos quando for necessário por motivos de segurança, conformidade, resolução de litígios ou razões legais."),
        ("Limitações da aplicação",
         "A FanGeo é fornecida «tal como está», na medida permitida por lei. Não garantimos um serviço ininterrupto, dados exatos dos locais, calendários desportivos completos, disponibilidade de anúncios, resultados das denúncias, nem que todos os utilizadores ou locais atuem de forma segura. As funcionalidades podem ser alteradas, limitadas ou descontinuadas."),
    ],
    [
        ("Rivalidade desportiva, sim; abuso, não",
         "Torça com força, debata sobre as equipas e provoque em relação ao marcador, mas não vise as pessoas com assédio, ameaças, discurso de ódio, insultos, intimidação, perseguição, comentários de teor sexual ou contacto indesejado repetido."),
        ("Não permitido",
         "- Assédio, intimidação, ameaças ou abuso direcionado\n- Discurso de ódio, racismo, insultos ou discriminação\n- Doxxing, partilha de informações privadas ou pressão sobre os utilizadores para revelarem dados pessoais\n- Personificação de utilizadores, locais, equipas, ligas, FanGeo ou figuras públicas\n- Spam, fraudes, phishing, falsas promoções, scraping ou publicações disruptivas repetidas\n- Comportamento inseguro em encontros, coação, perseguição ou incentivo à violência ou a atos ilegais\n- Exploração sexual, conteúdo explícito ou conteúdo que envolva menores"),
        ("Fan Chats e comentários",
         "Mantenha os Fan Chats e os comentários sobre locais ou eventos úteis para o público desportivo local. Não desvie as discussões com spam, ataques pessoais, informações falsas sobre locais ou abuso coordenado. Os comentários podem ser ocultados, removidos ou analisados quando denunciados ou quando parecerem violar estas normas."),
        ("DMs e interações entre amigos",
         "As mensagens diretas destinam-se a conversas respeitosas com pessoas que aceitaram uma ligação de amizade. Não envie mensagens abusivas, ameaçadoras, de teor sexual, fraudulentas, de spam nem mensagens indesejadas de forma repetida. Se alguém lhe pedir para parar, pare."),
        ("Denunciar e bloquear",
         "Denuncie utilizadores, comentários, mensagens ou conversas abusivas utilizando as ferramentas de denúncia da aplicação, quando disponíveis. Bloqueie os utilizadores que não devem contactá-lo. As denúncias ajudam a FanGeo a analisar questões de segurança, mas devem ser verdadeiras e feitas de boa-fé."),
        ("Aplicação das normas",
         "A FanGeo pode avisar os utilizadores, remover conteúdo, ocultar comentários, restringir as mensagens, suspender contas, eliminar contas, conservar denúncias ou tomar outras medidas consoante a gravidade, o contexto e a reincidência."),
        ("O seu acordo",
         "Ao utilizar a FanGeo, concorda em seguir estas normas e em ajudar a manter uma comunidade desportiva respeitosa."),
    ],
    [
        ("Visão geral",
         "A sua segurança é importante. A FanGeo disponibiliza ferramentas de denúncia e bloqueio para comportamentos abusivos, UGC, DMs, Fan Chats, comentários, conversas e questões relacionadas com locais, quando suportadas na aplicação. As denúncias são analisadas ao abrigo das Normas da Comunidade da FanGeo."),
        ("O que pode denunciar",
         "Utilize as ações de denúncia ou sinalização na aplicação, quando disponíveis, incluindo denúncias de utilizadores, comentários de Fan Chats, mensagens diretas, conversas, fichas de locais e conteúdo de locais ou eventos. Detalhes claros e exatos ajudam os moderadores a compreender o que aconteceu."),
        ("Comentários e novidades dos adeptos",
         "Cada utilizador pode ter uma denúncia ativa por comentário. Pode remover uma denúncia acidental tocando novamente na bandeira vermelha antes de os limiares se aplicarem. Várias denúncias ativas distintas podem acionar a ocultação automática da visualização pública enquanto o conteúdo é analisado. Se um comentário já tiver sido ocultado automaticamente, remover uma denúncia não o restaura automaticamente."),
        ("Denúncia de conversas privadas",
         "A partir de um chat direto, pode denunciar a conversa ou o conteúdo de mensagem suportado para análise por um moderador. As denúncias de DMs podem incluir apenas a janela de análise selecionada, juntamente com os metadados relacionados necessários para avaliar a denúncia. A submissão de uma denúncia não bane automaticamente um utilizador, não elimina mensagens, não oculta o chat nem notifica a pessoa que denunciou. A FanGeo pode aplicar períodos de espera, limites a denúncias duplicadas e verificações de prevenção de abusos."),
        ("Bloqueio",
         "Os utilizadores podem bloquear outros utilizadores para impedir que interajam consigo onde o bloqueio for suportado, incluindo as superfícies de chat direto. O bloqueio limita o contacto indesejado na FanGeo; não impede que alguém o contacte fora da FanGeo."),
        ("Análise de moderação",
         "A análise de moderação pode incluir os detalhes da denúncia, os identificadores de conta do denunciante e do denunciado, os registos de data e hora, os motivos selecionados, os comentários ou mensagens denunciados, um contexto envolvente limitado, as decisões de moderação e os registos necessários para a segurança ou a conformidade. Os registos de moderação podem ser conservados por motivos de segurança. Os moderadores podem avisar os utilizadores, ocultar ou eliminar conteúdo, restringir funcionalidades, restringir utilizadores abusivos, suspender contas, eliminar contas ou conservar registos consoante a gravidade e a reincidência."),
        ("Conformidade com a App Store",
         "A FanGeo inclui mecanismos de denúncia na aplicação e de escalonamento de moderação para UGC e mensagens privadas. Os utilizadores podem bloquear outros utilizadores para impedir que interajam consigo onde o bloqueio for suportado na aplicação."),
        ("Emergências",
         "Se você ou outra pessoa estiver em perigo imediato, contacte imediatamente os serviços de emergência locais. A FanGeo não é um serviço de crise e não pode substituir a polícia, os serviços médicos ou outros socorristas de emergência."),
    ],
)

# ---------------------------------------------------------------------------
# GERMAN (de)
# ---------------------------------------------------------------------------
LANGUAGES["de"] = build(
    "Zuletzt aktualisiert: 18. Juni 2026",
    [
        ("Überblick",
         "Diese Datenschutzerklärung erläutert, wie FanGeo Informationen erhebt, verwendet, weitergibt und aufbewahrt, wenn Sie die FanGeo-App nutzen."),
        ("Konto- und Profildaten",
         "Wir erheben die Informationen, die Sie für Ihr Konto angeben oder erstellen, wie E-Mail-Adresse, Anzeigename, Benutzername, Bio, Avatar, Authentifizierungskennungen, Lieblingsteams, gespeicherte Locations, gespeicherte Spiele, Teilnahme- oder Interessensignale, Benachrichtigungseinstellungen, Live-Sichtbarkeitseinstellungen, Blockierungen, Meldungen und ähnliche Profil- oder Präferenzdaten."),
        ("Standort und Entdeckung",
         "FanGeo kann Ihren Gerätestandort, den Kartenausschnitt, die gesuchte Stadt oder den Standort einer Location verwenden, um Ihnen nahegelegene Sportbars, Spiele, Pickup-Aktivitäten und lokale Fan-Aktivitäten anzuzeigen. Den Zugriff auf den Gerätestandort können Sie in den iOS-Einstellungen steuern. Location- und Geschäftseinträge können Adressen, Koordinaten, Fotos, Öffnungszeiten, Kontaktdaten sowie von den Location-Inhabern übermittelte Beanspruchungs- oder Eigentümerinformationen enthalten."),
        ("Nachrichten, Fan Chats und Nutzerinhalte",
         "FanGeo verarbeitet von Nutzern erstellte Inhalte wie Direktnachrichten, private Unterhaltungen, Fan Chats, Kommentare, Location-/Event-Beiträge, Fotos, Meldungen und zugehörige Metadaten, damit die App Unterhaltungen bereitstellen, den Kontext von Threads bewahren, Sicherheitsregeln durchsetzen, Missbrauch untersuchen und die Integrität des Dienstes aufrechterhalten kann."),
        ("Meldungen und Moderation",
         "Wenn Sie einen Nutzer, einen Kommentar, eine Nachricht, eine Unterhaltung, eine Location oder andere Inhalte melden, verarbeiten wir Ihre Meldung, den gewählten Grund, optionale Angaben, den gemeldeten Inhalt, den Nachrichten- oder Unterhaltungskontext, sofern unterstützt, Zeitstempel, Kontokennungen und den Moderationsstatus. Moderationsaufzeichnungen können aufbewahrt werden, um Nutzer zu schützen, Regeln durchzusetzen und rechtlichen oder App-Store-Pflichten nachzukommen."),
        ("Werbung, Analyse und Diagnose",
         "FanGeo verwendet Google AdMob, um Werbung anzuzeigen. AdMob kann je nach Ihren Geräteeinstellungen und Einwilligungsentscheidungen Informationen über das Gerät, die Werbeinteraktion, den ungefähren Standort und die Werbe-ID erhalten. FanGeo kann außerdem App-Diagnosen, Protokolle, Leistungsdaten und absturzbezogene Informationen verwenden, um Fehler zu beheben, Missbrauch zu verhindern und die Zuverlässigkeit zu verbessern. Debug-Protokolle sind für Betrieb und Tests bestimmt, nicht für den Verkauf personenbezogener Daten."),
        ("Dienste von Drittanbietern",
         "FanGeo stützt sich auf Dienstleister wie Supabase für Authentifizierung, Datenbank, Speicher, Echtzeitfunktionen und Edge-Funktionen; Google AdMob für Werbung; Apple-Plattformdienste; sowie Sportdatenanbieter wie TheSportsDB für Spielpläne und Live-Spieldaten. Diese Anbieter verarbeiten Daten im erforderlichen Umfang, um ihre Dienste zu erbringen."),
        ("Kontolöschung",
         "Durch das Löschen Ihres Kontos werden Ihr öffentliches Profil und Ihre persönlichen Einstellungen entfernt oder anonymisiert. Einige Nachrichten, Kommentare, Meldungen und Moderationsaufzeichnungen können aufbewahrt und als „Deleted User“ angezeigt werden, um die Integrität von Unterhaltungen, die Sicherheit sowie rechtliche bzw. Compliance-Aufzeichnungen zu wahren. Gelöschte Konten können sich nicht erneut anmelden, es sei denn, der FanGeo-Support stellt das Konto wieder her oder reaktiviert es."),
        ("Datenaufbewahrung",
         "Wir bewahren Konto- und App-Daten so lange auf, wie dies erforderlich ist, um FanGeo zu betreiben, angeforderte Funktionen bereitzustellen, Missbrauch zu verhindern, Streitigkeiten beizulegen, dem Gesetz zu entsprechen und Sicherheitsaufzeichnungen zu führen. Die Aufbewahrungsfristen variieren je nach Datenart. Öffentliche oder geteilte Inhalte können nach der Löschung bestehen bleiben, wenn dies erforderlich ist, um Unterhaltungen, Meldungen, den Moderationsverlauf, Location-Aufzeichnungen, Geschäftsbeanspruchungen oder rechtliche bzw. Compliance-Aufzeichnungen zu wahren."),
        ("Kontakt",
         "Bei Fragen zum Datenschutz oder zur Löschung wenden Sie sich an support@fangeosports.com oder nutzen Sie den in der App verfügbaren Support-Kanal."),
    ],
    [
        ("Überblick",
         "Diese Nutzungsbedingungen regeln Ihre Nutzung von FanGeo. Indem Sie die App nutzen, ein Konto erstellen, Inhalte veröffentlichen, Nachrichten senden, Meldungen einreichen, eine Location beanspruchen oder einen Geschäftseintrag verwalten, erklären Sie sich damit einverstanden, diese Bedingungen einzuhalten."),
        ("Gemeinschaftsstandards und akzeptable Nutzung",
         "FanGeo hat null Toleranz gegenüber anstößigen Inhalten oder missbräuchlichen Nutzern. Nutzer dürfen keine Inhalte veröffentlichen, hochladen, senden oder teilen, die Belästigung, Hassrede, Drohungen, Mobbing, sexuelle Ausbeutung, illegale Inhalte, Spam, Identitätsvortäuschung, missbräuchliches Verhalten oder sonstiges anstößiges Material enthalten.\n\nNutzer können anstößige Inhalte oder missbräuchliche Nutzer in der App melden. FanGeo kann Inhalte entfernen, den Zugriff einschränken, Konten sperren oder Konten dauerhaft kündigen, die gegen diese Bedingungen oder die Community-Richtlinien verstoßen."),
        ("Akzeptable Nutzung",
         "Nutzen Sie FanGeo nur zu rechtmäßigen, persönlichen und legitimen Zwecken im Zusammenhang mit Geschäftseinträgen. Missbrauchen Sie den Dienst nicht, versenden Sie keinen Spam, betreiben Sie kein Scraping, Crawling oder Sammeln von Daten, manipulieren Sie keine Besucherzahlen oder Bewertungen, greifen Sie nicht in die Sicherheit der App ein, umgehen Sie keine Zugriffskontrollen und versuchen Sie nicht, auf Konten, Nachrichten, Meldungen, Admin-Tools, Location-Tools oder Daten zuzugreifen, zu deren Nutzung Sie nicht berechtigt sind."),
        ("Nutzerinhalte",
         "Sie sind für die Inhalte verantwortlich, die Sie erstellen, hochladen, senden oder einreichen, einschließlich Profildaten, Avatare, Fan Chats, Direktnachrichten, Meldungen, Pickup-Aktivitäten, Location-Fotos, Geschäftsinformationen und Location-Spielpläne. Sie behalten Ihre Eigentumsrechte, erteilen FanGeo jedoch die Erlaubnis, Ihre Inhalte in dem Umfang zu hosten, anzuzeigen, zu speichern, zu moderieren, zu vervielfältigen und zu verbreiten, wie dies zum Betreiben, Verbessern und Schützen des Dienstes erforderlich ist."),
        ("Keine Belästigung oder unsicheres Verhalten",
         "Sportliche Rivalität und leidenschaftliche Debatten sind willkommen. Belästigung, Drohungen, Hassrede, Doxxing, sexuelle Ausbeutung, gezielter Missbrauch, Identitätsvortäuschung, Stalking, Betrug und die Aufforderung zu illegalem oder unsicherem Verhalten sind nicht erlaubt. Nutzen Sie FanGeo nicht, um unsichere Treffen zu organisieren oder Nutzer dazu zu drängen, private Informationen preiszugeben."),
        ("Location- und Geschäftsbeanspruchungen",
         "Wenn Sie eine Location, ein Geschäftskonto oder einen Standort beanspruchen oder verwalten, bestätigen Sie, dass Sie dazu berechtigt sind und dass die von Ihnen übermittelten Informationen zutreffend sind. FanGeo kann Location- und Geschäftsbeanspruchungen oder -einträge, die unzutreffend, betrügerisch, doppelt, unsicher oder inaktiv sind oder gegen diese Bedingungen verstoßen, prüfen, ablehnen, genehmigen, archivieren, entfernen oder einschränken."),
        ("Moderation und Durchsetzung",
         "FanGeo kann Meldungen prüfen, Inhalte entfernen oder ausblenden, Funktionen einschränken, den Zugriff sperren, Konten aussetzen, Konten löschen, Aufzeichnungen aufbewahren oder andere Maßnahmen ergreifen, wenn wir der Auffassung sind, dass gegen diese Bedingungen, die Community-Richtlinien, Sicherheitsregeln, das Gesetz oder App-Store-Anforderungen verstoßen wurde. Wir können Inhalte oder Aufzeichnungen auch dann aufbewahren, wenn dies aus Gründen der Sicherheit, der Compliance, der Streitbeilegung oder aus rechtlichen Gründen erforderlich ist."),
        ("Einschränkungen der App",
         "FanGeo wird im gesetzlich zulässigen Umfang „wie besehen“ bereitgestellt. Wir garantieren keinen unterbrechungsfreien Dienst, keine exakten Location-Daten, keine vollständigen Sport-Spielpläne, keine Werbeverfügbarkeit, keine Ergebnisse von Meldungen und nicht, dass jeder Nutzer oder jede Location sicher handelt. Funktionen können geändert, eingeschränkt oder eingestellt werden."),
    ],
    [
        ("Sportliche Rivalität ist okay; Missbrauch nicht",
         "Feuern Sie kräftig an, diskutieren Sie über Teams und lästern Sie über den Spielstand, aber greifen Sie keine Personen mit Belästigung, Drohungen, Hassrede, Beleidigungen, Mobbing, Stalking, sexuellen Kommentaren oder wiederholtem unerwünschtem Kontakt an."),
        ("Nicht erlaubt",
         "- Belästigung, Mobbing, Drohungen oder gezielter Missbrauch\n- Hassrede, Rassismus, Beleidigungen oder Diskriminierung\n- Doxxing, Weitergabe privater Informationen oder Druck auf Nutzer, persönliche Daten preiszugeben\n- Vortäuschung der Identität von Nutzern, Locations, Teams, Ligen, FanGeo oder Personen des öffentlichen Lebens\n- Spam, Betrug, Phishing, gefälschte Werbeaktionen, Scraping oder wiederholte störende Beiträge\n- Unsicheres Verhalten bei Treffen, Nötigung, Stalking oder Aufforderung zu Gewalt oder illegalen Handlungen\n- Sexuelle Ausbeutung, explizite Inhalte oder Inhalte, an denen Minderjährige beteiligt sind"),
        ("Fan Chats und Kommentare",
         "Halten Sie Fan Chats sowie Location-/Event-Kommentare nützlich für die lokale Sportgemeinschaft. Bringen Sie Threads nicht mit Spam, persönlichen Angriffen, falschen Location-Informationen oder koordiniertem Missbrauch vom Thema ab. Kommentare können ausgeblendet, entfernt oder geprüft werden, wenn sie gemeldet werden oder gegen diese Richtlinien zu verstoßen scheinen."),
        ("DMs und Freundesinteraktionen",
         "Direktnachrichten dienen dem respektvollen Austausch mit Personen, die eine Freundschaftsverbindung akzeptiert haben. Senden Sie keine missbräuchlichen, bedrohlichen, sexuellen, betrügerischen, Spam- oder wiederholt unerwünschten Nachrichten. Wenn jemand Sie bittet aufzuhören, hören Sie auf."),
        ("Melden und blockieren",
         "Melden Sie missbräuchliche Nutzer, Kommentare, Nachrichten oder Unterhaltungen über die In-App-Meldefunktionen, sofern verfügbar. Blockieren Sie Nutzer, die Sie nicht kontaktieren sollten. Meldungen helfen FanGeo, Sicherheitsprobleme zu prüfen, sie sollten jedoch wahrheitsgemäß und in gutem Glauben erfolgen."),
        ("Durchsetzung",
         "FanGeo kann Nutzer verwarnen, Inhalte entfernen, Kommentare ausblenden, das Versenden von Nachrichten einschränken, Konten aussetzen, Konten löschen, Meldungen aufbewahren oder andere Maßnahmen ergreifen, abhängig von Schwere, Kontext und wiederholtem Verhalten."),
        ("Ihre Zustimmung",
         "Durch die Nutzung von FanGeo erklären Sie sich damit einverstanden, diese Richtlinien zu befolgen und dazu beizutragen, eine respektvolle Sportgemeinschaft zu erhalten."),
    ],
    [
        ("Überblick",
         "Ihre Sicherheit ist uns wichtig. FanGeo bietet Melde- und Blockierfunktionen für missbräuchliches Verhalten, UGC, DMs, Fan Chats, Kommentare, Unterhaltungen und Location-bezogene Probleme, sofern in der App unterstützt. Meldungen werden nach den Community-Richtlinien von FanGeo geprüft."),
        ("Was Sie melden können",
         "Nutzen Sie die In-App-Melde- oder Kennzeichnungsaktionen, sofern verfügbar, einschließlich Nutzermeldungen, Fan-Chat-Kommentaren, Direktnachrichten, Unterhaltungen, Location-Einträgen und Location-/Event-Inhalten. Klare, genaue Angaben helfen Moderatoren zu verstehen, was passiert ist."),
        ("Kommentare und Fan-Updates",
         "Jeder Nutzer kann pro Kommentar eine aktive Meldung haben. Eine versehentliche Meldung können Sie zurücknehmen, indem Sie erneut auf die rote Flagge tippen, bevor Schwellenwerte greifen. Mehrere eindeutige aktive Meldungen können ein automatisches Ausblenden aus der öffentlichen Ansicht auslösen, während der Inhalt geprüft wird. Wenn ein Kommentar bereits automatisch ausgeblendet wurde, wird er durch das Zurücknehmen einer Meldung nicht automatisch wiederhergestellt."),
        ("Meldung privater Unterhaltungen",
         "In einem Direktchat können Sie die Unterhaltung oder unterstützte Nachrichteninhalte zur Prüfung durch einen Moderator melden. DM-Meldungen können nur das ausgewählte Prüffenster sowie die zugehörigen Metadaten enthalten, die zur Bewertung der Meldung erforderlich sind. Das Einreichen einer Meldung sperrt nicht automatisch einen Nutzer, löscht keine Nachrichten, blendet den Chat nicht aus und benachrichtigt nicht die gemeldete Person. FanGeo kann Wartezeiten, Grenzen für doppelte Meldungen und Prüfungen zur Missbrauchsprävention anwenden."),
        ("Blockieren",
         "Nutzer können andere Nutzer daran hindern, mit ihnen zu interagieren, sofern das Blockieren unterstützt wird, einschließlich der Direktchat-Oberflächen. Das Blockieren begrenzt unerwünschten Kontakt in FanGeo; es hindert jemanden nicht daran, Sie außerhalb von FanGeo zu kontaktieren."),
        ("Moderationsprüfung",
         "Die Moderationsprüfung kann Meldungsdetails, Kontokennungen der meldenden und der gemeldeten Person, Zeitstempel, ausgewählte Gründe, gemeldete Kommentare oder Nachrichten, einen begrenzten umgebenden Kontext, Moderationsentscheidungen sowie für Sicherheit oder Compliance erforderliche Aufzeichnungen umfassen. Moderationsaufzeichnungen können aus Sicherheitsgründen aufbewahrt werden. Moderatoren können Nutzer verwarnen, Inhalte ausblenden oder löschen, Funktionen einschränken, missbräuchliche Nutzer einschränken, Konten aussetzen, Konten löschen oder Aufzeichnungen aufbewahren, abhängig von Schwere und wiederholtem Verhalten."),
        ("App-Store-Konformität",
         "FanGeo enthält In-App-Melde- und Moderations-Eskalationsmechanismen für UGC und private Nachrichten. Nutzer können andere Nutzer daran hindern, mit ihnen zu interagieren, sofern das Blockieren in der App unterstützt wird."),
        ("Notfälle",
         "Wenn Sie oder eine andere Person in unmittelbarer Gefahr sind, wenden Sie sich sofort an Ihre örtlichen Notdienste. FanGeo ist kein Krisendienst und kann Polizei, medizinische oder andere Notfallhelfer nicht ersetzen."),
    ],
)

# ---------------------------------------------------------------------------
# ITALIAN (it)
# ---------------------------------------------------------------------------
LANGUAGES["it"] = build(
    "Ultimo aggiornamento: 18 giugno 2026",
    [
        ("Panoramica",
         "La presente Informativa sulla privacy spiega come FanGeo raccoglie, utilizza, condivide e conserva le informazioni quando utilizzi l'app FanGeo."),
        ("Dati dell'account e del profilo",
         "Raccogliamo le informazioni che fornisci o crei per il tuo account, come indirizzo e-mail, nome visualizzato, nome utente, biografia, avatar, identificativi di autenticazione, squadre preferite, locali salvati, partite salvate, segnali di presenza o interesse, preferenze di notifica, impostazioni di visibilità in diretta, blocchi, segnalazioni e dati di profilo o preferenze simili."),
        ("Posizione e scoperta",
         "FanGeo può utilizzare la posizione del tuo dispositivo, l'area della mappa, la città cercata o la posizione di un locale per mostrarti sports bar nelle vicinanze, partite, attività di partite improvvisate e attività locale dei tifosi. Puoi controllare l'accesso alla posizione del dispositivo nelle Impostazioni di iOS. Le schede dei locali e delle attività commerciali possono includere indirizzi, coordinate, foto, orari, recapiti e informazioni sulla rivendicazione o sulla titolarità inviate dai proprietari dei locali."),
        ("Messaggi, Fan Chats e contenuti degli utenti",
         "FanGeo tratta i contenuti generati dagli utenti, come messaggi diretti, conversazioni private, Fan Chats, commenti, post su locali o eventi, foto, segnalazioni e metadati correlati, affinché l'app possa recapitare le conversazioni, preservare il contesto delle discussioni, far rispettare le regole di sicurezza, indagare sugli abusi e mantenere l'integrità del servizio."),
        ("Segnalazioni e moderazione",
         "Quando segnali un utente, un commento, un messaggio, una conversazione, un locale o altri contenuti, trattiamo la tua segnalazione, il motivo selezionato, gli eventuali dettagli, il contenuto segnalato, il contesto del messaggio o della conversazione ove supportato, le marche temporali, gli identificativi dell'account e lo stato di moderazione. I registri di moderazione possono essere conservati per proteggere gli utenti, far rispettare le regole e adempiere agli obblighi di legge o dell'App Store."),
        ("Pubblicità, analisi e diagnostica",
         "FanGeo utilizza Google AdMob per mostrare gli annunci. AdMob può ricevere informazioni sul dispositivo, sull'interazione con gli annunci, sulla posizione approssimativa e sull'identificativo pubblicitario, a seconda delle impostazioni del tuo dispositivo e delle tue scelte di consenso. FanGeo può inoltre utilizzare diagnostica dell'app, log, dati sulle prestazioni e informazioni relative agli arresti anomali per eseguire il debug, prevenire gli abusi e migliorare l'affidabilità. I log di debug sono destinati alle operazioni e ai test, non alla vendita di informazioni personali."),
        ("Servizi di terze parti",
         "FanGeo si avvale di fornitori di servizi come Supabase per l'autenticazione, il database, l'archiviazione, le funzionalità in tempo reale e le funzioni edge; Google AdMob per gli annunci; i servizi della piattaforma Apple; e fornitori di dati sportivi come TheSportsDB per i calendari e i dati delle partite in diretta. Questi fornitori trattano i dati nella misura necessaria a erogare i propri servizi."),
        ("Eliminazione dell'account",
         "L'eliminazione dell'account rimuove o rende anonimi il tuo profilo pubblico e le tue preferenze personali. Alcuni messaggi, commenti, segnalazioni e registri di moderazione possono essere conservati e mostrati come «Deleted User» per preservare l'integrità delle conversazioni, la sicurezza e i registri legali o di conformità. Gli account eliminati non possono più accedere, a meno che l'assistenza FanGeo non ripristini o riattivi l'account."),
        ("Conservazione dei dati",
         "Conserviamo i dati dell'account e dell'app per il tempo necessario a gestire FanGeo, fornire le funzionalità richieste, prevenire gli abusi, risolvere le controversie, rispettare la legge e mantenere i registri di sicurezza. I periodi di conservazione variano in base al tipo di dato. I contenuti pubblici o condivisi possono permanere dopo l'eliminazione quando è necessario per preservare conversazioni, segnalazioni, cronologia di moderazione, registri dei locali, rivendicazioni di attività commerciali o registri legali o di conformità."),
        ("Contatti",
         "Per domande sulla privacy o sull'eliminazione, contatta support@fangeosports.com o utilizza il canale di assistenza disponibile nell'app."),
    ],
    [
        ("Panoramica",
         "I presenti Termini di servizio disciplinano il tuo utilizzo di FanGeo. Utilizzando l'app, creando un account, pubblicando contenuti, inviando messaggi, inoltrando segnalazioni, rivendicando un locale o gestendo una scheda commerciale, accetti di rispettare questi termini."),
        ("Standard della community e uso accettabile",
         "FanGeo ha tolleranza zero verso i contenuti riprovevoli o gli utenti abusivi. Gli utenti non possono pubblicare, caricare, inviare o condividere contenuti che includano molestie, incitamento all'odio, minacce, atti di bullismo, sfruttamento sessuale, contenuti illegali, spam, sostituzione di identità, comportamenti abusivi o altro materiale riprovevole.\n\nGli utenti possono segnalare nell'app i contenuti riprovevoli o gli utenti abusivi. FanGeo può rimuovere contenuti, limitare l'accesso, sospendere account o chiudere in modo permanente gli account che violano i presenti Termini o le Linee guida della community."),
        ("Uso accettabile",
         "Utilizza FanGeo solo per scopi leciti, personali e legittimi legati alle schede commerciali. Non utilizzare il servizio in modo improprio, non inviare spam, non effettuare scraping, crawling o raccolta di dati, non manipolare le presenze o le valutazioni, non interferire con la sicurezza dell'app, non aggirare i controlli di accesso e non tentare di accedere ad account, messaggi, segnalazioni, strumenti di amministrazione, strumenti per i locali o dati che non sei autorizzato a utilizzare."),
        ("Contenuti dell'utente",
         "Sei responsabile dei contenuti che crei, carichi, invii o inoltri, inclusi i dati del profilo, gli avatar, le Fan Chats, i messaggi diretti, le segnalazioni, l'attività di partite improvvisate, le foto dei locali, le informazioni commerciali e i calendari delle partite dei locali. Mantieni i tuoi diritti di proprietà, ma concedi a FanGeo l'autorizzazione a ospitare, mostrare, archiviare, moderare, riprodurre e distribuire i tuoi contenuti nella misura necessaria per gestire, migliorare e proteggere il servizio."),
        ("Nessuna molestia o condotta non sicura",
         "La rivalità sportiva e il dibattito acceso sono benvenuti. Non sono consentiti molestie, minacce, incitamento all'odio, doxxing, sfruttamento sessuale, abusi mirati, sostituzione di identità, stalking, truffe e l'incoraggiamento di comportamenti illegali o non sicuri. Non utilizzare FanGeo per organizzare incontri non sicuri né per fare pressione sugli utenti affinché condividano informazioni private."),
        ("Rivendicazioni di locali e attività commerciali",
         "Se rivendichi o gestisci un locale, un account commerciale o una posizione, confermi di essere autorizzato a farlo e che le informazioni che invii sono accurate. FanGeo può esaminare, rifiutare, approvare, archiviare, rimuovere o limitare le rivendicazioni o le schede di locali e attività commerciali che risultino inaccurate, fraudolente, duplicate, non sicure, inattive o in violazione dei presenti termini."),
        ("Moderazione e applicazione",
         "FanGeo può esaminare le segnalazioni, rimuovere o nascondere contenuti, limitare funzionalità, bloccare l'accesso, sospendere account, eliminare account, conservare registri o adottare altri provvedimenti quando riteniamo che siano stati violati i presenti termini, le Linee guida della community, le regole di sicurezza, la legge o i requisiti dell'App Store. Possiamo inoltre conservare contenuti o registri quando è necessario per motivi di sicurezza, conformità, risoluzione delle controversie o ragioni legali."),
        ("Limitazioni dell'app",
         "FanGeo è fornita «così com'è» nella misura consentita dalla legge. Non garantiamo un servizio ininterrotto, dati esatti sui locali, calendari sportivi completi, disponibilità di annunci, esiti delle segnalazioni, né che ogni utente o locale agisca in modo sicuro. Le funzionalità possono essere modificate, limitate o interrotte."),
    ],
    [
        ("La rivalità sportiva va bene; gli abusi no",
         "Tifa con passione, discuti delle squadre e sfotti sul punteggio, ma non prendere di mira le persone con molestie, minacce, incitamento all'odio, insulti, atti di bullismo, stalking, commenti sessuali o contatti indesiderati ripetuti."),
        ("Non consentito",
         "- Molestie, atti di bullismo, minacce o abusi mirati\n- Incitamento all'odio, razzismo, insulti o discriminazione\n- Doxxing, condivisione di informazioni private o pressioni sugli utenti affinché rivelino dati personali\n- Sostituzione dell'identità di utenti, locali, squadre, leghe, FanGeo o personaggi pubblici\n- Spam, truffe, phishing, false promozioni, scraping o post disturbanti ripetuti\n- Comportamento non sicuro negli incontri, coercizione, stalking o incoraggiamento alla violenza o ad atti illegali\n- Sfruttamento sessuale, contenuti espliciti o contenuti che coinvolgono minori"),
        ("Fan Chats e commenti",
         "Mantieni le Fan Chats e i commenti su locali ed eventi utili per il pubblico sportivo locale. Non deviare le discussioni con spam, attacchi personali, false informazioni sui locali o abusi coordinati. I commenti possono essere nascosti, rimossi o esaminati quando vengono segnalati o quando sembrano violare queste linee guida."),
        ("DMs e interazioni tra amici",
         "I messaggi diretti servono a conversare in modo rispettoso con le persone che hanno accettato una connessione di amicizia. Non inviare messaggi abusivi, minacciosi, sessuali, truffaldini, spam o messaggi indesiderati ripetuti. Se qualcuno ti chiede di smettere, smetti."),
        ("Segnalare e bloccare",
         "Segnala utenti, commenti, messaggi o conversazioni abusive utilizzando gli strumenti di segnalazione dell'app, ove disponibili. Blocca gli utenti che non dovrebbero contattarti. Le segnalazioni aiutano FanGeo a esaminare i problemi di sicurezza, ma devono essere veritiere e fatte in buona fede."),
        ("Applicazione",
         "FanGeo può avvisare gli utenti, rimuovere contenuti, nascondere commenti, limitare la messaggistica, sospendere account, eliminare account, conservare segnalazioni o adottare altri provvedimenti a seconda della gravità, del contesto e della recidiva."),
        ("Il tuo accordo",
         "Utilizzando FanGeo, accetti di seguire queste linee guida e di contribuire a mantenere una community sportiva rispettosa."),
    ],
    [
        ("Panoramica",
         "La tua sicurezza è importante. FanGeo mette a disposizione strumenti di segnalazione e blocco per comportamenti abusivi, UGC, DMs, Fan Chats, commenti, conversazioni e problemi legati ai locali, ove supportati nell'app. Le segnalazioni vengono esaminate secondo le Linee guida della community di FanGeo."),
        ("Cosa puoi segnalare",
         "Utilizza le azioni di segnalazione o contrassegno nell'app, ove disponibili, incluse le segnalazioni di utenti, i commenti delle Fan Chats, i messaggi diretti, le conversazioni, le schede dei locali e i contenuti di locali o eventi. Dettagli chiari e accurati aiutano i moderatori a capire cosa è successo."),
        ("Commenti e aggiornamenti dei tifosi",
         "Ogni utente può avere una segnalazione attiva per commento. Puoi rimuovere una segnalazione accidentale toccando di nuovo la bandierina rossa prima che vengano applicate le soglie. Più segnalazioni attive distinte possono attivare l'occultamento automatico dalla vista pubblica mentre il contenuto è in fase di revisione. Se un commento è già stato nascosto automaticamente, la rimozione di una segnalazione non lo ripristina automaticamente."),
        ("Segnalazione delle conversazioni private",
         "Da una chat diretta puoi segnalare la conversazione o il contenuto del messaggio supportato per la revisione di un moderatore. Le segnalazioni dei DMs possono includere solo la finestra di revisione selezionata, insieme ai metadati correlati necessari per valutare la segnalazione. L'invio di una segnalazione non comporta automaticamente il ban di un utente, l'eliminazione dei messaggi, l'occultamento della chat né la notifica alla persona segnalata. FanGeo può applicare tempi di attesa, limiti alle segnalazioni duplicate e controlli anti-abuso."),
        ("Blocco",
         "Gli utenti possono impedire ad altri utenti di interagire con loro dove il blocco è supportato, incluse le superfici di chat diretta. Il blocco limita i contatti indesiderati in FanGeo; non impedisce a qualcuno di contattarti al di fuori di FanGeo."),
        ("Revisione della moderazione",
         "La revisione della moderazione può includere i dettagli della segnalazione, gli identificativi dell'account del segnalante e del segnalato, le marche temporali, i motivi selezionati, i commenti o i messaggi segnalati, un contesto circostante limitato, le decisioni di moderazione e i registri necessari per la sicurezza o la conformità. I registri di moderazione possono essere conservati per motivi di sicurezza. I moderatori possono avvisare gli utenti, nascondere o eliminare contenuti, limitare funzionalità, limitare gli utenti abusivi, sospendere account, eliminare account o conservare registri a seconda della gravità e della recidiva."),
        ("Conformità all'App Store",
         "FanGeo include meccanismi di segnalazione nell'app e di escalation della moderazione per UGC e messaggistica privata. Gli utenti possono impedire ad altri utenti di interagire con loro dove il blocco è supportato nell'app."),
        ("Emergenze",
         "Se tu o un'altra persona siete in pericolo immediato, contatta subito i servizi di emergenza locali. FanGeo non è un servizio di emergenza e non può sostituire la polizia, il personale medico o altri soccorritori."),
    ],
)

# ---------------------------------------------------------------------------
# POLISH (pl)
# ---------------------------------------------------------------------------
LANGUAGES["pl"] = build(
    "Ostatnia aktualizacja: 18 czerwca 2026",
    [
        ("Przegląd",
         "Niniejsza Polityka prywatności wyjaśnia, w jaki sposób FanGeo gromadzi, wykorzystuje, udostępnia i przechowuje informacje, gdy korzystasz z aplikacji FanGeo."),
        ("Dane konta i profilu",
         "Gromadzimy informacje, które podajesz lub tworzysz na potrzeby swojego konta, takie jak adres e-mail, nazwa wyświetlana, nazwa użytkownika, bio, awatar, identyfikatory uwierzytelniania, ulubione drużyny, zapisane lokale, zapisane mecze, sygnały obecności lub zainteresowania, preferencje powiadomień, ustawienia widoczności na żywo, blokady, zgłoszenia oraz podobne dane profilu lub preferencji."),
        ("Lokalizacja i odkrywanie",
         "FanGeo może wykorzystywać lokalizację Twojego urządzenia, obszar mapy, wyszukiwane miasto lub lokalizację lokalu, aby pokazywać pobliskie bary sportowe, mecze, aktywność meczów towarzyskich oraz lokalną aktywność kibiców. Dostępem do lokalizacji urządzenia możesz zarządzać w Ustawieniach iOS. Wpisy lokali i firm mogą obejmować adresy, współrzędne, zdjęcia, godziny otwarcia, dane kontaktowe oraz informacje o roszczeniu lub własności przesłane przez właścicieli lokali."),
        ("Wiadomości, Fan Chaty i treści użytkowników",
         "FanGeo przetwarza treści tworzone przez użytkowników, takie jak wiadomości bezpośrednie, prywatne rozmowy, Fan Chaty, komentarze, posty o lokalach lub wydarzeniach, zdjęcia, zgłoszenia oraz powiązane metadane, aby aplikacja mogła dostarczać rozmowy, zachowywać kontekst wątków, egzekwować zasady bezpieczeństwa, badać nadużycia i utrzymywać integralność usługi."),
        ("Zgłoszenia i moderacja",
         "Gdy zgłaszasz użytkownika, komentarz, wiadomość, rozmowę, lokal lub inną treść, przetwarzamy Twoje zgłoszenie, wybrany powód, opcjonalne szczegóły, zgłoszoną treść, kontekst wiadomości lub rozmowy tam, gdzie jest to obsługiwane, znaczniki czasu, identyfikatory kont oraz status moderacji. Zapisy moderacyjne mogą być przechowywane w celu ochrony użytkowników, egzekwowania zasad oraz spełniania obowiązków prawnych lub wymogów App Store."),
        ("Reklamy, analityka i diagnostyka",
         "FanGeo korzysta z Google AdMob do wyświetlania reklam. AdMob może otrzymywać informacje o urządzeniu, interakcji z reklamą, przybliżonej lokalizacji oraz identyfikatorze reklamowym w zależności od ustawień Twojego urządzenia i wyborów dotyczących zgody. FanGeo może również wykorzystywać diagnostykę aplikacji, dzienniki, dane o wydajności oraz informacje związane z awariami w celu debugowania, zapobiegania nadużyciom i poprawy niezawodności. Dzienniki debugowania są przeznaczone do celów operacyjnych i testowych, a nie do sprzedaży informacji osobowych."),
        ("Usługi podmiotów trzecich",
         "FanGeo korzysta z usługodawców takich jak Supabase w zakresie uwierzytelniania, bazy danych, przechowywania, funkcji czasu rzeczywistego i funkcji edge; Google AdMob w zakresie reklam; usług platformy Apple; oraz dostawców danych sportowych, takich jak TheSportsDB, w zakresie terminarzy i danych o meczach na żywo. Usługodawcy ci przetwarzają dane w zakresie niezbędnym do świadczenia swoich usług."),
        ("Usunięcie konta",
         "Usunięcie konta powoduje usunięcie lub anonimizację Twojego profilu publicznego i osobistych preferencji. Niektóre wiadomości, komentarze, zgłoszenia i zapisy moderacyjne mogą być zachowane i wyświetlane jako „Deleted User”, aby zachować integralność rozmów, bezpieczeństwo oraz zapisy prawne lub dotyczące zgodności. Usunięte konta nie mogą się ponownie zalogować, chyba że dział wsparcia FanGeo przywróci lub ponownie aktywuje konto."),
        ("Przechowywanie danych",
         "Przechowujemy dane konta i aplikacji tak długo, jak jest to potrzebne do obsługi FanGeo, świadczenia żądanych funkcji, zapobiegania nadużyciom, rozstrzygania sporów, przestrzegania prawa i utrzymywania zapisów dotyczących bezpieczeństwa. Okresy przechowywania różnią się w zależności od rodzaju danych. Treści publiczne lub udostępnione mogą pozostać po usunięciu, gdy jest to konieczne do zachowania rozmów, zgłoszeń, historii moderacji, zapisów o lokalach, roszczeń biznesowych lub zapisów prawnych bądź dotyczących zgodności."),
        ("Kontakt",
         "W sprawach dotyczących prywatności lub usunięcia danych skontaktuj się z support@fangeosports.com lub skorzystaj z kanału wsparcia dostępnego w aplikacji."),
    ],
    [
        ("Przegląd",
         "Niniejszy Regulamin określa zasady korzystania z FanGeo. Korzystając z aplikacji, tworząc konto, publikując treści, wysyłając wiadomości, przesyłając zgłoszenia, przejmując lokal lub zarządzając wpisem firmowym, zgadzasz się przestrzegać niniejszych warunków."),
        ("Standardy społeczności i dopuszczalne korzystanie",
         "FanGeo stosuje zasadę zerowej tolerancji wobec treści budzących sprzeciw oraz użytkowników dopuszczających się nadużyć. Użytkownicy nie mogą publikować, przesyłać, wysyłać ani udostępniać treści zawierających nękanie, mowę nienawiści, groźby, znęcanie się, wykorzystywanie seksualne, treści nielegalne, spam, podszywanie się, zachowania obraźliwe lub inne materiały budzące sprzeciw.\n\nUżytkownicy mogą zgłaszać w aplikacji treści budzące sprzeciw lub użytkowników dopuszczających się nadużyć. FanGeo może usuwać treści, ograniczać dostęp, zawieszać konta lub trwale zamykać konta naruszające niniejszy Regulamin lub Wytyczne dla społeczności."),
        ("Dopuszczalne korzystanie",
         "Korzystaj z FanGeo wyłącznie w celach zgodnych z prawem, osobistych oraz uzasadnionych celów związanych z wpisami firmowymi. Nie nadużywaj usługi, nie wysyłaj spamu, nie prowadź scrapingu, indeksowania ani pozyskiwania danych, nie manipuluj frekwencją ani ocenami, nie ingeruj w bezpieczeństwo aplikacji, nie obchodź mechanizmów kontroli dostępu ani nie próbuj uzyskać dostępu do kont, wiadomości, zgłoszeń, narzędzi administracyjnych, narzędzi dla lokali lub danych, do których nie masz uprawnień."),
        ("Treści użytkownika",
         "Odpowiadasz za treści, które tworzysz, przesyłasz, wysyłasz lub zgłaszasz, w tym dane profilu, awatary, Fan Chaty, wiadomości bezpośrednie, zgłoszenia, aktywność w meczach towarzyskich, zdjęcia lokali, informacje firmowe oraz terminarze meczów w lokalach. Zachowujesz swoje prawa własności, ale udzielasz FanGeo zgody na hostowanie, wyświetlanie, przechowywanie, moderowanie, zwielokrotnianie i rozpowszechnianie Twoich treści w zakresie niezbędnym do obsługi, ulepszania i ochrony usługi."),
        ("Zakaz nękania i niebezpiecznych zachowań",
         "Rywalizacja sportowa i żywiołowa dyskusja są mile widziane. Nękanie, groźby, mowa nienawiści, doxxing, wykorzystywanie seksualne, ukierunkowane nadużycia, podszywanie się, uporczywe nękanie, oszustwa oraz zachęcanie do zachowań nielegalnych lub niebezpiecznych są zabronione. Nie używaj FanGeo do organizowania niebezpiecznych spotkań ani do wywierania presji na użytkownikach, aby udostępniali prywatne informacje."),
        ("Roszczenia do lokali i firm",
         "Jeśli przejmujesz lub zarządzasz lokalem, kontem firmowym lub lokalizacją, potwierdzasz, że masz do tego uprawnienia i że przesyłane przez Ciebie informacje są dokładne. FanGeo może weryfikować, odrzucać, zatwierdzać, archiwizować, usuwać lub ograniczać roszczenia bądź wpisy lokali i firm, które są niedokładne, oszukańcze, zduplikowane, niebezpieczne, nieaktywne lub naruszają niniejsze warunki."),
        ("Moderacja i egzekwowanie",
         "FanGeo może weryfikować zgłoszenia, usuwać lub ukrywać treści, ograniczać funkcje, blokować dostęp, zawieszać konta, usuwać konta, przechowywać zapisy lub podejmować inne działania, gdy uznamy, że naruszono niniejsze warunki, Wytyczne dla społeczności, zasady bezpieczeństwa, prawo lub wymogi App Store. Możemy również zachować treści lub zapisy, gdy jest to konieczne ze względów bezpieczeństwa, zgodności, rozstrzygania sporów lub przyczyn prawnych."),
        ("Ograniczenia aplikacji",
         "FanGeo jest udostępniana „w stanie, w jakim jest” w zakresie dozwolonym przez prawo. Nie gwarantujemy nieprzerwanego działania usługi, dokładnych danych o lokalach, kompletnych terminarzy sportowych, dostępności reklam, wyników zgłoszeń ani tego, że każdy użytkownik lub lokal będzie postępować bezpiecznie. Funkcje mogą ulegać zmianie, zostać ograniczone lub wycofane."),
    ],
    [
        ("Rywalizacja sportowa jest w porządku; nadużycia nie",
         "Kibicuj z zapałem, dyskutuj o drużynach i podpuszczaj w kwestii wyniku, ale nie atakuj ludzi nękaniem, groźbami, mową nienawiści, wyzwiskami, znęcaniem się, uporczywym nękaniem, komentarzami o charakterze seksualnym ani powtarzającym się niechcianym kontaktem."),
        ("Niedozwolone",
         "- Nękanie, znęcanie się, groźby lub ukierunkowane nadużycia\n- Mowa nienawiści, rasizm, wyzwiska lub dyskryminacja\n- Doxxing, udostępnianie prywatnych informacji lub wywieranie presji na użytkownikach, aby ujawnili dane osobowe\n- Podszywanie się pod użytkowników, lokale, drużyny, ligi, FanGeo lub osoby publiczne\n- Spam, oszustwa, phishing, fałszywe promocje, scraping lub powtarzające się zakłócające posty\n- Niebezpieczne zachowania podczas spotkań, przymus, uporczywe nękanie lub zachęcanie do przemocy bądź czynów nielegalnych\n- Wykorzystywanie seksualne, treści o charakterze jednoznacznie seksualnym lub treści z udziałem nieletnich"),
        ("Fan Chaty i komentarze",
         "Dbaj o to, aby Fan Chaty oraz komentarze dotyczące lokali i wydarzeń były przydatne dla lokalnej społeczności kibiców. Nie zakłócaj wątków spamem, atakami osobistymi, fałszywymi informacjami o lokalach ani skoordynowanymi nadużyciami. Komentarze mogą zostać ukryte, usunięte lub poddane weryfikacji po zgłoszeniu lub gdy wydają się naruszać niniejsze wytyczne."),
        ("DMs i interakcje ze znajomymi",
         "Wiadomości bezpośrednie służą do prowadzenia rozmów z szacunkiem z osobami, które zaakceptowały połączenie znajomości. Nie wysyłaj wiadomości obraźliwych, zawierających groźby, o charakterze seksualnym, oszukańczych, spamu ani powtarzających się niechcianych wiadomości. Jeśli ktoś prosi Cię o zaprzestanie, przestań."),
        ("Zgłaszanie i blokowanie",
         "Zgłaszaj użytkowników, komentarze, wiadomości lub rozmowy naruszające zasady, korzystając z narzędzi zgłaszania w aplikacji tam, gdzie są dostępne. Blokuj użytkowników, którzy nie powinni się z Tobą kontaktować. Zgłoszenia pomagają FanGeo weryfikować kwestie bezpieczeństwa, ale powinny być zgodne z prawdą i dokonywane w dobrej wierze."),
        ("Egzekwowanie",
         "FanGeo może ostrzegać użytkowników, usuwać treści, ukrywać komentarze, ograniczać wysyłanie wiadomości, zawieszać konta, usuwać konta, przechowywać zgłoszenia lub podejmować inne działania w zależności od wagi naruszenia, kontekstu i powtarzalności zachowań."),
        ("Twoja zgoda",
         "Korzystając z FanGeo, zgadzasz się przestrzegać niniejszych wytycznych i pomagać w utrzymaniu pełnej szacunku społeczności sportowej."),
    ],
    [
        ("Przegląd",
         "Twoje bezpieczeństwo jest ważne. FanGeo udostępnia narzędzia do zgłaszania i blokowania w przypadku zachowań stanowiących nadużycie, UGC, DMs, Fan Chatów, komentarzy, rozmów oraz kwestii związanych z lokalami tam, gdzie jest to obsługiwane w aplikacji. Zgłoszenia są rozpatrywane zgodnie z Wytycznymi dla społeczności FanGeo."),
        ("Co możesz zgłosić",
         "Korzystaj z dostępnych w aplikacji akcji zgłaszania lub oznaczania, w tym zgłoszeń użytkowników, komentarzy w Fan Chatach, wiadomości bezpośrednich, rozmów, wpisów lokali oraz treści dotyczących lokali lub wydarzeń. Jasne, dokładne szczegóły pomagają moderatorom zrozumieć, co się wydarzyło."),
        ("Komentarze i aktualności kibiców",
         "Każdy użytkownik może mieć jedno aktywne zgłoszenie na komentarz. Możesz cofnąć przypadkowe zgłoszenie, ponownie dotykając czerwonej flagi, zanim zostaną zastosowane progi. Wiele odrębnych aktywnych zgłoszeń może spowodować automatyczne ukrycie treści z widoku publicznego na czas jej weryfikacji. Jeśli komentarz został już automatycznie ukryty, cofnięcie zgłoszenia nie przywraca go automatycznie."),
        ("Zgłaszanie prywatnych rozmów",
         "Z poziomu czatu bezpośredniego możesz zgłosić rozmowę lub obsługiwaną treść wiadomości do weryfikacji przez moderatora. Zgłoszenia DMs mogą obejmować wyłącznie wybrane okno weryfikacji wraz z powiązanymi metadanymi niezbędnymi do oceny zgłoszenia. Przesłanie zgłoszenia nie powoduje automatycznego zbanowania użytkownika, usunięcia wiadomości, ukrycia czatu ani powiadomienia zgłaszanej osoby. FanGeo może stosować okresy oczekiwania, limity zduplikowanych zgłoszeń oraz mechanizmy zapobiegania nadużyciom."),
        ("Blokowanie",
         "Użytkownicy mogą blokować innym użytkownikom możliwość interakcji z nimi tam, gdzie blokowanie jest obsługiwane, w tym w powierzchniach czatu bezpośredniego. Blokowanie ogranicza niechciany kontakt w FanGeo; nie uniemożliwia komuś kontaktu z Tobą poza FanGeo."),
        ("Weryfikacja moderacyjna",
         "Weryfikacja moderacyjna może obejmować szczegóły zgłoszenia, identyfikatory kont zgłaszającego i zgłaszanego, znaczniki czasu, wybrane powody, zgłoszone komentarze lub wiadomości, ograniczony kontekst otaczający, decyzje moderacyjne oraz zapisy niezbędne dla bezpieczeństwa lub zgodności. Zapisy moderacyjne mogą być przechowywane ze względów bezpieczeństwa. Moderatorzy mogą ostrzegać użytkowników, ukrywać lub usuwać treści, ograniczać funkcje, ograniczać użytkowników dopuszczających się nadużyć, zawieszać konta, usuwać konta lub przechowywać zapisy w zależności od wagi naruszenia i powtarzalności zachowań."),
        ("Zgodność z App Store",
         "FanGeo obejmuje wbudowane w aplikację mechanizmy zgłaszania i eskalacji moderacji dla UGC oraz wiadomości prywatnych. Użytkownicy mogą blokować innym użytkownikom możliwość interakcji z nimi tam, gdzie blokowanie jest obsługiwane w aplikacji."),
        ("Sytuacje awaryjne",
         "Jeśli Ty lub inna osoba znajdujecie się w bezpośrednim niebezpieczeństwie, natychmiast skontaktuj się z lokalnymi służbami ratunkowymi. FanGeo nie jest służbą kryzysową i nie może zastąpić policji, służb medycznych ani innych służb ratunkowych."),
    ],
)

# ---------------------------------------------------------------------------
# RUSSIAN (ru)
# ---------------------------------------------------------------------------
LANGUAGES["ru"] = build(
    "Последнее обновление: 18 июня 2026 г.",
    [
        ("Обзор",
         "Настоящая Политика конфиденциальности объясняет, как FanGeo собирает, использует, передаёт и хранит информацию, когда вы пользуетесь приложением FanGeo."),
        ("Данные учётной записи и профиля",
         "Мы собираем информацию, которую вы предоставляете или создаёте для своей учётной записи, такую как адрес электронной почты, отображаемое имя, имя пользователя, биография, аватар, идентификаторы аутентификации, любимые команды, сохранённые заведения, сохранённые матчи, сигналы посещения или интереса, настройки уведомлений, настройки видимости в режиме реального времени, блокировки, жалобы и аналогичные данные профиля или предпочтений."),
        ("Местоположение и поиск",
         "FanGeo может использовать местоположение вашего устройства, область карты, искомый город или местоположение заведения, чтобы показывать ближайшие спорт-бары, матчи, любительские игры и местную активность болельщиков. Доступ к местоположению устройства можно настроить в Настройках iOS. Карточки заведений и организаций могут включать адреса, координаты, фотографии, часы работы, контактные данные, а также сведения о заявке или праве собственности, предоставленные владельцами заведений."),
        ("Сообщения, Fan Chats и пользовательский контент",
         "FanGeo обрабатывает создаваемый пользователями контент, такой как личные сообщения, приватные переписки, Fan Chats, комментарии, публикации о заведениях и событиях, фотографии, жалобы и связанные метаданные, чтобы приложение могло доставлять переписки, сохранять контекст веток, обеспечивать соблюдение правил безопасности, расследовать злоупотребления и поддерживать целостность сервиса."),
        ("Жалобы и модерация",
         "Когда вы подаёте жалобу на пользователя, комментарий, сообщение, переписку, заведение или иной контент, мы обрабатываем вашу жалобу, выбранную причину, необязательные сведения, содержание жалобы, контекст сообщения или переписки, где это поддерживается, отметки времени, идентификаторы учётных записей и статус модерации. Записи модерации могут храниться для защиты пользователей, обеспечения соблюдения правил и выполнения юридических обязательств или требований App Store."),
        ("Реклама, аналитика и диагностика",
         "FanGeo использует Google AdMob для показа рекламы. AdMob может получать информацию об устройстве, взаимодействии с рекламой, приблизительном местоположении и рекламном идентификаторе в зависимости от настроек вашего устройства и выбранных вами параметров согласия. FanGeo также может использовать диагностику приложения, журналы, данные о производительности и информацию, связанную со сбоями, для отладки, предотвращения злоупотреблений и повышения надёжности. Журналы отладки предназначены для эксплуатации и тестирования, а не для продажи персональных данных."),
        ("Сторонние сервисы",
         "FanGeo использует поставщиков услуг, таких как Supabase — для аутентификации, базы данных, хранения, функций в реальном времени и edge-функций; Google AdMob — для рекламы; сервисы платформы Apple; а также поставщиков спортивных данных, таких как TheSportsDB — для расписаний и данных о матчах в прямом эфире. Эти поставщики обрабатывают данные в объёме, необходимом для предоставления своих услуг."),
        ("Удаление учётной записи",
         "Удаление вашей учётной записи приводит к удалению или обезличиванию вашего публичного профиля и личных предпочтений. Некоторые сообщения, комментарии, жалобы и записи модерации могут сохраняться и отображаться как «Deleted User» для сохранения целостности переписок, безопасности и юридических записей или записей о соответствии требованиям. Удалённые учётные записи не могут снова войти в систему, если только служба поддержки FanGeo не восстановит или повторно не активирует учётную запись."),
        ("Хранение данных",
         "Мы храним данные учётной записи и приложения столько, сколько необходимо для работы FanGeo, предоставления запрошенных функций, предотвращения злоупотреблений, разрешения споров, соблюдения закона и ведения записей о безопасности. Сроки хранения различаются в зависимости от типа данных. Публичный или общедоступный контент может сохраняться после удаления, когда это необходимо для сохранения переписок, жалоб, истории модерации, записей о заведениях, заявок организаций или юридических записей либо записей о соответствии требованиям."),
        ("Контакты",
         "По вопросам конфиденциальности или удаления данных обращайтесь по адресу support@fangeosports.com или используйте канал поддержки, доступный в приложении."),
    ],
    [
        ("Обзор",
         "Настоящие Условия использования регулируют использование вами FanGeo. Используя приложение, создавая учётную запись, публикуя контент, отправляя сообщения, подавая жалобы, заявляя права на заведение или управляя карточкой организации, вы соглашаетесь соблюдать эти условия."),
        ("Стандарты сообщества и допустимое использование",
         "FanGeo придерживается политики нулевой терпимости к предосудительному контенту или пользователям, допускающим злоупотребления. Пользователи не могут публиковать, загружать, отправлять или распространять контент, содержащий преследование, разжигание ненависти, угрозы, травлю, сексуальную эксплуатацию, незаконный контент, спам, выдачу себя за другое лицо, оскорбительное поведение или иные предосудительные материалы.\n\nПользователи могут сообщать о предосудительном контенте или пользователях, допускающих злоупотребления, в приложении. FanGeo может удалять контент, ограничивать доступ, приостанавливать учётные записи или окончательно закрывать учётные записи, нарушающие настоящие Условия или Правила сообщества."),
        ("Допустимое использование",
         "Используйте FanGeo только в законных, личных и правомерных целях, связанных с карточками организаций. Не используйте сервис ненадлежащим образом, не рассылайте спам, не выполняйте скрейпинг, обход или сбор данных, не манипулируйте посещаемостью или рейтингами, не вмешивайтесь в безопасность приложения, не обходите средства контроля доступа и не пытайтесь получить доступ к учётным записям, сообщениям, жалобам, инструментам администрирования, инструментам для заведений или данным, к использованию которых у вас нет полномочий."),
        ("Пользовательский контент",
         "Вы несёте ответственность за контент, который создаёте, загружаете, отправляете или предоставляете, включая данные профиля, аватары, Fan Chats, личные сообщения, жалобы, любительские игры, фотографии заведений, сведения об организациях и расписания матчей заведений. Вы сохраняете свои права собственности, но предоставляете FanGeo разрешение размещать, отображать, хранить, модерировать, воспроизводить и распространять ваш контент в объёме, необходимом для работы, улучшения и защиты сервиса."),
        ("Недопустимость преследования и небезопасного поведения",
         "Спортивное соперничество и оживлённые споры приветствуются. Преследование, угрозы, разжигание ненависти, доксинг, сексуальная эксплуатация, целенаправленные злоупотребления, выдача себя за другое лицо, сталкинг, мошенничество и подстрекательство к незаконному или небезопасному поведению не допускаются. Не используйте FanGeo для организации небезопасных встреч или для давления на пользователей с целью раскрытия личной информации."),
        ("Заявки на заведения и организации",
         "Если вы заявляете права на заведение, учётную запись организации или местоположение либо управляете ими, вы подтверждаете, что уполномочены на это и что предоставляемая вами информация является точной. FanGeo может проверять, отклонять, одобрять, архивировать, удалять или ограничивать заявки либо карточки заведений и организаций, которые являются неточными, мошенническими, дублирующимися, небезопасными, неактивными или нарушают настоящие условия."),
        ("Модерация и применение мер",
         "FanGeo может рассматривать жалобы, удалять или скрывать контент, ограничивать функции, блокировать доступ, приостанавливать учётные записи, удалять учётные записи, сохранять записи или принимать иные меры, когда мы считаем, что были нарушены настоящие условия, Правила сообщества, правила безопасности, закон или требования App Store. Мы также можем сохранять контент или записи, когда это необходимо в целях безопасности, соответствия требованиям, разрешения споров или по юридическим причинам."),
        ("Ограничения приложения",
         "FanGeo предоставляется «как есть» в объёме, разрешённом законом. Мы не гарантируем бесперебойную работу сервиса, точность данных о заведениях, полноту спортивных расписаний, доступность рекламы, результаты рассмотрения жалоб, а также того, что каждый пользователь или заведение будут действовать безопасно. Функции могут изменяться, ограничиваться или прекращаться."),
    ],
    [
        ("Спортивное соперничество — нормально; злоупотребления — нет",
         "Болейте от души, спорьте о командах и подтрунивайте по поводу счёта, но не преследуйте людей с помощью травли, угроз, разжигания ненависти, оскорблений, издевательств, сталкинга, сексуальных комментариев или повторяющихся нежелательных контактов."),
        ("Запрещено",
         "- Преследование, травля, угрозы или целенаправленные злоупотребления\n- Разжигание ненависти, расизм, оскорбления или дискриминация\n- Доксинг, раскрытие личной информации или давление на пользователей с целью раскрытия персональных данных\n- Выдача себя за пользователей, заведения, команды, лиги, FanGeo или публичных лиц\n- Спам, мошенничество, фишинг, поддельные акции, скрейпинг или повторяющиеся деструктивные публикации\n- Небезопасное поведение при встречах, принуждение, сталкинг или подстрекательство к насилию или незаконным действиям\n- Сексуальная эксплуатация, материалы откровенного характера или контент с участием несовершеннолетних"),
        ("Fan Chats и комментарии",
         "Пусть Fan Chats и комментарии о заведениях и событиях остаются полезными для местного спортивного сообщества. Не уводите ветки в сторону спамом, личными нападками, ложной информацией о заведениях или скоординированными злоупотреблениями. Комментарии могут быть скрыты, удалены или отправлены на проверку при получении жалобы или если они, по-видимому, нарушают настоящие правила."),
        ("DMs и взаимодействие с друзьями",
         "Личные сообщения предназначены для уважительного общения с людьми, принявшими запрос в друзья. Не отправляйте оскорбительные, угрожающие, сексуальные, мошеннические, спам- или повторяющиеся нежелательные сообщения. Если вас просят прекратить — прекратите."),
        ("Жалобы и блокировка",
         "Сообщайте о пользователях, комментариях, сообщениях или переписках, допускающих злоупотребления, с помощью встроенных инструментов подачи жалоб, где это доступно. Блокируйте пользователей, которым не следует с вами связываться. Жалобы помогают FanGeo рассматривать вопросы безопасности, но они должны быть правдивыми и подаваться добросовестно."),
        ("Применение мер",
         "FanGeo может предупреждать пользователей, удалять контент, скрывать комментарии, ограничивать обмен сообщениями, приостанавливать учётные записи, удалять учётные записи, сохранять жалобы или принимать иные меры в зависимости от тяжести, контекста и повторности нарушений."),
        ("Ваше согласие",
         "Используя FanGeo, вы соглашаетесь соблюдать настоящие правила и помогать поддерживать уважительное спортивное сообщество."),
    ],
    [
        ("Обзор",
         "Ваша безопасность важна. FanGeo предоставляет инструменты подачи жалоб и блокировки в отношении злоупотреблений, UGC, DMs, Fan Chats, комментариев, переписок и вопросов, связанных с заведениями, где это поддерживается в приложении. Жалобы рассматриваются в соответствии с Правилами сообщества FanGeo."),
        ("О чём можно сообщить",
         "Используйте встроенные действия подачи жалоб или отметок, где они доступны, включая жалобы на пользователей, комментарии в Fan Chats, личные сообщения, переписки, карточки заведений и контент заведений или событий. Чёткие и точные сведения помогают модераторам понять, что произошло."),
        ("Комментарии и обновления болельщиков",
         "У каждого пользователя может быть одна активная жалоба на комментарий. Вы можете отменить случайную жалобу, снова нажав на красный флажок до того, как сработают пороговые значения. Несколько отдельных активных жалоб могут привести к автоматическому скрытию из общего доступа на время проверки контента. Если комментарий уже был автоматически скрыт, отмена жалобы не восстанавливает его автоматически."),
        ("Жалобы на приватные переписки",
         "Из личного чата вы можете пожаловаться на переписку или поддерживаемое содержимое сообщения для проверки модератором. Жалобы на DMs могут включать только выбранное окно проверки вместе со связанными метаданными, необходимыми для оценки жалобы. Подача жалобы не приводит автоматически к блокировке пользователя, удалению сообщений, скрытию чата или уведомлению лица, на которое вы пожаловались. FanGeo может применять периоды ожидания, ограничения на дублирующиеся жалобы и проверки для предотвращения злоупотреблений."),
        ("Блокировка",
         "Пользователи могут блокировать другим пользователям возможность взаимодействовать с ними там, где блокировка поддерживается, включая поверхности личного чата. Блокировка ограничивает нежелательные контакты в FanGeo; она не препятствует тому, чтобы кто-либо связался с вами за пределами FanGeo."),
        ("Проверка модерации",
         "Проверка модерации может включать сведения о жалобе, идентификаторы учётных записей заявителя и лица, на которое подана жалоба, отметки времени, выбранные причины, комментарии или сообщения, на которые подана жалоба, ограниченный окружающий контекст, решения модерации и записи, необходимые для безопасности или соответствия требованиям. Записи модерации могут храниться в целях безопасности. Модераторы могут предупреждать пользователей, скрывать или удалять контент, ограничивать функции, ограничивать пользователей, допускающих злоупотребления, приостанавливать учётные записи, удалять учётные записи или сохранять записи в зависимости от тяжести и повторности нарушений."),
        ("Соответствие требованиям App Store",
         "FanGeo включает встроенные механизмы подачи жалоб и эскалации модерации для UGC и приватного обмена сообщениями. Пользователи могут блокировать другим пользователям возможность взаимодействовать с ними там, где блокировка поддерживается в приложении."),
        ("Чрезвычайные ситуации",
         "Если вы или кто-либо другой находитесь в непосредственной опасности, немедленно обратитесь в местные экстренные службы. FanGeo не является кризисной службой и не может заменить полицию, медицинскую помощь или другие экстренные службы."),
    ],
)

# ---------------------------------------------------------------------------
# ALBANIAN (sq)
# ---------------------------------------------------------------------------
LANGUAGES["sq"] = build(
    "Përditësuar së fundmi: 18 qershor 2026",
    [
        ("Përmbledhje",
         "Kjo Politikë e Privatësisë shpjegon se si FanGeo mbledh, përdor, ndan dhe ruan informacionin kur përdorni aplikacionin FanGeo."),
        ("Të dhënat e llogarisë dhe të profilit",
         "Ne mbledhim informacionin që jepni ose krijoni për llogarinë tuaj, si adresa e email-it, emri i shfaqur, emri i përdoruesit, biografia, avatari, identifikuesit e vërtetimit, ekipet e preferuara, vendet e ruajtura, ndeshjet e ruajtura, sinjalet e pjesëmarrjes ose të interesit, preferencat e njoftimeve, cilësimet e dukshmërisë në kohë reale, bllokimet, raportimet dhe të dhëna të ngjashme të profilit ose të preferencave."),
        ("Vendndodhja dhe zbulimi",
         "FanGeo mund të përdorë vendndodhjen e pajisjes suaj, zonën e hartës, qytetin e kërkuar ose vendndodhjen e një vendi për t'ju treguar bare sportive aty pranë, ndeshje, aktivitet ndeshjesh të lira dhe aktivitet vendor tifozësh. Qasjen në vendndodhjen e pajisjes mund ta kontrolloni te Cilësimet e iOS. Listimet e vendeve dhe të bizneseve mund të përfshijnë adresa, koordinata, foto, orare, të dhëna kontakti dhe informacion mbi pretendimin ose pronësinë të dorëzuar nga pronarët e vendeve."),
        ("Mesazhet, Fan Chats dhe përmbajtja e përdoruesve",
         "FanGeo përpunon përmbajtjen e krijuar nga përdoruesit, si mesazhet e drejtpërdrejta, bisedat private, Fan Chats, komentet, postimet për vende/ngjarje, fotot, raportimet dhe të dhënat përkatëse ndihmëse, që aplikacioni të mund të ofrojë bisedat, të ruajë kontekstin e temave, të zbatojë rregullat e sigurisë, të hetojë abuzimet dhe të ruajë integritetin e shërbimit."),
        ("Raportimet dhe moderimi",
         "Kur raportoni një përdorues, koment, mesazh, bisedë, vend ose përmbajtje tjetër, ne përpunojmë raportimin tuaj, arsyen e zgjedhur, detajet opsionale, përmbajtjen e raportuar, kontekstin e mesazhit ose të bisedës kur mbështetet, vulat kohore, identifikuesit e llogarisë dhe statusin e moderimit. Regjistrimet e moderimit mund të ruhen për të mbrojtur përdoruesit, për të zbatuar rregullat dhe për të përmbushur detyrimet ligjore ose ato të App Store."),
        ("Reklamat, analitika dhe diagnostika",
         "FanGeo përdor Google AdMob për të shfaqur reklama. AdMob mund të marrë informacion mbi pajisjen, ndërveprimin me reklamat, vendndodhjen e përafërt dhe identifikuesin e reklamimit, në varësi të cilësimeve të pajisjes suaj dhe të zgjedhjeve tuaja të pëlqimit. FanGeo gjithashtu mund të përdorë diagnostikën e aplikacionit, regjistrat, të dhënat e performancës dhe informacionin e lidhur me përplasjet për të korrigjuar gabimet, për të parandaluar abuzimet dhe për të përmirësuar besueshmërinë. Regjistrat e korrigjimit janë menduar për operimet dhe testimin, jo për shitjen e informacionit personal."),
        ("Shërbimet e palëve të treta",
         "FanGeo mbështetet te ofrues shërbimesh si Supabase për vërtetimin, bazën e të dhënave, ruajtjen, veçoritë në kohë reale dhe funksionet edge; Google AdMob për reklamat; shërbimet e platformës Apple; dhe ofrues të të dhënave sportive si TheSportsDB për oraret dhe të dhënat e ndeshjeve drejtpërdrejt. Këta ofrues i përpunojnë të dhënat sa është e nevojshme për të ofruar shërbimet e tyre."),
        ("Fshirja e llogarisë",
         "Fshirja e llogarisë suaj heq ose anonimizon profilin tuaj publik dhe preferencat tuaja personale. Disa mesazhe, komente, raportime dhe regjistrime moderimi mund të ruhen dhe të shfaqen si «Deleted User» për të ruajtur integritetin e bisedave, sigurinë dhe regjistrimet ligjore/të përputhshmërisë. Llogaritë e fshira nuk mund të hyjnë sërish, përveçse nëse mbështetja e FanGeo e rikthen ose e riaktivizon llogarinë."),
        ("Ruajtja e të dhënave",
         "Ne i ruajmë të dhënat e llogarisë dhe të aplikacionit për aq kohë sa është e nevojshme për të operuar FanGeo, për të ofruar veçoritë e kërkuara, për të parandaluar abuzimet, për të zgjidhur mosmarrëveshjet, për të respektuar ligjin dhe për të mbajtur regjistrimet e sigurisë. Periudhat e ruajtjes ndryshojnë sipas llojit të të dhënave. Përmbajtja publike ose e ndarë mund të mbetet pas fshirjes kur është e nevojshme për të ruajtur bisedat, raportimet, historikun e moderimit, regjistrimet e vendeve, pretendimet e bizneseve ose regjistrimet ligjore/të përputhshmërisë."),
        ("Kontakti",
         "Për pyetje mbi privatësinë ose fshirjen, kontaktoni support@fangeosports.com ose përdorni kanalin e mbështetjes të disponueshëm në aplikacion."),
    ],
    [
        ("Përmbledhje",
         "Këto Kushte të Shërbimit rregullojnë përdorimin tuaj të FanGeo. Duke përdorur aplikacionin, duke krijuar një llogari, duke postuar përmbajtje, duke dërguar mesazhe, duke dorëzuar raportime, duke pretenduar një vend ose duke menaxhuar një listim biznesi, ju pranoni t'i respektoni këto kushte."),
        ("Standardet e komunitetit dhe përdorimi i pranueshëm",
         "FanGeo ka tolerancë zero ndaj përmbajtjes së papranueshme ose përdoruesve abuzivë. Përdoruesit nuk mund të postojnë, ngarkojnë, dërgojnë ose ndajnë përmbajtje që përfshin ngacmim, gjuhë urrejtjeje, kërcënime, bullizëm, shfrytëzim seksual, përmbajtje të paligjshme, spam, imitim identiteti, sjellje abuzive ose material tjetër të papranueshëm.\n\nPërdoruesit mund të raportojnë në aplikacion përmbajtjen e papranueshme ose përdoruesit abuzivë. FanGeo mund të heqë përmbajtje, të kufizojë qasjen, të pezullojë llogari ose të mbyllë përgjithmonë llogaritë që shkelin këto Kushte ose Udhëzimet e Komunitetit."),
        ("Përdorimi i pranueshëm",
         "Përdoreni FanGeo vetëm për qëllime të ligjshme, personale dhe të ligjshme të listimit të bizneseve. Mos e keqpërdorni shërbimin, mos dërgoni spam, mos kryeni scraping, crawling ose grumbullim të dhënash, mos manipuloni pjesëmarrjen ose vlerësimet, mos ndërhyni në sigurinë e aplikacionit, mos anashkaloni kontrollet e qasjes dhe mos u përpiqni të qaseni në llogari, mesazhe, raportime, mjete administrimi, mjete për vendet ose të dhëna që nuk jeni të autorizuar t'i përdorni."),
        ("Përmbajtja e përdoruesit",
         "Ju jeni përgjegjës për përmbajtjen që krijoni, ngarkoni, dërgoni ose dorëzoni, përfshirë detajet e profilit, avatarët, Fan Chats, mesazhet e drejtpërdrejta, raportimet, aktivitetin e ndeshjeve të lira, fotot e vendeve, informacionin e biznesit dhe oraret e ndeshjeve të vendeve. Ju i ruani të drejtat tuaja të pronësisë, por i jepni FanGeo lejen për të strehuar, shfaqur, ruajtur, moderuar, riprodhuar dhe shpërndarë përmbajtjen tuaj sa është e nevojshme për të operuar, përmirësuar dhe mbrojtur shërbimin."),
        ("Pa ngacmim ose sjellje të pasigurt",
         "Rivaliteti sportiv dhe debati me pasion janë të mirëpritur. Ngacmimi, kërcënimet, gjuha e urrejtjes, doxxing, shfrytëzimi seksual, abuzimi i synuar, imitimi i identitetit, ndjekja obsesive, mashtrimet dhe nxitja e sjelljeve të paligjshme ose të pasigurta nuk lejohen. Mos e përdorni FanGeo për të organizuar takime të pasigurta ose për të ushtruar presion mbi përdoruesit që të ndajnë informacion privat."),
        ("Pretendimet për vende dhe biznese",
         "Nëse pretendoni ose menaxhoni një vend, një llogari biznesi ose një vendndodhje, ju konfirmoni se jeni të autorizuar ta bëni këtë dhe se informacioni që dorëzoni është i saktë. FanGeo mund të shqyrtojë, refuzojë, miratojë, arkivojë, heqë ose kufizojë pretendimet ose listimet e vendeve dhe të bizneseve që janë të pasakta, mashtruese, të dyfishta, të pasigurta, joaktive ose që shkelin këto kushte."),
        ("Moderimi dhe zbatimi",
         "FanGeo mund të shqyrtojë raportimet, të heqë ose fshehë përmbajtje, të kufizojë veçori, të bllokojë qasjen, të pezullojë llogari, të fshijë llogari, të ruajë regjistrime ose të marrë masa të tjera kur besojmë se këto kushte, Udhëzimet e Komunitetit, rregullat e sigurisë, ligji ose kërkesat e App Store janë shkelur. Ne gjithashtu mund të ruajmë përmbajtje ose regjistrime kur është e nevojshme për arsye sigurie, përputhshmërie, zgjidhjeje mosmarrëveshjesh ose arsye ligjore."),
        ("Kufizimet e aplikacionit",
         "FanGeo ofrohet «ashtu siç është» në masën e lejuar nga ligji. Ne nuk garantojmë shërbim të pandërprerë, të dhëna të sakta për vendet, orare të plota sportive, disponueshmëri reklamash, rezultate raportimesh, apo që çdo përdorues ose vend do të veprojë në mënyrë të sigurt. Veçoritë mund të ndryshojnë, të kufizohen ose të ndërpriten."),
    ],
    [
        ("Rivaliteti sportiv është në rregull; abuzimi jo",
         "Tifoni fort, debatoni për ekipet dhe bëni shaka për rezultatin, por mos i sulmoni njerëzit me ngacmim, kërcënime, gjuhë urrejtjeje, ofendime, bullizëm, ndjekje obsesive, komente seksuale ose kontakt të përsëritur të padëshiruar."),
        ("Nuk lejohet",
         "- Ngacmimi, bullizmi, kërcënimet ose abuzimi i synuar\n- Gjuha e urrejtjes, racizmi, ofendimet ose diskriminimi\n- Doxxing, ndarja e informacionit privat ose ushtrimi i presionit mbi përdoruesit që të zbulojnë të dhëna personale\n- Imitimi i identitetit të përdoruesve, vendeve, ekipeve, ligave, FanGeo ose figurave publike\n- Spam, mashtrime, phishing, promocione të rreme, scraping ose postime të përsëritura shqetësuese\n- Sjellje e pasigurt në takime, detyrim, ndjekje obsesive ose nxitje e dhunës apo veprimeve të paligjshme\n- Shfrytëzimi seksual, përmbajtje eksplicite ose përmbajtje që përfshin të mitur"),
        ("Fan Chats dhe komentet",
         "Mbajini Fan Chats dhe komentet për vendet/ngjarjet të dobishme për tifozerinë sportive vendore. Mos i shmangni temat me spam, sulme personale, informacion të rremë për vendet ose abuzim të koordinuar. Komentet mund të fshihen, hiqen ose shqyrtohen kur raportohen ose kur duket se shkelin këto udhëzime."),
        ("DMs dhe ndërveprimet me miqtë",
         "Mesazhet e drejtpërdrejta janë për bisedë të respektueshme me njerëzit që kanë pranuar një lidhje miqësie. Mos dërgoni mesazhe abuzive, kërcënuese, seksuale, mashtruese, spam ose mesazhe të përsëritura të padëshiruara. Nëse dikush ju kërkon të ndaloni, ndaloni."),
        ("Raporto dhe blloko",
         "Raportoni përdoruesit, komentet, mesazhet ose bisedat abuzive duke përdorur mjetet e raportimit brenda aplikacionit ku janë të disponueshme. Bllokoni përdoruesit që nuk duhet t'ju kontaktojnë. Raportimet e ndihmojnë FanGeo të shqyrtojë çështjet e sigurisë, por ato duhet të jenë të vërteta dhe të bëra në mirëbesim."),
        ("Zbatimi",
         "FanGeo mund të paralajmërojë përdoruesit, të heqë përmbajtje, të fshehë komente, të kufizojë mesazhimin, të pezullojë llogari, të fshijë llogari, të ruajë raportime ose të marrë masa të tjera në varësi të rëndësisë, kontekstit dhe sjelljes së përsëritur."),
        ("Marrëveshja juaj",
         "Duke përdorur FanGeo, ju pranoni t'i ndiqni këto udhëzime dhe të ndihmoni në ruajtjen e një komuniteti sportiv me respekt."),
    ],
    [
        ("Përmbledhje",
         "Siguria juaj ka rëndësi. FanGeo ofron mjete raportimi dhe bllokimi për sjellje abuzive, UGC, DMs, Fan Chats, komente, biseda dhe çështje të lidhura me vendet ku mbështeten në aplikacion. Raportimet shqyrtohen sipas Udhëzimeve të Komunitetit të FanGeo."),
        ("Çfarë mund të raportoni",
         "Përdorni veprimet e raportimit ose të shënjimit brenda aplikacionit ku janë të disponueshme, përfshirë raportimet e përdoruesve, komentet e Fan Chats, mesazhet e drejtpërdrejta, bisedat, listimet e vendeve dhe përmbajtjen e vendeve/ngjarjeve. Detajet e qarta dhe të sakta i ndihmojnë moderatorët të kuptojnë se çfarë ndodhi."),
        ("Komentet dhe përditësimet e tifozëve",
         "Çdo përdorues mund të ketë një raportim aktiv për koment. Ju mund të hiqni një raportim aksidental duke prekur sërish flamurin e kuq para se të zbatohen pragjet. Raportime të shumta aktive unike mund të nxisin fshehjen automatike nga pamja publike ndërsa përmbajtja shqyrtohet. Nëse një koment është fshehur tashmë automatikisht, heqja e një raportimi nuk e rikthen atë automatikisht."),
        ("Raportimi i bisedave private",
         "Nga një bisedë e drejtpërdrejtë, ju mund të raportoni bisedën ose përmbajtjen e mbështetur të mesazhit për shqyrtim nga moderatori. Raportimet e DMs mund të përfshijnë vetëm dritaren e zgjedhur të shqyrtimit, së bashku me të dhënat përkatëse ndihmëse të nevojshme për të vlerësuar raportimin. Dorëzimi i një raportimi nuk e ndalon automatikisht një përdorues, nuk fshin mesazhet, nuk e fsheh bisedën dhe nuk njofton personin që raportuat. FanGeo mund të zbatojë periudha pritjeje, kufizime për raportimet e dyfishta dhe kontrolle për parandalimin e abuzimeve."),
        ("Bllokimi",
         "Përdoruesit mund të bllokojnë përdorues të tjerë që të ndërveprojnë me ta atje ku bllokimi mbështetet, përfshirë sipërfaqet e bisedës së drejtpërdrejtë. Bllokimi kufizon kontaktin e padëshiruar në FanGeo; ai nuk e pengon dikë të ju kontaktojë jashtë FanGeo."),
        ("Shqyrtimi i moderimit",
         "Shqyrtimi i moderimit mund të përfshijë detajet e raportimit, identifikuesit e llogarisë së raportuesit dhe të të raportuarit, vulat kohore, arsyet e zgjedhura, komentet ose mesazhet e raportuara, kontekstin e kufizuar përreth, vendimet e moderimit dhe regjistrimet e nevojshme për sigurinë ose përputhshmërinë. Regjistrimet e moderimit mund të ruhen për arsye sigurie. Moderatorët mund të paralajmërojnë përdoruesit, të fshehin ose fshijnë përmbajtje, të kufizojnë veçori, të kufizojnë përdoruesit abuzivë, të pezullojnë llogari, të fshijnë llogari ose të ruajnë regjistrime në varësi të rëndësisë dhe sjelljes së përsëritur."),
        ("Përputhshmëria me App Store",
         "FanGeo përfshin mekanizma raportimi brenda aplikacionit dhe përshkallëzimi të moderimit për UGC dhe mesazhimin privat. Përdoruesit mund të bllokojnë përdorues të tjerë që të ndërveprojnë me ta atje ku bllokimi mbështetet në aplikacion."),
        ("Emergjencat",
         "Nëse ju ose dikush tjetër jeni në rrezik të menjëhershëm, kontaktoni menjëherë shërbimet vendore të emergjencës. FanGeo nuk është shërbim krize dhe nuk mund të zëvendësojë policinë, ndihmën mjekësore ose ndërhyrës të tjerë të emergjencës."),
    ],
)

# ---------------------------------------------------------------------------
# SIMPLIFIED CHINESE (zh-Hans)
# ---------------------------------------------------------------------------
LANGUAGES["zh-Hans"] = build(
    "最后更新：2026年6月18日",
    [
        ("概述",
         "本隐私政策说明当您使用 FanGeo 应用时，FanGeo 如何收集、使用、共享和保留信息。"),
        ("账户和个人资料数据",
         "我们会收集您为账户提供或创建的信息，例如电子邮件地址、显示名称、用户名、简介、头像、身份验证标识符、喜爱的球队、已保存的场所、已保存的比赛、到场/兴趣信号、通知偏好、实时可见性设置、屏蔽、举报以及类似的个人资料或偏好数据。"),
        ("位置与发现",
         "FanGeo 可能会使用您的设备位置、地图区域、搜索的城市或场所位置，向您展示附近的体育酒吧、比赛、临时约球活动以及本地球迷动态。您可以在 iOS 设置中控制设备位置访问权限。场所和商家信息可能包括地址、坐标、照片、营业时间、联系方式，以及由场所所有者提交的认领或所有权信息。"),
        ("消息、Fan Chats 和用户内容",
         "FanGeo 会处理用户生成的内容，例如私信、私密对话、Fan Chats、评论、场所/活动帖子、照片、举报及相关元数据，以便应用能够传送对话、保留话题上下文、执行安全规则、调查滥用行为并维护服务的完整性。"),
        ("举报与审核",
         "当您举报某位用户、评论、消息、对话、场所或其他内容时，我们会处理您的举报、所选原因、可选的详细说明、被举报的内容、在受支持时的消息或对话上下文、时间戳、账户标识符以及审核状态。审核记录可能会被保留，以保护用户、执行规则并遵守法律或 App Store 义务。"),
        ("广告、分析与诊断",
         "FanGeo 使用 Google AdMob 展示广告。根据您的设备设置和同意选择，AdMob 可能会接收设备、广告互动、大致位置和广告标识符信息。FanGeo 还可能使用应用诊断、日志、性能数据和崩溃相关信息来进行调试、防止滥用并提升可靠性。调试日志用于运营和测试，而非出售个人信息。"),
        ("第三方服务",
         "FanGeo 依赖服务提供商，例如用于身份验证、数据库、存储、实时功能和边缘函数的 Supabase；用于广告的 Google AdMob；Apple 平台服务；以及用于赛程和实时比赛数据的体育数据提供商，例如 TheSportsDB。这些提供商会按其提供服务所需的范围处理数据。"),
        ("账户删除",
         "删除账户会移除或匿名化您的公开个人资料和个人偏好。为保持对话完整性、安全性以及法律/合规记录，某些消息、评论、举报和审核记录可能会被保留，并显示为“Deleted User”。除非 FanGeo 支持团队恢复或重新激活该账户，否则已删除的账户无法重新登录。"),
        ("数据保留",
         "在为运营 FanGeo、提供所请求的功能、防止滥用、解决争议、遵守法律以及保存安全记录所需的期间内，我们会保留账户和应用数据。保留期限因数据类型而异。当有必要保留对话、举报、审核历史、场所记录、商家认领或法律/合规记录时，公开或共享的内容在删除后仍可能保留。"),
        ("联系方式",
         "如有隐私或删除方面的问题，请联系 support@fangeosports.com，或使用应用内提供的支持渠道。"),
    ],
    [
        ("概述",
         "本服务条款约束您对 FanGeo 的使用。使用本应用、创建账户、发布内容、发送消息、提交举报、认领场所或管理商家信息，即表示您同意遵守这些条款。"),
        ("社区标准与可接受使用",
         "FanGeo 对令人反感的内容或滥用行为的用户采取零容忍政策。用户不得发布、上传、发送或分享包含骚扰、仇恨言论、威胁、欺凌、性剥削、非法内容、垃圾信息、冒充、辱骂行为或其他令人反感材料的内容。\n\n用户可在应用内举报令人反感的内容或滥用行为的用户。对于违反本条款或社区准则的账户，FanGeo 可移除内容、限制访问、暂停账户或永久终止账户。"),
        ("可接受使用",
         "请仅将 FanGeo 用于合法、个人以及正当的商家信息用途。请勿滥用本服务、发送垃圾信息、进行抓取、爬取或收集数据、操纵到场人数或评分、干扰应用安全、绕过访问控制，或试图访问您无权使用的账户、消息、举报、管理工具、场所工具或数据。"),
        ("用户内容",
         "您对自己创建、上传、发送或提交的内容负责，包括个人资料信息、头像、Fan Chats、私信、举报、临时约球活动、场所照片、商家信息以及场所比赛赛程。您保留自己的所有权，但您授予 FanGeo 权限，以按运营、改进和保护本服务所需的范围托管、展示、存储、审核、复制和分发您的内容。"),
        ("禁止骚扰或不安全行为",
         "欢迎体育竞争和热烈辩论。不得进行骚扰、威胁、仇恨言论、人肉搜索、性剥削、针对性辱骂、冒充、跟踪、诈骗，以及鼓动非法或不安全的行为。请勿使用 FanGeo 组织不安全的见面，或施压用户分享私人信息。"),
        ("场所与商家认领",
         "如果您认领或管理某个场所、商家账户或位置，即表示您确认自己有权这样做，且您提交的信息准确无误。对于不准确、欺诈、重复、不安全、不活跃或违反本条款的场所和商家认领或信息，FanGeo 可进行审查、拒绝、批准、归档、移除或限制。"),
        ("审核与执行",
         "当我们认为本条款、社区准则、安全规则、法律或 App Store 要求已被违反时，FanGeo 可审查举报、移除或隐藏内容、限制功能、屏蔽访问、暂停账户、删除账户、保留记录或采取其他措施。出于安全、合规、争议解决或法律原因需要时，我们也可保留内容或记录。"),
        ("应用限制",
         "在法律允许的范围内，FanGeo 按“现状”提供。我们不保证服务不中断、场所数据精确、体育赛程完整、广告可用、举报结果，也不保证每位用户或每个场所都会安全行事。功能可能会更改、受到限制或停止提供。"),
    ],
    [
        ("体育竞争可以，但不得滥用",
         "尽情呐喊、争论球队，围绕比分互相调侃都没问题，但不得以骚扰、威胁、仇恨言论、辱骂、欺凌、跟踪、性评论或反复的不受欢迎的联系针对他人。"),
        ("不允许",
         "- 骚扰、欺凌、威胁或针对性辱骂\n- 仇恨言论、种族主义、辱骂或歧视\n- 人肉搜索、分享私人信息或施压用户透露个人资料\n- 冒充用户、场所、球队、联赛、FanGeo 或公众人物\n- 垃圾信息、诈骗、网络钓鱼、虚假促销、抓取或反复的扰乱性帖子\n- 不安全的见面行为、胁迫、跟踪或鼓动暴力或非法行为\n- 性剥削、露骨内容或涉及未成年人的内容"),
        ("Fan Chats 与评论",
         "请让 Fan Chats 以及场所/活动评论对本地体育人群保持有用。请勿以垃圾信息、人身攻击、虚假场所信息或有组织的滥用行为扰乱话题。当评论被举报或看似违反这些准则时，可能会被隐藏、移除或审查。"),
        ("私信与好友互动",
         "私信用于与已接受好友关系的人进行相互尊重的交流。请勿发送辱骂、威胁、性、诈骗、垃圾或反复的不受欢迎的消息。如果有人请您停止，请停止。"),
        ("举报与屏蔽",
         "在提供相应功能的地方，请使用应用内举报工具举报滥用行为的用户、评论、消息或对话。屏蔽不应联系您的用户。举报有助于 FanGeo 审查安全问题，但举报应真实并出于善意。"),
        ("执行",
         "FanGeo 可根据严重程度、情境和重复行为，警告用户、移除内容、隐藏评论、限制消息发送、暂停账户、删除账户、保留举报或采取其他措施。"),
        ("您的同意",
         "使用 FanGeo，即表示您同意遵守这些准则，并帮助维护一个相互尊重的体育社区。"),
    ],
    [
        ("概述",
         "您的安全很重要。在应用支持的范围内，FanGeo 为滥用行为、UGC、DMs、Fan Chats、评论、对话以及与场所相关的问题提供举报和屏蔽工具。举报会依据 FanGeo 的社区准则进行审查。"),
        ("您可以举报的内容",
         "在提供相应功能的地方，请使用应用内的举报或标记操作，包括用户举报、Fan Chat 评论、私信、对话、场所信息以及场所/活动内容。清晰、准确的细节有助于审核人员了解所发生的情况。"),
        ("评论与球迷动态",
         "每位用户对每条评论可有一个有效举报。在阈值生效之前，您可以再次点按红色旗标来撤销误操作的举报。多个不同的有效举报可能会在内容接受审查期间触发从公开视图中自动隐藏。如果某条评论已被自动隐藏，撤销举报不会自动将其恢复。"),
        ("私密对话举报",
         "在私聊中，您可以举报对话或受支持的消息内容，以供审核人员审查。DM 举报可能仅包含所选的审查时间范围，以及评估该举报所需的相关元数据。提交举报不会自动封禁用户、删除消息、隐藏聊天或通知被举报者。FanGeo 可能会施加冷却期、重复举报限制以及防滥用检查。"),
        ("屏蔽",
         "在支持屏蔽的地方（包括私聊界面），用户可以屏蔽其他用户，使其无法与自己互动。屏蔽可限制在 FanGeo 内的不受欢迎联系；但无法阻止他人在 FanGeo 之外与您联系。"),
        ("审核审查",
         "审核审查可能包括举报详情、举报者和被举报者的账户标识符、时间戳、所选原因、被举报的评论或消息、有限的周边上下文、审核决定，以及为安全或合规所需的记录。审核记录可能出于安全原因予以保留。审核人员可根据严重程度和重复行为，警告用户、隐藏或删除内容、限制功能、限制滥用行为的用户、暂停账户、删除账户或保留记录。"),
        ("App Store 合规",
         "FanGeo 针对 UGC 和私密消息包含应用内举报和审核升级机制。在应用支持屏蔽的地方，用户可以屏蔽其他用户，使其无法与自己互动。"),
        ("紧急情况",
         "如果您或他人处于紧急危险之中，请立即联系当地紧急服务。FanGeo 不是危机服务，无法替代警察、医疗或其他紧急救援人员。"),
    ],
)


def main():
    written = []
    for lang, data in LANGUAGES.items():
        path = os.path.join(OUT_DIR, f"legal_{lang}.json")
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.write("\n")
        written.append(path)

    # Verify against English section counts.
    with open(os.path.join(OUT_DIR, "legal_en.json"), encoding="utf-8") as f:
        en = json.load(f)
    en_counts = {k: len(en["documents"][k]) for k in DOC_KEYS}

    print("English section counts:", en_counts)
    print()
    header = f"{'lang':10} | " + " | ".join(f"{k}" for k in DOC_KEYS) + " | OK"
    print(header)
    print("-" * len(header))
    all_ok = True
    for lang in LANGUAGES:
        path = os.path.join(OUT_DIR, f"legal_{lang}.json")
        with open(path, encoding="utf-8") as f:
            d = json.load(f)  # validates JSON
        counts = {k: len(d["documents"][k]) for k in DOC_KEYS}
        ok = counts == en_counts
        all_ok = all_ok and ok
        row = f"{lang:10} | " + " | ".join(f"{counts[k]:>{len(k)}}" for k in DOC_KEYS) + f" | {'yes' if ok else 'NO'}"
        print(row)

    print()
    print("Files written:")
    for p in written:
        print(" ", p)
    print()
    print("ALL COUNTS MATCH ENGLISH:", all_ok)
    if not all_ok:
        raise SystemExit("Section count mismatch!")


if __name__ == "__main__":
    main()
