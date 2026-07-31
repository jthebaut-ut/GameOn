import Foundation
import MapKit

/// Shared hometown (home city / region / country) display + MapKit parse helpers.
///
/// Storage remains structured `home_city` / `home_region` / `home_country` (prefer ISO country
/// codes when available). Display is always rebuilt here so the profile editor and public
/// profile never format the same hometown differently.
enum ProfileHomeCityIdentity {
    static func displayLine(
        city: String?,
        region: String?,
        country: String?,
        languageCode: String? = nil
    ) -> String? {
        let trimmedCity = trimmed(city)
        guard !trimmedCity.isEmpty else { return nil }

        let resolvedLanguage = L10n.normalizedLanguageCode(
            languageCode ?? UserDefaults.standard.string(forKey: L10n.appLanguageKey)
        )
        let trimmedRegion = trimmed(region)
        let trimmedCountry = trimmed(country)

        let inferredCountryCode = resolveCountryCode(
            storedCountry: trimmedCountry,
            region: trimmedRegion
        )
        let displayRegion = localizedRegionName(
            trimmedRegion,
            countryCode: inferredCountryCode,
            languageCode: resolvedLanguage
        )
        let displayCountry = localizedCountryName(
            storedCountry: trimmedCountry,
            inferredCountryCode: inferredCountryCode,
            languageCode: resolvedLanguage
        )

        if !displayRegion.isEmpty, !displayCountry.isEmpty {
            return "\(trimmedCity), \(displayRegion), \(displayCountry)"
        }
        if !displayRegion.isEmpty {
            return "\(trimmedCity), \(displayRegion)"
        }
        if !displayCountry.isEmpty {
            return "\(trimmedCity), \(displayCountry)"
        }
        return trimmedCity
    }

    static func parse(
        mapItem: MKMapItem,
        languageCode: String? = nil
    ) -> (city: String, region: String, country: String, display: String) {
        let city: String
        let region: String
        let country: String

        if #available(iOS 26.0, *) {
            let parsed = parseModern(mapItem: mapItem)
            city = parsed.city
            region = parsed.region
            country = parsed.country
        } else {
            city = trimmed(mapItem.placemark.locality).ifEmpty(fallback: trimmed(mapItem.name))
            let iso = trimmed(mapItem.placemark.countryCode)
            region = expandRegionAbbreviationIfNeeded(
                trimmed(mapItem.placemark.administrativeArea),
                countryCode: iso.uppercased()
            )
            country = preferredStoredCountry(
                isoCode: iso,
                countryName: trimmed(mapItem.placemark.country)
            )
        }

