import SwiftUI

// Claude's usage panel (/usage) as Nook draws it: a card of its own in the panel's place.
//
// This file is Claude's words for the panel, in Spanish (`UsageWords`); the card itself, with all of the panel's sections at once, is in
// ClaudeUsageCard.swift. The toolbar, the keys and Esc are the panel's own (`ClaudePanelCard`).
//
// `ClaudeUsage` (the reading) is in ClaudePanel.swift; nothing here reads the screen.

/// Claude's English words for the panel, in Spanish. What Claude words in a way this does not know is shown as it is.
enum UsageWords {
    /// "Current session" → "Sesión actual"; "Current week (Sonnet only)" → "Semana actual (solo Sonnet)"; a credit's or the spend
    /// limit's title too ("Usage credits" → "Créditos de uso").
    static func title(_ title: String) -> String {
        let text = title.trimmingCharacters(in: .whitespaces)
        if text.lowercased() == "current session" { return "Sesión actual" }
        if let known = Self.limitTitles[text.lowercased()] { return known }
        guard let found = groups(#"^Current week(?: \((.+)\))?$"#, in: text) else { return text }
        guard let inner = found.first.flatMap({ $0 }) else { return "Semana actual" }
        if inner.lowercased() == "all models" { return "Semana actual (todos los modelos)" }
        if inner.lowercased().hasSuffix(" only") { return "Semana actual (solo \(inner.dropLast(5)))" }
        return "Semana actual (\(inner))"
    }

    /// "Resets Oct 6 at 6am (America/Bogota)" → "Se reinicia el 6 oct a las 6 a. m. (America/Bogota)"; "Resets 10:30am (…)" has no date.
    /// A credit's line under its bar goes part by part: "One-time credit · Expires October 13" → "Crédito único · Vence el 13 de octubre".
    static func resets(_ text: String) -> String {
        let parts = text.components(separatedBy: " · ")
        guard parts.count > 1 else { return reset(text) }
        return parts.map { reset($0.trimmingCharacters(in: .whitespaces)) }.joined(separator: " · ")
    }

    private static func reset(_ text: String) -> String {
        if let words = caption(text) { return words }
        let pattern = #"^Resets\s+(?:([A-Z][a-z]{2,3})\s+(\d{1,2})(?:,|\s+at)?\s+)?(\d{1,2})(?::(\d{2}))?\s*([ap]m)\s*(?:\(([^)]+)\))?$"#
        guard let found = groups(pattern, in: text.trimmingCharacters(in: .whitespaces)), let hour = found[2] else {
            // Words this does not know: the first one is the only one it can say with certainty.
            return text.hasPrefix("Resets ") ? "Se reinicia " + text.dropFirst(7) : text
        }
        let clock = hour + (found[3].map { ":" + $0 } ?? "") + " " + (found[4]?.lowercased() == "pm" ? "p. m." : "a. m.")
        var words = "Se reinicia"
        if let month = found[0], let day = found[1] { words += " el \(day) \(Self.months[month.prefix(3).lowercased()] ?? month.lowercased())" }
        words += " a las \(clock)"
        if let zone = found[5] { words += " (\(zone))" }
        return words
    }

    /// The number Claude prints beside the bar ("79% used") and what comes after it, in Spanish. A label it does not know stays whole.
    static func percent(_ label: String) -> (value: String, rest: String) {
        guard let found = groups(#"^(\d+(?:[.,]\d+)?)\s*%\s*used$"#, in: label.trimmingCharacters(in: .whitespaces)), let value = found[0] else { return (label, "") }
        return (value + " %", "usado")
    }

    private static let months = ["jan": "ene", "feb": "feb", "mar": "mar", "apr": "abr", "may": "may", "jun": "jun", "jul": "jul", "aug": "ago",
                                 "sep": "sep", "oct": "oct", "nov": "nov", "dec": "dic"]
    private static let fullMonths = ["jan": "enero", "feb": "febrero", "mar": "marzo", "apr": "abril", "may": "mayo", "jun": "junio", "jul": "julio",
                                     "aug": "agosto", "sep": "septiembre", "oct": "octubre", "nov": "noviembre", "dec": "diciembre"]
    private static let limitTitles = ["spend limit": "Límite de gasto", "usage credits": "Créditos de uso", "credit": "Crédito",
                                      "claude code and cowork credit": "Crédito de Claude Code y Cowork"]

    /// What a credit or the spend limit prints under its bar instead of a reset; nil for anything else.
    private static func caption(_ text: String) -> String? {
        if text == "One-time credit" { return "Crédito único" }
        if let found = groups(#"^Expires ([A-Z][a-z]+) (\d{1,2})$"#, in: text), let month = found[0], let day = found[1] {
            return "Vence el \(day) de \(fullMonths[month.prefix(3).lowercased()] ?? month)"
        }
        if let found = groups(#"^(\S+) of (\S+) used$"#, in: text), let used = found[0], let limit = found[1] { return "\(used) de \(limit) usados" }
        if let found = groups(#"^(.+?) spent(?: (this month|this week|today))?$"#, in: text), let spent = found[0] {
            let period = ["this month": " este mes", "this week": " esta semana", "today": " hoy"][found[1] ?? ""] ?? ""
            return "\(spent) gastados" + period
        }
        return nil
    }

    /// The capture groups of `pattern` over the whole of `text` (nil for a group that did not take part), or nil when it does not match.
    private static func groups(_ pattern: String, in text: String) -> [String?]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return nil }
        return (1..<max(1, match.numberOfRanges)).map { index in
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : (text as NSString).substring(with: range)
        }
    }
}

/// The words of the panel's other sections (`ClaudeUsage.session`, `.footprint`, `.insights`), in Spanish. Each takes what Claude
/// printed and gives it back unchanged when it does not know it: the card never loses a line to a translation.
extension UsageWords {
    /// A section's title: "Session" → "Sesión", "Plugin skill-listing footprint" → "Huella de las skills de los plugins",
    /// "What's contributing to your limits usage?" → "¿Qué está consumiendo tus límites?".
    static func section(_ title: String) -> String {
        let text = title.trimmingCharacters(in: .whitespaces)
        switch text.lowercased().replacingOccurrences(of: "’", with: "'") {
        case "session": return "Sesión"
        case "session (remote)": return "Sesión (remota)"
        case "plugin skill-listing footprint": return "Huella de las skills de los plugins"
        case "what's contributing to your limits usage?": return "¿Qué está consumiendo tus límites?"
        case "usage by model", "usage by model:": return "Uso por modelo"
        default: return text
        }
    }

