import Foundation

// What each request to Nook Remote does (docs/REMOTE_API.md): the checks every request passes, pairing, reading, and the actions,
// each one the island's own function on the main thread. An action that fails answers the phone with a sentence in Spanish (the
// model's notice when it said why); nothing a phone asks for ever opens a dialog on the Mac.

extension RemoteAccess {
    /// How long a call may wait for the model before the phone hears it did not answer (a delivery waits for Claude's screen, an
    /// image for Claude to read it: seconds, never this long).
    static let replyTimeout: TimeInterval = 45

    // MARK: Every request

    /// One request, from the server's queue. `reply` is called once, from any thread.
    func handle(_ request: RemoteRequest, from peer: RemotePeer, reply: @escaping (RemoteReply) -> Void) {
        let once = OnceFlag()
        let answer: (RemoteReply) -> Void = { result in if once.claim() { reply(result) } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.replyTimeout) {
            answer(.response(.error(504, "Nook no respondió a tiempo. Revisa la pestaña en el Mac.")))
        }
        // The page is for the phone: on the Mac itself it says so, and nothing else is served there.
        if peer.verdict == .thisMac {
            var page = RemoteResponse.page(403, title: "Nook Remoto es para tu teléfono", message: "Abre la dirección de Nook Remoto en tu iPhone, conectado a la misma Wi-Fi que este Mac. En el propio Mac, usa la isla.")
            page.closes = true
            return answer(.response(page))
        }
        // Only this Mac by its own address on the home network: a name that leads here (DNS rebinding) is refused.
        guard policy.acceptsHost(request.header("host"), port: peer.port) else {
            var refused = request.path.hasPrefix("/api/") ? RemoteResponse.error(403, "Dirección no válida para Nook Remoto.")
                : RemoteResponse.page(403, title: "Dirección no válida", message: "Abre Nook Remoto con la dirección que muestra Nook en Ajustes → Remoto.")
            refused.closes = true
            return answer(.response(refused))
        }
        if request.path.hasPrefix("/api/") { return api(request, from: peer, answer: answer) }
        guard request.method == "GET" else { return answer(.response(.error(405, "Método no permitido."))) }
        if request.path == "/pair" { return answer(.response(pair(request))) }
        answer(.response(pageFile(request.path == "/" ? "index.html" : String(request.path.dropFirst()))))
    }

    /// A file of the page. It holds no data, so it needs no cookie.
    private func pageFile(_ name: String) -> RemoteResponse {
        guard let type = RemotePageSource.contentType(name), let data = page.file(name) else {
            if name == "index.html" {
                return .page(503, title: "Nook Remoto no está instalado", message: "Falta la página de Nook Remoto en esta copia de Nook. Vuelve a instalar Nook.")
            }
            return .page(404, title: "No encontrado", message: "Esta dirección no existe en Nook Remoto.")
        }
        var headers = [("Content-Type", type), ("Cache-Control", "no-cache")]
        if name.hasSuffix(".html") { headers.append(("Content-Security-Policy", Self.contentSecurityPolicy(scripts: RemotePageSource.scriptHashes(in: data)))) }
        return RemoteResponse(status: 200, headers: headers, body: data)
    }

    /// The page reaches nothing but this server. Its scripts are its own files or the inline blocks it shipped with, each allowed by
    /// its hash (`scripts`, "sha256-…"): a script anything managed to slip into the page, an event-handler attribute or a
    /// `javascript:` link never runs. Its styles are its own (inline allowed), its images its own or made in place, and no other
    /// site can frame it.
    static func contentSecurityPolicy(scripts: [String]) -> String {
        let script = (["'self'"] + scripts.map { "'\($0)'" }).joined(separator: " ")
        return "default-src 'self'; script-src \(script); style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; "
            + "font-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
    }

    // MARK: Pairing