        let display = displayLine(
            city: city,
            region: region,
            country: country,
            languageCode: languageCode
        ) ?? city
        return (city: city, region: region, country: country, display: display)
    }

    // MARK: - Country-only public display (Suggested Fans, etc.)

    /// Privacy-safe country chip: localized name + optional flag from stored home_country.
    /// Callers must only pass countries already gated for public display (`show_home_city`).
    static func displayableHomeCountry(
        storedCountry: String?,
        languageCode: String? = nil
    ) -> (isoCode: String?, flagEmoji: String?, localizedName: String)? {
        let trimmedCountry = trimmed(storedCountry)
        guard !trimmedCountry.isEmpty else { return nil }

        let resolvedLanguage = L10n.normalizedLanguageCode(
            languageCode ?? UserDefaults.standard.string(forKey: L10n.appLanguageKey)
        )
        let isoCode = resolveCountryCode(storedCountry: trimmedCountry, region: "")
        let localizedName = localizedCountryName(
            storedCountry: trimmedCountry,
            inferredCountryCode: isoCode,
            languageCode: resolvedLanguage
        )
        guard !localizedName.isEmpty else { return nil }

        let flag: String?
        if let isoCode {
            let emoji = CountryFlagHelper.flagEmoji(forRegionCode: isoCode)
            flag = emoji.isEmpty ? nil : emoji
        } else {
            flag = nil
        }
        return (isoCode: isoCode, flagEmoji: flag, localizedName: localizedName)
    }

    // MARK: - Country / region display

    /// Prefer ISO region codes for storage; accept legacy English country names.
    private static func preferredStoredCountry(isoCode: String, countryName: String) -> String {
        let code = isoCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if isISOCountryCode(code) {
            return code
        }
        if let mapped = CountryFlagHelper.countryCode(for: countryName) {
            return mapped
        }
        if let fromEnglish = countryCodeFromKnownEnglishName(countryName) {
            return fromEnglish
        }
        return trimmed(countryName)
    }

    private static func isISOCountryCode(_ code: String) -> Bool {
        guard code.count == 2 else { return false }
        return Locale.Region.isoRegions.contains { $0.identifier == code }
    }

    private static func resolveCountryCode(storedCountry: String, region: String) -> String? {
        if !storedCountry.isEmpty {
            let upper = storedCountry.uppercased()
            if isISOCountryCode(upper) {
                return upper
            }
            if let fromName = CountryFlagHelper.countryCode(for: storedCountry) {
                return fromName
            }
            if let fromCatalog = countryCodeFromKnownEnglishName(storedCountry) {
                return fromCatalog
            }
        }

        // Safe display-only inference from known admin areas (does not mutate storage).
        // Only infer when the region token cannot also be read as an ISO country code
        // (e.g. "UT" → US is safe; "CA" is ambiguous with Canada).
        if let inferred = inferredCountryCodeFromRegionAlone(region) {
            return inferred
        }
        return nil
    }

    private static func inferredCountryCodeFromRegionAlone(_ region: String) -> String? {
        let trimmedRegion = trimmed(region)
        guard !trimmedRegion.isEmpty else { return nil }
        let upper = trimmedRegion.uppercased()

        if usStateDisplayName(for: trimmedRegion) != nil {
            if upper.count == 2 {
                // Two-letter US state that is not also an ISO country (UT, TX, NY, …).
                if USStatesForBusinessLocation.validCodes.contains(upper), !isISOCountryCode(upper) {
                    return "US"
                }
            } else if CountryFlagHelper.countryCode(for: trimmedRegion) == nil,
                      countryCodeFromKnownEnglishName(trimmedRegion) == nil {
                // Full name like "Utah" (skip ambiguous names like "Georgia").
                return "US"
            }
        }

        if canadianProvinceEnglishName(for: trimmedRegion) != nil {
            if upper.count == 2 {
                if !isISOCountryCode(upper) {
                    return "CA"
                }
            } else if CountryFlagHelper.countryCode(for: trimmedRegion) == nil,
                      countryCodeFromKnownEnglishName(trimmedRegion) == nil {
                return "CA"
            }
        }
        return nil
    }

    private static func localizedCountryName(
        storedCountry: String,
        inferredCountryCode: String?,
        languageCode: String
    ) -> String {
        let locale = Locale(identifier: languageCode)

        if let code = inferredCountryCode, !code.isEmpty {
            if let localized = locale.localizedString(forRegionCode: code)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !localized.isEmpty {
                return localized
            }
            let englishName = Locale(identifier: "en_US").localizedString(forRegionCode: code) ?? code
            let fromCatalog = L10n.t(englishName, languageCode: languageCode)
            if fromCatalog != englishName || fromCatalog != code {
                return fromCatalog
            }
        }

        guard !storedCountry.isEmpty else { return "" }

        let fromCatalog = L10n.t(storedCountry, languageCode: languageCode)
        if fromCatalog != storedCountry {
            return fromCatalog
        }
        if let regionCode = CountryFlagHelper.countryCode(for: storedCountry)
            ?? countryCodeFromKnownEnglishName(storedCountry),
           let localized = locale.localizedString(forRegionCode: regionCode)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !localized.isEmpty {
            return localized
        }
        return storedCountry
    }

    private static func localizedRegionName(
        _ region: String,
        countryCode: String?,
        languageCode: String
    ) -> String {
        guard !region.isEmpty else { return "" }
        let code = (countryCode ?? "").uppercased()

        if let usName = usStateDisplayName(for: region) {
            if code == "US" { return usName }
            if code.isEmpty, inferredCountryCodeFromRegionAlone(region) == "US" {
                return usName
            }
        }
        if let english = canadianProvinceEnglishName(for: region) {
            if code == "CA" {
                return localizeCanadianProvince(english: english, languageCode: languageCode)
            }
            if code.isEmpty, inferredCountryCodeFromRegionAlone(region) == "CA" {
                return localizeCanadianProvince(english: english, languageCode: languageCode)
            }
        }
        return region
    }

    private static func expandRegionAbbreviationIfNeeded(_ region: String, countryCode: String) -> String {
        guard !region.isEmpty else { return "" }
        let code = countryCode.uppercased()
        if let usName = usStateDisplayName(for: region) {
            if code == "US" { return usName }
            if code.isEmpty, inferredCountryCodeFromRegionAlone(region) == "US" {
                return usName
            }
        }
        if let english = canadianProvinceEnglishName(for: region) {
            if code == "CA" || (code.isEmpty && inferredCountryCodeFromRegionAlone(region) == "CA") {
                return english
            }
        }
        return region
    }

    private static func usStateDisplayName(for region: String) -> String? {
        let trimmedRegion = trimmed(region)
        guard !trimmedRegion.isEmpty else { return nil }
        let upper = trimmedRegion.uppercased()
        if upper.count == 2,
           let match = USStatesForBusinessLocation.abbreviationsSortedByName.first(where: { $0.0 == upper }) {
            return match.1
        }
        if let match = USStatesForBusinessLocation.abbreviationsSortedByName.first(where: {
            $0.1.caseInsensitiveCompare(trimmedRegion) == .orderedSame
        }) {
            return match.1
        }
        return nil
    }

    private static func canadianProvinceEnglishName(for region: String) -> String? {
        let trimmedRegion = trimmed(region)
        guard !trimmedRegion.isEmpty else { return nil }

        let codeMap: [String: String] = [
            "AB": "Alberta",
            "BC": "British Columbia",
            "MB": "Manitoba",
            "NB": "New Brunswick",
            "NL": "Newfoundland and Labrador",
            "NS": "Nova Scotia",
            "NT": "Northwest Territories",
            "NU": "Nunavut",
            "ON": "Ontario",
            "PE": "Prince Edward Island",
            "QC": "Quebec",
            "SK": "Saskatchewan",
            "YT": "Yukon"
        ]
        if let byCode = codeMap[trimmedRegion.uppercased()] {
            return byCode
        }

        let folded = trimmedRegion
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en"))
        let nameMap: [String: String] = [
            "alberta": "Alberta",
            "british columbia": "British Columbia",
            "manitoba": "Manitoba",
            "new brunswick": "New Brunswick",
            "newfoundland and labrador": "Newfoundland and Labrador",
            "nova scotia": "Nova Scotia",
            "northwest territories": "Northwest Territories",
            "nunavut": "Nunavut",
            "ontario": "Ontario",
            "prince edward island": "Prince Edward Island",
            "quebec": "Quebec",
            "saskatchewan": "Saskatchewan",
            "yukon": "Yukon"
        ]
        return nameMap[folded]
    }

    private static func localizeCanadianProvince(english: String, languageCode: String) -> String {
        let lang = L10n.normalizedLanguageCode(languageCode)
        guard lang == "fr" else { return english }
        let french: [String: String] = [
            "Alberta": "Alberta",
            "British Columbia": "Colombie-Britannique",
            "Manitoba": "Manitoba",
            "New Brunswick": "Nouveau-Brunswick",
            "Newfoundland and Labrador": "Terre-Neuve-et-Labrador",
            "Nova Scotia": "Nouvelle-Écosse",
            "Northwest Territories": "Territoires du Nord-Ouest",
            "Nunavut": "Nunavut",
            "Ontario": "Ontario",
            "Prince Edward Island": "Île-du-Prince-Édouard",
            "Quebec": "Québec",
            "Saskatchewan": "Saskatchewan",
            "Yukon": "Yukon"
        ]
        return french[english] ?? english
    }

    private static func countryCodeFromKnownEnglishName(_ name: String) -> String? {
        let trimmedName = trimmed(name)
        guard !trimmedName.isEmpty else { return nil }
        let english = Locale(identifier: "en_US")
        for region in Locale.Region.isoRegions {
            let code = region.identifier
            guard code.count == 2 else { continue }
            if let localized = english.localizedString(forRegionCode: code),
               localized.caseInsensitiveCompare(trimmedName) == .orderedSame {
                return code
            }
        }
        return nil
    }

    // MARK: - MapKit parse (iOS 26+)

    @available(iOS 26.0, *)
    private static func parseModern(mapItem: MKMapItem) -> (city: String, region: String, country: String) {
        let representations = mapItem.addressRepresentations
        let city = trimmed(representations?.cityName).ifEmpty(fallback: trimmed(mapItem.name))

        // Prefer ISO region code when MapKit provides it (e.g. "US").
        let isoCode = trimmed(representations?.region?.identifier).uppercased()

        // Full contextual line includes country even when the device region matches
        // (e.g. "Lehi, UT, United States"). Short `cityWithContext` omits it for locals.
        let fullContext = trimmed(representations?.cityWithContext(.full))
            .ifEmpty(fallback: trimmed(representations?.cityWithContext))

        let regionRaw = administrativeArea(from: fullContext, city: city)
            ?? administrativeArea(from: addressLines(from: mapItem, includingRegion: false), city: city)
            ?? ""

        let countryNameFallback = trimmed(representations?.regionName)
            .ifEmpty(fallback: countryName(from: fullContext, city: city) ?? "")
            .ifEmpty(
                fallback: countryName(
                    from: addressLines(from: mapItem, includingRegion: true),
                    city: city
                ) ?? ""
            )

        let country = preferredStoredCountry(isoCode: isoCode, countryName: countryNameFallback)
        let countryCodeForRegion: String = {
            if country.count == 2 { return country.uppercased() }
            return CountryFlagHelper.countryCode(for: country)
                ?? countryCodeFromKnownEnglishName(country)
                ?? ""
        }()
        let region = expandRegionAbbreviationIfNeeded(
            trimmed(regionRaw),
            countryCode: countryCodeForRegion
        )

        return (city: city, region: region, country: country)
    }

    @available(iOS 26.0, *)
    private static func addressLines(from mapItem: MKMapItem, includingRegion: Bool) -> [String] {
        let representations = mapItem.addressRepresentations
        let addressText = representations?.fullAddress(includingRegion: includingRegion, singleLine: false)
            ?? mapItem.address?.fullAddress
            ?? mapItem.address?.shortAddress
        return addressText?
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
    }

    private static func administrativeArea(from cityContext: String, city: String) -> String? {
        guard
            !cityContext.isEmpty,
            !city.isEmpty,
            cityContext.localizedCaseInsensitiveContains(city),
            let commaIndex = cityContext.firstIndex(of: ",")
        else {
            return nil
        }

        let remainder = cityContext[cityContext.index(after: commaIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // "UT" / "UT, United States" / "Utah, United States" / "UT 84043"
        let part = remainder.split(separator: ",").first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let regionToken = part.split(separator: " ").first.map(String.init) ?? part
        return regionToken.isEmpty ? nil : regionToken
    }

    private static func administrativeArea(from lines: [String], city: String?) -> String? {
        guard
            let city,
            !city.isEmpty,
            let cityLine = lines.first(where: { $0.localizedCaseInsensitiveContains(city) })
        else {
            return nil
        }
        return administrativeArea(from: cityLine, city: city)
    }

    private static func countryName(from cityContext: String, city: String) -> String? {
        guard
            !cityContext.isEmpty,
            !city.isEmpty,
            cityContext.localizedCaseInsensitiveContains(city),
            let commaIndex = cityContext.firstIndex(of: ",")
        else {
            return nil
        }

        let remainder = cityContext[cityContext.index(after: commaIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = remainder.split(separator: ",").map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard parts.count >= 2 else { return nil }
        let value = parts.last ?? ""
        return value.isEmpty ? nil : value
    }

    private static func countryName(from lines: [String], city: String?) -> String? {
        guard lines.count >= 2, let last = lines.last else { return nil }
        if let city, last.localizedCaseInsensitiveContains(city) { return nil }
        let value = trimmed(last)
        return value.isEmpty ? nil : value
    }

    private static func trimmed(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

private extension String {
    func ifEmpty(fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