    /// A figure of the session: "Total cost" → "Costo", "Total duration (API)" → "Tiempo en la API", "Total duration (wall)" →
    /// "Duración", "Total code changes" → "Cambios de código", "Prompt cache (main)" → "Caché de prompts (principal)".
    static func stat(_ label: String) -> String {
        let text = label.trimmingCharacters(in: .whitespaces)
        let bare = text.hasSuffix(":") ? String(text.dropLast()) : text
        switch bare.lowercased() {
        case "total cost": return "Costo"
        case "total duration (api)": return "Tiempo en la API"
        case "total duration (wall)": return "Duración"
        case "total code changes": return "Cambios de código"
        case "usage by model": return "Uso por modelo"
        case "usage": return "Uso"
        case "total web search requests": return "Búsquedas web"
        default:
            guard let found = groups(#"^Prompt cache \((.+)\)$"#, in: bare), let which = found[0] else { return bare }
            return "Caché de prompts (\(which == "main" ? "principal" : which))"
        }
    }

    /// Claude's remark after the session's cost, in Spanish where it is one it makes ("costs may be inaccurate due to usage of unknown models"); any other stays as
    /// Claude wrote it.
    static func costNote(_ note: String) -> String {
        let text = note.trimmingCharacters(in: .whitespaces)
        switch text.lowercased() {
        case "costs may be inaccurate due to usage of unknown models": return "El costo puede ser inexacto: se usaron modelos que Claude no conoce"
        default: return text
        }
    }

    /// "12 líneas añadidas, 1 eliminada".
    static func lines(added: Int, removed: Int) -> String {
        "\(added) \(added == 1 ? "línea añadida" : "líneas añadidas"), \(removed) \(removed == 1 ? "eliminada" : "eliminadas")"
    }

    /// The kind of a model's token count: "input" → "entrada", "cache read" → "lectura de caché".
    static func tokens(_ kind: String) -> String {
        ["input": "entrada", "output": "salida", "cache read": "lectura de caché", "cache write": "escritura de caché",
         "web search": "búsquedas web"][kind.lowercased()] ?? kind
    }

    /// The prompt cache's line, part by part: "22 requests · 95% of input tokens from cache · no misses · warm (1h TTL, last activity
    /// 1m 11s ago)" → "22 solicitudes · 95 % de la entrada desde la caché · sin fallos · activa (TTL de 1h, última actividad hace 1m 11s)".
    static func promptCache(_ text: String) -> String {
        text.components(separatedBy: " · ").map { part -> String in
            let part = part.trimmingCharacters(in: .whitespaces)
            if let found = groups(#"^(\d+) requests?$"#, in: part), let count = found[0] { return count == "1" ? "1 solicitud" : "\(count) solicitudes" }
            if let found = groups(#"^(\d+)% of input tokens from cache$"#, in: part), let share = found[0] { return "\(share) % de la entrada desde la caché" }
            if part == "no misses" { return "sin fallos" }
            if part == "no prompt caching reported by the API" { return "la API no informa de caché de prompts" }
            if let found = groups(#"^warm \((\S+) TTL, last activity (.+) ago\)$"#, in: part), let ttl = found[0], let idle = found[1] {
                return "activa (TTL de \(ttl), última actividad hace \(idle))"
            }
            if let found = groups(#"^cold — idle ([^,]+), next turn re-caches (.+) tokens$"#, in: part), let idle = found[0], let size = found[1] {
                return "fría: inactiva \(idle), el próximo turno vuelve a cachear \(size) tokens"
            }
            return part
        }.joined(separator: " · ")
    }

    /// A plugin's line or the total: "10 skills · ~301 tok/turn" → "10 skills · ~301 tok/turno".
    static func footprint(_ detail: String) -> String {
        var words = detail.replacingOccurrences(of: "tok/turn", with: "tok/turno")
        if let found = groups(#"^(\d+) skills?( · .*)?$"#, in: words), let count = found[0] {
            words = "\(count) \(count == "1" ? "skill" : "skills")" + (found[1] ?? "")
        }
        return words
    }

    /// The footprint's and the insights' own sentences (notes, the window, headlines, advice, single lines, table headers).
    static func insight(_ text: String) -> String {
        let line = text.trimmingCharacters(in: .whitespaces)
        if let known = Self.sentences[line.replacingOccurrences(of: "’", with: "'")] { return known }
        if let found = groups(#"^(Last|Past) (\d+)\s*(h|d) · these are independent characteristics of your usage, not a breakdown$"#, in: line),
           let count = found[1], let unit = found[2] {
            return "\(unit == "h" ? "Últimas \(count) h" : "Últimos \(count) días") · son rasgos independientes de tu uso, no un desglose"
        }
        if let found = groups(#"^(Last|Past) (\d+)\s*(h|d)( · .*)?$"#, in: line), let count = found[1], let unit = found[2] {
            return (unit == "h" ? "Últimas \(count) h" : "Últimos \(count) días") + (found[3] ?? "")
        }
        if let found = groups(#"^(\d{1,3})% of your usage (.+)$"#, in: line), let share = found[0], let rest = found[1] {
            let quoted = { (name: String) in "«\(name)»" }
            if rest == "hit a >100k-token cache miss" { return "El \(share) % de tu uso tuvo un fallo de caché de más de 100k tokens" }
            if rest == "was at >150k context" { return "El \(share) % de tu uso fue con más de 150k de contexto" }
            if rest == "came from subagent-heavy sessions" { return "El \(share) % de tu uso vino de sesiones con muchos subagentes" }
            if rest == "was while 4+ sessions ran in parallel" { return "El \(share) % de tu uso fue con 4 o más sesiones en paralelo" }
            if rest == "came from sessions active for 8+ hours" { return "El \(share) % de tu uso vino de sesiones activas durante 8 horas o más" }
            if let name = groups(#"^came from subagents under "(.+)"$"#, in: rest)?[0] { return "El \(share) % de tu uso vino de subagentes de \(quoted(name))" }
            if let name = groups(#"^came from the plugin "(.+)"$"#, in: rest)?[0] { return "El \(share) % de tu uso vino del plugin \(quoted(name))" }
            if let name = groups(#"^came from the MCP server "(.+)"$"#, in: rest)?[0] { return "El \(share) % de tu uso vino del servidor MCP \(quoted(name))" }
            if let name = groups(#"^came from (/\S+)$"#, in: rest)?[0] { return "El \(share) % de tu uso vino de \(name)" }
        }
        if let found = groups(#"^… (\d+) more$"#, in: line), let count = found[0] { return "… \(count) más" }
        if let known = credits(line) { return known }
        // A line that says how full a limit is, as the panel prints it while it loads: "Current session · 3% used".
        if let found = groups(#"^(.+?) · (\d+(?:[.,]\d+)?)\s*%\s*used$"#, in: line), let name = found[0], let value = found[1] {
            return "\(title(name)) · \(value) % usado"
        }
        return line
    }

    /// What the panel says of the usage credits at its end: "Usage credits are off · /usage-credits to turn them on" is "Los créditos de uso están desactivados ·
    /// /usage-credits los activa", and "Unlimited" is "Sin límite". Each part Claude adds after a dot that this does not know is kept as it is.
    private static func credits(_ line: String) -> String? {
        if line == "Unlimited" { return "Sin límite" }
        guard let found = groups(#"^Usage credits are (on|off)(?: · (.+))?$"#, in: line), let state = found[0] else { return nil }
        var words = "Los créditos de uso están " + (state == "on" ? "activados" : "desactivados")
        if let rest = found[1] {
            let parts = rest.components(separatedBy: " · ").map { part -> String in
                switch part.trimmingCharacters(in: .whitespaces) {
                case "/usage-credits to turn them on": return "/usage-credits los activa"
                case "/usage-credits to turn them off": return "/usage-credits los desactiva"
                case "/usage-credits to manage them": return "/usage-credits los gestiona"
                default: return part
                }
            }
            words += " · " + parts.joined(separator: " · ")
        }
        return words
    }

    private static let sentences: [String: String] = [
        "Approximate, based on local sessions on this machine — does not include other devices or claude.ai":
            "Aproximado, según las sesiones locales de este equipo; no incluye otros dispositivos ni claude.ai",
        "What each plugin's skill descriptions add to the system prompt (cached input after the first turn). Agents and MCP tools not yet counted.":
            "Lo que las descripciones de las skills de cada plugin suman al prompt del sistema (entrada en caché después del primer turno). Aún no cuenta agentes ni herramientas MCP.",
        "capped at the listing budget; per-plugin figures above are pre-truncation":
            "limitado por el presupuesto del listado; las cifras por plugin son previas al recorte",
        "Uncached input is expensive, and often happens when sending a message to a session that has gone idle. /compact before stepping away keeps the cold-start small.":
            "La entrada sin caché es cara, y suele pasar al escribirle a una sesión que quedó inactiva. Un /compact antes de alejarte mantiene pequeño el arranque en frío.",
        "Longer sessions are more expensive even when cached. /compact mid-task, /clear when switching to new tasks.":
            "Las sesiones largas cuestan más aunque estén en caché. Usa /compact a mitad de una tarea y /clear al pasar a otra.",
        "Each subagent runs its own requests. Be deliberate about spawning them — and consider configuring a cheaper model for simpler subagents.":
            "Cada subagente hace sus propias solicitudes. Lánzalos con intención, y considera un modelo más barato para los subagentes sencillos.",
        "All sessions share one limit. If you don't need them all at once, queueing uses it more evenly.":
            "Todas las sesiones comparten un mismo límite. Si no las necesitas a la vez, ponerlas en cola lo reparte mejor.",
        "These are often background/loop sessions. Continuous usage can add up quickly so make sure it is intentional.":
            "Suelen ser sesiones en segundo plano o en bucle. El uso continuo se acumula rápido; asegúrate de que sea intencional.",
        "If this runs frequently, consider configuring its subagents with a cheaper model or tightening their prompts.":
            "Si esto se ejecuta a menudo, considera un modelo más barato para sus subagentes o prompts más ajustados.",
        "Heavy skills can be scoped down or run with a cheaper model via skill frontmatter.":
            "Las skills pesadas se pueden acotar o ejecutar con un modelo más barato desde su frontmatter.",
        "Review what this plugin contributes — its agents, skills, and MCP tools all count toward your limit.":
            "Revisa lo que aporta este plugin: sus agentes, skills y herramientas MCP cuentan para tu límite.",
        "MCP tool results stay in context for the rest of the session. /compact to flush them, or disable servers you don't need.":
            "Los resultados de las herramientas MCP se quedan en el contexto el resto de la sesión. Usa /compact para vaciarlos, o desactiva los servidores que no necesites.",
        "Scanning local sessions…": "Revisando las sesiones locales…",
        "Nothing over 10% in this period — try the other window.": "Nada supera el 10 % en este periodo; prueba la otra ventana.",
        "Skills, subagents, plugins, and MCP servers": "Skills, subagentes, plugins y servidores MCP",
        "No attribution data yet · accumulates as you use Claude": "Aún no hay datos de atribución · se acumulan a medida que usas Claude",
        "Loading usage data…": "Cargando los datos de uso…",
        // What the panel adds under a limit that is nearly full.
        "You are close to this limit": "Estás cerca de este límite",
        "You've used most of your session limit": "Has usado casi todo el límite de tu sesión",
        "Subagents": "Subagentes", "MCP servers": "Servidores MCP", "Loops": "Bucles",
        "% of usage": "% del uso", "every": "cada", "runs": "ejecuciones", "per run": "por ejecución", "last run": "última",
    ]
}