    /// `GET /pair?k=<key>`: the right key gives this device a cookie of its own, and the page.
    /// The key pairs one device: a second scan of the same QR (or one opened again from the history) finds it used up.
    private func pair(_ request: RemoteRequest) -> RemoteResponse {
        switch registry.pair(key: request.query["k"], userAgent: request.header("user-agent")) {
        case .paired(let token):
            return RemoteResponse(status: 303, headers: [("Location", "/"), ("Cache-Control", "no-store"),
                                                         ("Set-Cookie", "\(Self.cookieName)=\(token); HttpOnly; SameSite=Strict; Path=/")])
        case .wrongKey:
            return .page(403, title: "No se pudo emparejar", message: "Escanea el código QR en Nook → Ajustes → Remoto.")
        case .full:
            return .page(403, title: "No se pudo emparejar",
                         message: "Ya hay \(RemoteRegistry.maxDevices) dispositivos emparejados. Quita uno en Nook → Ajustes → Remoto.")
        }
    }

    // MARK: The API

    /// The checks every API request passes, from its head alone: its origin, a paired device's cookie, and for a POST the page's own
    /// header and the body's type (JSON; raw image bytes for `/api/upload`). The device, or the answer that refuses it.
    private func gate(_ request: RemoteRequest) -> RemoteGate {
        let host = request.header("host") ?? ""
        // A page of another origin may not call it, even with the cookie (which SameSite=Strict keeps from it anyway).
        if let origin = request.header("origin"), origin.lowercased() != "http://" + host.lowercased() { return .refused(.error(403, "Origen no permitido.")) }
        if request.header("sec-fetch-site")?.lowercased() == "cross-site" { return .refused(.error(403, "Origen no permitido.")) }
        guard let device = registry.device(cookie: request.header("cookie")) else {
            return .refused(.error(401, "Empareja este dispositivo escaneando el QR en Nook."))
        }
        guard request.method == "POST" else { return .passed(device) }
        // Only the page's own script sends this header, and a form or a simple request from elsewhere cannot.
        guard request.header("x-nook-remote") == "1" else { return .refused(.error(403, "Falta la cabecera de Nook Remoto.")) }
        if request.path == "/api/upload" {
            guard RemoteImageKind(contentType: request.header("content-type")) != nil else {
                return .refused(.error(415, "Ese archivo no es una imagen JPEG, PNG, GIF o WebP."))
            }
        } else if request.header("content-type")?.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces) != "application/json" {
            return .refused(.error(415, "La petición debe ser JSON."))
        }
        return .passed(device)
    }

    private func api(_ request: RemoteRequest, from peer: RemotePeer, answer: @escaping (RemoteReply) -> Void) {
        let device: RemoteDevice
        switch gate(request) {
        case .refused(let refusal): return answer(.response(refusal))
        case .passed(let found): device = found
        }
        note(device, connection: peer.connection, address: peer.address)
        switch request.method {
        case "GET": read(request, from: device, answer: answer)
        case "POST":
            if request.path == "/api/upload" { return upload(request, from: device, answer: answer) }
            if request.path == "/api/log", request.body.count > RemoteLog.maxBody { return answer(.response(.error(413, "El registro es demasiado largo."))) }
            guard let body = (request.body.isEmpty ? [:] : try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] else {
                return answer(.response(.error(400, "La petición no es válida.")))
            }
            if request.path == "/api/log" { return answer(.response(log(RemoteBody(body), from: device))) }
            act(request.path, RemoteBody(body), from: device, answer: answer)
        default:
            answer(.response(.error(405, "Método no permitido.")))
        }
    }

    // MARK: Large bodies

    /// A request whose body is longer than 64 KB, from its head alone, before a byte of the body is read (server's queue). Only an
    /// image for `/api/upload` from a paired device, passing every check an API request passes, is read: up to
    /// `RemoteImages.maxBytes`, within `RemoteImages.uploadTimeout`, two at a time server-wide. Anything else is answered at once.
    func bodyDecision(for head: RemoteRequest, from peer: RemotePeer) -> RemoteBodyDecision {
        guard head.method == "POST", head.path == "/api/upload" else { return .refuse(.error(413, "La petición es demasiado grande.")) }
        guard peer.verdict == .allowed, policy.acceptsHost(head.header("host"), port: peer.port) else {
            return .refuse(.error(403, "Dirección no válida para Nook Remoto."))
        }
        let device: RemoteDevice
        switch gate(head) {
        case .refused(let refusal): return .refuse(refusal)
        case .passed(let found): device = found
        }
        let declared = Int(head.header("content-length") ?? "") ?? 0
        guard declared <= RemoteImages.maxBytes else { return .refuse(Self.tooBig) }
        if let refusal = uploadRefusal(for: device) { return .refuse(refusal) }
        guard uploadGauge.acquire() else { return .refuse(.error(503, "Ya se están subiendo otras imágenes; espera un momento y vuelve a intentarlo.")) }
        let gauge = uploadGauge, once = OnceFlag()
        return .large(limit: RemoteImages.maxBytes, timeout: RemoteImages.uploadTimeout, release: { if once.claim() { gauge.release() } })
    }

    static var tooBig: RemoteResponse { .error(413, "La imagen pesa demasiado (más de \(RemoteImages.maxBytes / 1024 / 1024) MB).") }

    /// Why `device` may not upload one more image now, if it may not: too many lately, or too many waiting to be sent.
    private func uploadRefusal(for device: RemoteDevice) -> RemoteResponse? {
        guard uploadGauge.allows(device.id, count: false) else { return .error(429, "Has subido muchas imágenes seguidas; espera unos minutos.") }
        guard uploads.count(for: device.id) < RemoteUploads.maxPending else {
            return .error(409, "Tienes \(RemoteUploads.maxPending) imágenes sin enviar; envía o quita alguna antes de adjuntar otra.")
        }
        return nil
    }

    // MARK: Images from the phone

    /// `POST /api/upload`: an image for the next message. Checked to be what it says it is and to decode, written under a name Nook
    /// chooses, and kept for this device until a message carries it.
    private func upload(_ request: RemoteRequest, from device: RemoteDevice, answer: @escaping (RemoteReply) -> Void) {
        guard let kind = RemoteImageKind(contentType: request.header("content-type")) else {
            return answer(.response(.error(415, "Ese archivo no es una imagen JPEG, PNG, GIF o WebP.")))
        }
        guard !request.body.isEmpty else { return answer(.response(.error(400, "La imagen está vacía."))) }
        guard request.body.count <= RemoteImages.maxBytes else { return answer(.response(Self.tooBig)) }
        if let refusal = uploadRefusal(for: device) { return answer(.response(refusal)) }
        guard kind.matches(request.body) else { return answer(.response(.error(415, "Ese archivo no es la imagen que dice ser."))) }
        _ = uploadGauge.allows(device.id, count: true)
        let folder = imagesFolder, body = request.body, uploads = uploads
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let size = RemoteImages.inspect(body) else { return answer(.response(.error(415, "No pude abrir esa imagen; prueba con otra."))) }
            let url: URL
            do { url = try RemoteImages.save(body, kind: kind, in: folder) } catch {
                return answer(.response(.error(500, "No pude guardar la imagen en el Mac: \(error.localizedDescription)")))
            }
            let upload = RemoteUpload(name: url.lastPathComponent, path: url.path, device: device.id, issued: Date(), width: size.width, height: size.height)
            guard uploads.issue(upload) else {
                try? FileManager.default.removeItem(at: url)
                return answer(.response(.error(409, "Tienes \(RemoteUploads.maxPending) imágenes sin enviar; envía o quita alguna antes de adjuntar otra.")))
            }
            answer(.response(.ok([("id", .string(upload.name)), ("url", .string("/api/shot/" + upload.name)), ("width", .int(upload.width)), ("height", .int(upload.height))])))
            // Images older than a day go, as the island's pasted ones do; the ones still attached somewhere, or waiting here, stay.
            DispatchQueue.main.async {
                let kept = MainActor.assumeIsolated { MessageAttachments.shared.attachedPaths }.union(self?.uploads.paths ?? [])
                MessageAttachments.prune(folder, now: Date(), keeping: kept)
            }
        }
    }

    // MARK: The page's log

    /// `POST /api/log`: one entry of the page's own (an exception, a call that failed) into the log on the Mac, while this device has
    /// entries left this minute; the rest are dropped, and the page hears so only as `dropped`.
    private func log(_ body: RemoteBody, from device: RemoteDevice) -> RemoteResponse {
        guard let level = body.string("level"), RemoteLog.levels.contains(level), let message = body.string("message") else {
            return .error(400, "La petición no es válida.")
        }
        guard logLimiter.allows(device.id) else { return .ok([("dropped", .bool(true))]) }
        let entry = RemoteLog.Entry(level: level, message: message, detail: body.string("detail"), url: body.string("url"), line: body.int("line"),
                                    userAgent: body.string("ua"))
        RemoteLog.append(RemoteLog.line(entry, device: device.label), to: logURL)
        return .ok()
    }

    // MARK: Reading

    private func read(_ request: RemoteRequest, from device: RemoteDevice, answer: @escaping (RemoteReply) -> Void) {
        switch request.path {
        case "/api/state":
            onMain(answer) { access, _ in
                guard let frame = access.frame() else { return answer(.response(.error(503, "Nook se está cerrando."))) }
                access.broadcaster.publish(frame) { state in answer(.response(.json(200, .raw(state)))) }
            }
        case "/api/events":
            answer(.stream { [weak self] sink in self?.broadcaster.add(sink) })
        case "/api/conversation":
            guard let tab = request.query["tab"], let before = request.query["before"].flatMap(Int.init) else {
                return answer(.response(.error(400, "Faltan la pestaña o la línea.")))
            }
            let limit = min(1000, max(1, request.query["limit"].flatMap(Int.init) ?? 400))
            let epoch = request.query["epoch"].flatMap(Int.init)
            onMain(answer) { access, _ in
                guard let frame = access.frame() else { return answer(.response(.error(503, "Nook se está cerrando."))) }
                access.broadcaster.page(frame, tab: tab, before: before, limit: limit, epoch: epoch) { page in
                    switch page {
                    case .lines(let json): answer(.response(.json(200, json)))
                    case .moved(let epoch):
                        answer(.response(.error(409, "La conversación cambió; vuelve a cargarla.", [("epoch", .int(epoch))])))
                    }
                }
            }
        default:
            guard request.path.hasPrefix("/api/shot/") else { return answer(.response(.error(404, "No existe esa llamada."))) }
            shot(String(request.path.dropFirst("/api/shot/".count)), for: device, answer: answer)
        }
    }

    /// The picture of an image that went with a message (a screenshot, or one the phone sent: `AppModel.sentShots`), or one this
    /// device sent that waits to be attached (`RemoteUploads`), by its exact name. The phone names a file, never a path; the path is
    /// Nook's own record of where it wrote it, and it is never followed through a link.
    private func shot(_ name: String, for device: RemoteDevice, answer: @escaping (RemoteReply) -> Void) {
        guard SentShot.isShotName(name), let kind = RemoteImageKind(fileName: name) else { return answer(.response(.error(404, "Esa imagen no existe."))) }
        let waiting = uploads.waiting(name, for: device.id)
        onMain(answer) { _, model in
            guard let path = model.sentShot(named: name)?.path ?? waiting?.path, (path as NSString).lastPathComponent == name else {
                return answer(.response(.error(404, "Esa imagen no existe.")))
            }
            DispatchQueue.global(qos: .userInitiated).async {
                guard let data = RemotePageSource.read(URL(fileURLWithPath: path), limit: 30 * 1024 * 1024) else {
                    return answer(.response(.error(404, "Esa imagen ya no está en el Mac.")))
                }
                answer(.response(RemoteResponse(status: 200, headers: [("Content-Type", kind.contentType), ("Cache-Control", "private, max-age=86400")], body: data)))
            }
        }
    }

    // MARK: Acting

    /// Runs `work` on the main thread with the model, or answers that Nook is closing.
    private func onMain(_ answer: @escaping (RemoteReply) -> Void, _ work: @escaping (RemoteAccess, AppModel) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let model = self.model, self.server != nil else { return answer(.response(.error(503, "Nook Remoto está apagado."))) }
            work(self, model)
        }
    }

    private func act(_ path: String, _ body: RemoteBody, from device: RemoteDevice, answer: @escaping (RemoteReply) -> Void) {
        let respond: (RemoteResponse) -> Void = { answer(.response($0)) }
        onMain(answer) { access, model in
            // Calls without a tab.
            switch path {
            case "/api/screen":
                guard let attach = body.bool("attach") else { return respond(.error(400, "La petición no es válida.")) }
                // On only when the screen can really go (`screen.available`): the phone never turns on an eye that would end in
                // macOS asking for the permission on the Mac.
                if attach, !model.screenVision.enabled {
                    return respond(.error(409, "Activa la visión de pantalla en Nook (Ajustes → Pantalla) para adjuntar tu pantalla."))
                }
                if attach, !access.screenAvailable(model, fresh: true) { return respond(.error(409, Self.noRecording)) }
                model.screenVision.attachToMessages = attach
                return respond(.ok())
            case "/api/tabs/new":
                guard let kind = body.string("kind").flatMap(SessionKind.init(rawValue:)) else { return respond(.error(400, "La petición no es válida.")) }
                // A new tab of Terminal on the Mac; the island stays as it is (the phone is where the user is).
                model.create(kind, expandIsland: false)
                return respond(.ok())
            default: break
            }
            guard let id = body.string("tab") else { return respond(.error(400, "Falta la pestaña.")) }
            guard let session = model.sessions.first(where: { $0.id == id }) else { return respond(.error(404, "Esa pestaña ya no está abierta en Nook.")) }
            switch path {
            case "/api/select": access.select(session, in: model, respond: respond)
            case "/api/send": access.send(body, to: session, from: device, in: model, respond: respond)
            case "/api/prompt/choose": access.choose(body, on: session, in: model, respond: respond)
            case "/api/prompt/field": access.answerField(body, on: session, in: model, respond: respond)
            case "/api/prompt/cancel":
                guard session.mirrorsAgent, session.prompt != nil else { return respond(.error(409, "Ya no hay ninguna pregunta abierta en esa pestaña.")) }
                let serial = model.noticeSerial
                model.cancelPrompt(on: session, from: .remote) { result in
                    respond(Self.keys(result, model: model, since: serial, failed: "No pude cancelar la pregunta. Si ya se estaba enviando una respuesta, espera un momento."))
                }
            case "/api/key":
                guard let key = body.string("key").flatMap(Self.key) else { return respond(.error(400, "Esa tecla no se puede pulsar desde Nook Remoto.")) }
                let serial = model.noticeSerial
                model.press(key, on: session, from: .remote) { result in
                    respond(Self.keys(result, model: model, since: serial, failed: "No pude pulsar la tecla en la terminal."))
                }
            case "/api/interrupt":
                let serial = model.noticeSerial
                model.interrupt(session, from: .remote) { result in
                    respond(Self.keys(result, model: model, since: serial, failed: "No pude interrumpir a la IA en la terminal."))
                }
            case "/api/model": access.setModel(body, on: session, in: model, respond: respond)
            case "/api/mode/cycle":
                guard session.agent == .claude else { return respond(.error(409, "Claude no está abierto en esta pestaña.")) }
                let question = session.mirrorsAgent && session.prompt != nil
                let panel = session.mirrorsAgent && session.prompt == nil && session.panel != nil
                if let blocked = ClaudeModeStyle.block(running: session.isRunning, questionOpen: question, panelOpen: panel) { return respond(.error(409, blocked)) }
                let serial = model.noticeSerial
                model.cycleMode(on: session, from: .remote) { result in
                    respond(Self.keys(result, model: model, since: serial, failed: "No pude cambiar el modo de Claude."))
                }
            case "/api/agent/open":
                guard let agentID = body.string("id") else {
                    model.view(agent: nil, in: session)
                    return respond(.ok())
                }
                guard let agent = session.subagents.first(where: { $0.id == agentID && $0.role == .agent }) else {
                    return respond(.error(404, "Ese agente ya no está en la lista."))
                }
                model.openAgent(agent, in: session)
                respond(.ok())
            default:
                respond(.error(404, "No existe esa llamada."))
            }
        }
    }

    private func select(_ session: TerminalSession, in model: AppModel, respond: (RemoteResponse) -> Void) {
        model.select(session)
        // A Nook session's conversation, held back while nobody looked, comes now.
        if !session.isExternal { model.followTranscript(session) }
        respond(.ok())
    }

    /// `/api/send`: the island's own send (`AppModel.sendMessage`), with the images this device sent for it (`files`) as its attached
    /// files. A dialog's text field that would take whatever is written gets it as its answer instead, as the island's composer
    /// does. The phone keeps its text, and its images wait for another try, until the answer says it went.
    private func send(_ body: RemoteBody, to session: TerminalSession, from device: RemoteDevice, in model: AppModel, respond: @escaping (RemoteResponse) -> Void) {
        guard let raw = body.string("text") ?? (body.has("text") ? nil : "") else { return respond(.error(400, "La petición no es válida.")) }
        guard let names = body.strings("files") ?? (body.has("files") ? nil : []) else { return respond(.error(400, "La petición no es válida.")) }
        guard names.count <= RemoteUploads.maxPerMessage else { return respond(.error(400, "Puedes adjuntar hasta \(RemoteUploads.maxPerMessage) imágenes por mensaje.")) }
        let blank = raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let text = blank ? "" : raw.trimmingCharacters(in: .newlines)
        if blank, names.isEmpty {
            // An open dialog's text field never gets nothing (Enter on an empty field cancels Claude's question), and an empty send
            // never slips past it into the agent's box.
            if model.fieldAnswer(for: session) != nil { return respond(.error(400, "Escribe tu respuesta antes de enviarla.")) }
            // Nothing written and nothing attached is a message only when the screen goes with it (the eye on, an agent's tab): the
            // screenshot alone.
            guard model.screenVision.attaches(text: text, agent: session.agent) else {
                return respond(.error(400, "Escribe un mensaje o activa la captura de pantalla para enviar solo la captura."))
            }
        }
        let unavailable = RemoteResponse.error(400, "La imagen ya no está disponible; adjúntala otra vez.")
        guard names.allSatisfy({ uploads.waiting($0, for: device.id) != nil }) else { return respond(unavailable) }
        guard session.isRunning else { return respond(.error(409, "La terminal de esta pestaña está cerrada.")) }
        guard !session.sending else { return respond(.error(409, "Todavía se está enviando el mensaje anterior; espera un momento.")) }
        guard !model.screenVision.capturing else { return respond(.error(409, "Nook está capturando la pantalla para el mensaje anterior; espera un momento.")) }
        guard session.joinedBox == nil else {
            return respond(.error(409, "Tu mensaje anterior quedó en la caja de \(session.agent?.title ?? "la IA") detrás de otro texto. Revísalo en la terminal antes de enviar otro."))
        }
        let serial = model.noticeSerial
        if model.fieldAnswer(for: session) != nil {
            // A dialog's text field takes a line of text, as on the island: the images would be left behind.
            guard names.isEmpty else { return respond(.error(409, "La pregunta abierta espera una respuesta de texto; las imágenes no van en ella. Quítalas o responde primero.")) }
            model.remember(text, for: session)
            model.sendToField(text, on: session) { delivered in
                respond(delivered ? .ok([("field", .bool(true))]) : .error(409, Self.said(model, since: serial) ?? "No pude escribir tu respuesta en la pregunta. Revisa la terminal."))
            }
            return
        }
        // A message that would carry the screen goes only when macOS lets Nook record it: the phone never sets off a capture that
        // brings up the system's permission dialog on the Mac. Nothing is sent, and the phone keeps the text.
        if model.screenVision.attaches(text: text, agent: session.agent), !screenAvailable(model, fresh: true) {
            return respond(.error(409, Self.noRecording + " No envié el mensaje: apaga el ojo de la pantalla para enviarlo sin captura."))
        }
        // On their way: another message can't take the same images meanwhile.
        guard let attached = uploads.reserve(names, for: device.id) else { return respond(unavailable) }
        let uploads = uploads
        model.sendMessage(text, files: attached.map(\.path), to: session, rememberingFiles: true) { outcome in
            uploads.finish(names, sent: outcome == .delivered)
            switch outcome {
            case .delivered: respond(.ok())
            case .notDelivered:
                if session.joinedBox != nil {
                    return respond(.error(409, "Tu mensaje quedó en la caja de \(session.agent?.title ?? "la IA") detrás de texto que ya había, sin enviarse. Revísalo en la terminal."))
                }
                respond(.error(502, Self.said(model, since: serial) ?? "No pude entregar el mensaje a la terminal. Revisa la pestaña en el Mac."))
            case .screenFailed(let notice):
                respond(.error(500, notice))
            }
        }
    }

    /// `/api/prompt/choose`: an option of the question on screen, with notes for Claude when given. A text field takes no key: it
    /// becomes what the composer answers (`field: true`).
    private func choose(_ body: RemoteBody, on session: TerminalSession, in model: AppModel, respond: @escaping (RemoteResponse) -> Void) {
        guard let signature = body.string("signature"), let index = body.int("option") else { return respond(.error(400, "La petición no es válida.")) }
        guard let live = Self.livePrompt(session, signature: signature, respond: respond) else { return }
        guard live.options.indices.contains(index) else { return respond(.error(400, "Esa opción no existe.")) }
        let serial = model.noticeSerial
        let notes = body.string("notes")?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let notes, !notes.isEmpty {
            model.answer(live, option: index, notes: notes, on: session) { result in
                respond(Self.keys(result, model: model, since: serial, failed: "No pude enviar tu respuesta a la terminal."))
            }
            return
        }
        let field = live.options[index].input == .inline && !session.isFilledField(index, of: live)
        model.answer(live, option: index, on: session, from: .remote) { result in
            let response = Self.keys(result, model: model, since: serial, failed: "No pude enviar tu respuesta a la terminal.")
            respond(result == .sent && field ? .ok([("field", .bool(true))]) : response)
        }
    }

    /// `/api/prompt/field`: the text into a text field of the question on screen, and sent (`AppModel.answer(_:option:text:on:)`).
    private func answerField(_ body: RemoteBody, on session: TerminalSession, in model: AppModel, respond: @escaping (RemoteResponse) -> Void) {
        guard let signature = body.string("signature"), let index = body.int("option"), let text = body.string("text") else {
            return respond(.error(400, "La petición no es válida."))
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return respond(.error(400, "Escribe tu respuesta antes de enviarla.")) }
        guard let live = Self.livePrompt(session, signature: signature, respond: respond) else { return }
        guard live.options.indices.contains(index), live.options[index].input == .inline else { return respond(.error(400, "Esa opción no admite texto.")) }
        let serial = model.noticeSerial
        model.remember(text, for: session)
        model.answer(live, option: index, text: text, on: session) { result in
            respond(Self.keys(result, model: model, since: serial, failed: "No pude escribir tu respuesta en la pregunta. Revisa la terminal."))
        }
    }

    /// `/api/model`: the model of that id from the tab's list, as the model button switches it.
    private func setModel(_ body: RemoteBody, on session: TerminalSession, in model: AppModel, respond: (RemoteResponse) -> Void) {
        guard let id = body.string("id") else { return respond(.error(400, "La petición no es válida.")) }
        if let blocked = model.modelSwitchBlocked(on: session) { return respond(.error(409, blocked)) }
        guard !session.answering else { return respond(.error(409, "Se está enviando una respuesta; espera un momento.")) }
        guard let choice = model.availableModels(for: session).first(where: { $0.id == id }) else { return respond(.error(404, "Ese modelo ya no está en la lista.")) }
        model.setModel(choice, on: session, from: .remote)
        respond(.ok())
    }

    /// The question on screen, when it is still the one the phone answers; otherwise the phone is told, and nil.
    private static func livePrompt(_ session: TerminalSession, signature: String, respond: (RemoteResponse) -> Void) -> AgentPrompt? {
        guard session.mirrorsAgent, let live = session.prompt else {
            respond(.error(409, "Ya no hay ninguna pregunta abierta en esa pestaña."))
            return nil
        }
        guard live.signature == signature else {
            respond(.error(409, "La pregunta cambió en la terminal; revisa la tarjeta otra vez."))
            return nil
        }
        return live
    }

    /// Why the screen can't go with the phone's messages although screen vision is on: macOS doesn't let Nook record it.
    static let noRecording = "Nook no tiene permiso para grabar la pantalla de este Mac. Actívalo en el Mac: Ajustes del Sistema → Privacidad y seguridad → \(NookPermission.screenRecordingPane)."

    /// The answer to a call that pressed keys: done, Accessibility missing (403, nothing asked on the Mac), or what went wrong.
    static func keys(_ result: KeyDelivery, model: AppModel, since serial: Int, failed: String) -> RemoteResponse {
        switch result {
        case .sent: return .ok()
        case .needsPermission: return .error(403, AppModel.remoteKeysNotice)
        case .failed: return .error(409, said(model, since: serial) ?? failed)
        }
    }

    /// What the model's notice said since `serial`, when it said something.
    static func said(_ model: AppModel, since serial: Int) -> String? {
        model.noticeSerial != serial ? model.notice : nil
    }

    /// The keys the phone may press, by the contract's names.
    static func key(_ name: String) -> TerminalKey? {
        switch name {
        case "up": .up
        case "down": .down
        case "left": .left
        case "right": .right
        case "tab": .tab
        case "backtab": .backtab
        case "escape": .escape
        case "enter": .enter
        default: nil
        }
    }
}

/// How an API request fared at the gate (`RemoteAccess.gate`).
enum RemoteGate {
    case passed(RemoteDevice)
    case refused(RemoteResponse)
}

/// A request's JSON body, read by type: a number is never a bool, nor a bool a number.
struct RemoteBody {
    let fields: [String: Any]
    init(_ fields: [String: Any]) { self.fields = fields }

    func string(_ name: String) -> String? { fields[name] as? String }

    /// The field is there, null or not.
    func has(_ name: String) -> Bool { fields[name] != nil && !(fields[name] is NSNull) }

    /// An array of strings, and nothing else.
    func strings(_ name: String) -> [String]? {
        guard let items = fields[name] as? [Any] else { return nil }
        let strings = items.compactMap { $0 as? String }
        return strings.count == items.count ? strings : nil
    }

    func bool(_ name: String) -> Bool? {
        guard let number = fields[name] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    func int(_ name: String) -> Int? {
        guard let number = fields[name] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.rounded() == value, abs(value) < 1_000_000 else { return nil }
        return Int(value)
    }
}
