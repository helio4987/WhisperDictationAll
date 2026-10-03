import Foundation

final class AppSettings: ObservableObject, @unchecked Sendable {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    // MARK: - Hotkey Mode

    enum HotkeyMode: String { case pushToTalk, toggle }

    // MARK: - Keys

    private enum Key: String {
        case hotkeyKeyCode
        case hotkeyMode
        case toggleHoldDuration
        case selectedModel
        case soundFeedbackEnabled
        case vocabularyPrompt
        case launchAtLogin
        case minimumRecordingDuration
        case grammarCorrectionEnabled
        case selectedAudioDeviceUID
        case numberConversionEnabled
        case customTerms
        case hasCompletedOnboarding
        case liveDictationEnabled
        // Secondary language (see LanguageModelSlot, DictationEngine)
        case secondaryLanguageCode
        case secondaryModelSelection
        case secondaryHotkeyKeyCode
        case primaryIdleTimeoutMinutes
        case secondaryIdleTimeoutMinutes
        case secondaryVocabularyPrompt
        case includeEnglishTermsInSecondary
    }

    // MARK: - Properties

    var hotkeyKeyCode: Int {
        get { defaults.object(forKey: Key.hotkeyKeyCode.rawValue) as? Int ?? 61 } // 61 = right Option
        set { defaults.set(newValue, forKey: Key.hotkeyKeyCode.rawValue); objectWillChange.send() }
    }

    var hotkeyMode: HotkeyMode {
        get {
            let raw = defaults.string(forKey: Key.hotkeyMode.rawValue) ?? HotkeyMode.pushToTalk.rawValue
            return HotkeyMode(rawValue: raw) ?? .pushToTalk
        }
        set { defaults.set(newValue.rawValue, forKey: Key.hotkeyMode.rawValue); objectWillChange.send() }
    }

    /// Hotkey dedicated to secondary-language dictation, independent of the primary
    /// (English) hotkey above. Default: left Option (58) — distinct from the
    /// primary's default of right Option (61) so both work out of the box without
    /// colliding.
    var secondaryHotkeyKeyCode: Int {
        get { defaults.object(forKey: Key.secondaryHotkeyKeyCode.rawValue) as? Int ?? 58 }
        set { defaults.set(newValue, forKey: Key.secondaryHotkeyKeyCode.rawValue); objectWillChange.send() }
    }

    /// Seconds the hotkey must be held to trigger start/stop in toggle mode.
    /// Clamped on write to the slider range so out-of-band programmatic writes can't break the UI.
    var toggleHoldDuration: Double {
        get {
            let stored = defaults.object(forKey: Key.toggleHoldDuration.rawValue) as? Double ?? 1.5
            // Clamp on read too: an out-of-band raw value (older build, corrupt
            // domain) must not escape the slider range and break the UI/logic.
            return max(0.5, min(3.0, stored))
        }
        set {
            let clamped = max(0.5, min(3.0, newValue))
            defaults.set(clamped, forKey: Key.toggleHoldDuration.rawValue)
            objectWillChange.send()
        }
    }

    var selectedModel: String {
        get {
            let stored = defaults.string(forKey: Key.selectedModel.rawValue) ?? "small.en"
            // Fall back to the default if the stored id doesn't correspond to any
            // catalog model (see ModelInfo.settingsId). Guards against a stale id left
            // behind after the catalog changes.
            let isKnown = ModelManager.ModelInfo.all.contains { $0.settingsId == stored }
            return isKnown ? stored : "small.en"
        }
        set { defaults.set(newValue, forKey: Key.selectedModel.rawValue); objectWillChange.send() }
    }

    /// ISO-639-1-ish Whisper language code for secondary-language dictation (e.g.
    /// "pt" for Portuguese). Defaults to empty — nothing is picked for the user;
    /// the secondary hotkey stays inert (see `DictationEngine`) until a language
    /// is explicitly chosen via the picker in Settings > Secondary Language.
    var secondaryLanguageCode: String {
        get { defaults.string(forKey: Key.secondaryLanguageCode.rawValue) ?? "" }
        set { defaults.set(newValue, forKey: Key.secondaryLanguageCode.rawValue); objectWillChange.send() }
    }

    /// Multilingual model tier for secondary-language dictation. Falls back to the
    /// default if the stored id isn't a known *multilingual* catalog entry (same
    /// guard shape as `selectedModel`, scoped to `isMultilingual` models only so a
    /// stale/foreign id can never select an English-only model for the secondary
    /// slot).
    var secondaryModelSelection: String {
        get {
            let stored = defaults.string(forKey: Key.secondaryModelSelection.rawValue) ?? "small"
            let isKnown = ModelManager.ModelInfo.all.contains { $0.isMultilingual && $0.settingsId == stored }
            return isKnown ? stored : "small"
        }
        set { defaults.set(newValue, forKey: Key.secondaryModelSelection.rawValue); objectWillChange.send() }
    }

    /// Minutes of no successful transcription before a language's model is
    /// automatically unloaded from memory. 0 disables auto-unload for that
    /// language. Clamped to non-negative on both read and write.
    var primaryIdleTimeoutMinutes: Double {
        get { max(0, defaults.object(forKey: Key.primaryIdleTimeoutMinutes.rawValue) as? Double ?? 0) }
        set { defaults.set(max(0, newValue), forKey: Key.primaryIdleTimeoutMinutes.rawValue); objectWillChange.send() }
    }

    var secondaryIdleTimeoutMinutes: Double {
        get { max(0, defaults.object(forKey: Key.secondaryIdleTimeoutMinutes.rawValue) as? Double ?? 10) }
        set { defaults.set(max(0, newValue), forKey: Key.secondaryIdleTimeoutMinutes.rawValue); objectWillChange.send() }
    }

    var soundFeedbackEnabled: Bool {
        get { defaults.object(forKey: Key.soundFeedbackEnabled.rawValue) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.soundFeedbackEnabled.rawValue); objectWillChange.send() }
    }

    var vocabularyPrompt: String {
        get {
            defaults.string(forKey: Key.vocabularyPrompt.rawValue) ?? Self.defaultVocabularyPrompt
        }
        set { defaults.set(newValue, forKey: Key.vocabularyPrompt.rawValue); objectWillChange.send() }
    }

    /// Vocabulary prompt used for secondary-language dictation. Whisper's
    /// `initial_prompt` biases both vocabulary AND style/spelling toward whatever
    /// the prompt itself is written in (see OpenAI's prompting guide) — so a prompt
    /// written with European Portuguese-specific spellings measurably pulls output
    /// away from Whisper's Brazilian-leaning training bias for "pt", even though
    /// Whisper has no separate pt-PT/pt-BR language code to select directly.
    ///
    /// Defaults to a curated PT-PT preset when the current secondary language is
    /// Portuguese, and empty otherwise (no useful generic default exists for an
    /// arbitrary language). Falls back live if the stored value is empty AND the
    /// language is still "pt", so switching away and back to Portuguese without
    /// ever having typed a custom prompt still gets the preset.
    var secondaryVocabularyPrompt: String {
        get {
            if let stored = defaults.string(forKey: Key.secondaryVocabularyPrompt.rawValue), !stored.isEmpty {
                return stored
            }
            return Self.defaultSecondaryVocabularyPrompt(forLanguageCode: secondaryLanguageCode)
        }
        set { defaults.set(newValue, forKey: Key.secondaryVocabularyPrompt.rawValue); objectWillChange.send() }
    }

    /// When true, the secondary prompt is prefixed with the primary (English)
    /// vocabulary prompt — useful for bilingual technical dictation where English
    /// jargon (API, JSON, GitHub, ...) shows up mid-sentence in the secondary
    /// language too. Default false: most secondary-language dictation is prose,
    /// not code-mixed technical speech, so the extra ~500 words of English terms
    /// would otherwise eat into the word budget for no benefit by default.
    var includeEnglishTermsInSecondary: Bool {
        get { defaults.bool(forKey: Key.includeEnglishTermsInSecondary.rawValue) }
        set { defaults.set(newValue, forKey: Key.includeEnglishTermsInSecondary.rawValue); objectWillChange.send() }
    }

    /// The effective base vocabulary text for secondary-language dictation: the
    /// secondary prompt, optionally prefixed with the primary (English) prompt
    /// when `includeEnglishTermsInSecondary` is on. Single source used by
    /// `DictationEngine` so the "include English terms" toggle can't drift between
    /// the streaming and non-streaming transcribe paths.
    var effectiveSecondaryVocabularyBase: String {
        includeEnglishTermsInSecondary
            ? vocabularyPrompt + " " + secondaryVocabularyPrompt
            : secondaryVocabularyPrompt
    }

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: Key.launchAtLogin.rawValue) }
        set { defaults.set(newValue, forKey: Key.launchAtLogin.rawValue); objectWillChange.send() }
    }

    /// Whether the user has seen (or been auto-skipped past) first-launch onboarding.
    /// Defaults to false so a fresh install shows the flow once; existing users who
    /// already have a model on disk are marked complete at launch without ever seeing it.
    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Key.hasCompletedOnboarding.rawValue) }
        set { defaults.set(newValue, forKey: Key.hasCompletedOnboarding.rawValue); objectWillChange.send() }
    }

    var minimumRecordingDuration: Double {
        get {
            let stored = defaults.object(forKey: Key.minimumRecordingDuration.rawValue) as? Double ?? 0.3
            // Clamp on read: a nonsensical raw value must not gate every recording.
            return max(0.0, min(5.0, stored))
        }
        set { defaults.set(newValue, forKey: Key.minimumRecordingDuration.rawValue); objectWillChange.send() }
    }

    var grammarCorrectionEnabled: Bool {
        get { defaults.object(forKey: Key.grammarCorrectionEnabled.rawValue) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.grammarCorrectionEnabled.rawValue); objectWillChange.send() }
    }

    var numberConversionEnabled: Bool {
        get { defaults.object(forKey: Key.numberConversionEnabled.rawValue) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.numberConversionEnabled.rawValue); objectWillChange.send() }
    }

    /// Live dictation (commit-on-pause): type each phrase when the speaker
    /// pauses instead of everything at stop. Default false. Stores intent —
    /// the engine additionally requires the VAD model on disk per session.
    var liveDictationEnabled: Bool {
        get { defaults.bool(forKey: Key.liveDictationEnabled.rawValue) }
        set { defaults.set(newValue, forKey: Key.liveDictationEnabled.rawValue); objectWillChange.send() }
    }

    /// Maximum number of custom vocabulary terms. Mirrors the UI cap; enforced here
    /// so no write path (import, programmatic) can exceed the whisper prompt budget.
    static let maxCustomTerms = 100

    var customTerms: [String] {
        get { defaults.stringArray(forKey: Key.customTerms.rawValue) ?? [] }
        set {
            let capped = Array(newValue.prefix(Self.maxCustomTerms))
            defaults.set(capped, forKey: Key.customTerms.rawValue); objectWillChange.send()
        }
    }

    func addCustomTerm(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var terms = customTerms
        // Avoid duplicates (case-insensitive)
        if !terms.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            terms.append(trimmed)
            customTerms = terms
        }
    }

    func removeCustomTerm(_ term: String) {
        customTerms = customTerms.filter { $0 != term }
    }

    /// nil means "use system default"
    var selectedAudioDeviceUID: String? {
        get { defaults.string(forKey: Key.selectedAudioDeviceUID.rawValue) }
        set { defaults.set(newValue, forKey: Key.selectedAudioDeviceUID.rawValue); objectWillChange.send() }
    }

    // MARK: - Default Vocabulary Prompt

    // ~500 words — under whisper's 1024 token (~750 word) limit
    static let defaultVocabularyPrompt = """
        Technical software engineering discussion. \
        Languages: JavaScript, TypeScript, Python, Swift, SwiftUI, Rust, Go, Golang, \
        Java, Kotlin, C++, C#, F#, Ruby, PHP, Dart, Scala, Haskell, Elixir, Clojure, \
        Zig, Lua, Objective-C, Perl, COBOL, Fortran, Assembly, WASM, WebAssembly. \
        Frameworks: React, Next.js, Vue, Nuxt, Angular, Svelte, SvelteKit, Remix, \
        Astro, Gatsby, Express, Django, Flask, FastAPI, NestJS, Spring Boot, Rails, \
        Laravel, ASP.NET, Gin, Echo, Fiber, Actix, Rocket, Phoenix, Tailwind, \
        Bootstrap, Material UI, Chakra UI, shadcn, Radix, Headless UI, Storybook. \
        Infrastructure: Docker, Kubernetes, AWS, GCP, Azure, Terraform, Ansible, \
        Pulumi, Nginx, Apache, Caddy, Cloudflare, Vercel, Netlify, Heroku, Railway, \
        Fly.io, Render, Lambda, EC2, S3, CloudFront, ECS, EKS, Fargate, RDS, \
        DynamoDB, SQS, SNS, IAM, VPC, Cloud Run, Cloud Functions, BigQuery. \
        Databases: PostgreSQL, MySQL, SQLite, MongoDB, Redis, Elasticsearch, \
        Cassandra, DynamoDB, Firestore, Firebase, Supabase, PlanetScale, Neon, \
        CockroachDB, Prisma, Drizzle, Sequelize, TypeORM, Mongoose, SQLAlchemy, \
        Knex, Kysely, EdgeDB, SurrealDB, Turso, Upstash. \
        APIs: REST, GraphQL, gRPC, WebSocket, tRPC, OpenAPI, Swagger, Postman, \
        JSON, YAML, XML, protobuf, JWT, OAuth, SAML, CORS, CSRF, webhook, \
        endpoint, middleware, rate limiting, pagination, cursor, offset, idempotent. \
        DevOps: Git, GitHub, GitLab, Bitbucket, CI/CD, GitHub Actions, Jenkins, \
        CircleCI, ArgoCD, Helm, kubectl, Prometheus, Grafana, Datadog, Sentry, \
        PagerDuty, container, pod, replica set, deployment, ingress, namespace, \
        artifact, staging, production, canary, blue-green, rollback, hotfix, \
        feature flag, environment variable, secret, load balancer, reverse proxy, \
        API gateway, service mesh, uptime, latency, throughput, SLA, SLO, SLI. \
        Tools: npm, yarn, pnpm, Bun, Deno, Node.js, Webpack, Vite, Rollup, \
        esbuild, SWC, Babel, ESLint, Prettier, Biome, Cargo, pip, Poetry, uv, \
        CocoaPods, Swift Package Manager, Gradle, Maven, homebrew, apt, Turborepo, \
        Nx, Lerna, Changesets, Husky, lint-staged, commitlint. \
        Frontend: tooltip, dropdown, popover, modal, dialog, sidebar, navbar, \
        breadcrumb, carousel, accordion, checkbox, toggle, slider, pagination, \
        skeleton, spinner, toast, snackbar, avatar, badge, chip, tag, tabs, \
        responsive, viewport, breakpoint, flexbox, grid, z-index, opacity, \
        hover, focus, blur, onClick, onChange, onSubmit, useState, useEffect, \
        useRef, useMemo, useCallback, useContext, useReducer, custom hook, \
        SSR, SSG, ISR, hydration, lazy loading, code splitting, tree shaking, \
        bundler, minify, transpile, polyfill, CSS-in-JS, styled-components, \
        SVG, canvas, WebGL, animation, transition, keyframe, media query, \
        accessibility, ARIA, screen reader, semantic HTML, SEO, meta tags, \
        localStorage, sessionStorage, IndexedDB, service worker, PWA, \
        dark mode, light mode, theme, design system, design tokens, Figma. \
        Backend: controller, route, handler, resolver, schema, migration, seed, \
        ORM, query builder, connection pool, transaction, caching, Redis cache, \
        authentication, authorization, session, cookie, token, RBAC, ACL, SSO, MFA, \
        cron job, queue, worker, pub/sub, event-driven, message broker, RabbitMQ, \
        Kafka, NATS, logging, monitoring, tracing, OpenTelemetry, health check, \
        graceful shutdown, retry, circuit breaker, backoff, dead letter queue. \
        Concepts: API, SDK, CLI, IDE, async, await, promise, callback, closure, \
        mutex, semaphore, thread, coroutine, actor, channel, stream, observable, \
        microservice, monolith, serverless, edge function, CDN, \
        HTTP, HTTPS, TCP, UDP, DNS, SSL, TLS, SSH, SMTP, FTP, \
        pull request, merge, rebase, cherry-pick, squash, commit, branch, tag, \
        unit test, integration test, end-to-end test, TDD, BDD, mock, stub, spy, \
        snapshot test, regression, coverage, assertion, fixture, \
        function, class, struct, enum, protocol, interface, component, module, \
        generic, template, trait, mixin, decorator, annotation, abstract, \
        singleton, factory, observer, strategy, adapter, facade, proxy, \
        big O, algorithm, data structure, hash map, linked list, binary tree, \
        recursion, memoization, dynamic programming, sorting, searching. \
        AI: LLM, GPT, Claude, OpenAI, Anthropic, Hugging Face, Ollama, \
        PyTorch, TensorFlow, MLX, ONNX, Whisper, Stable Diffusion, DALL-E, \
        Midjourney, Copilot, RAG, embedding, vector, inference, fine-tuning, \
        tokenizer, attention, transformer, prompt engineering, agent, tool use. \
        Editors: Xcode, VS Code, IntelliJ, Vim, Neovim, Emacs, JetBrains, \
        terminal, shell, bash, zsh, fish, tmux, iTerm, PowerShell, \
        regex, cron, sed, awk, grep, curl, wget, jq, yq.
        """

    // MARK: - Secondary Vocabulary Defaults

    /// Curated European Portuguese (pt-PT) vocabulary preset. Whisper's "pt" model
    /// is trained mostly on Brazilian Portuguese, so its default output leans
    /// pt-BR regardless of the speaker's actual accent — there is no separate
    /// pt-PT language code to select. Writing the prompt itself using PT-PT
    /// spellings (which differ from PT-BR for many everyday words) measurably
    /// biases Whisper's output toward matching that spelling/style, per OpenAI's
    /// documented prompting behavior (the model continues in the style of the
    /// prompt, not just its vocabulary).
    static let defaultPortugalPortuguesePrompt = """
        Transcrição em português europeu de Portugal, com ortografia e vocabulário \
        de Portugal (não brasileiro). Facto, ecrã, ficheiro, ratinho, telemóvel, \
        autocarro, comboio, pequeno-almoço, casa de banho, frigorífico, \
        electrodomésticos, pastelaria, talho, sandes, gelado, sumo, rebuçado, \
        chávena, fato, calças, sapatilhas, camisola, fixe, giro, pois, então, \
        já agora, se calhar, está bem, pronto, tipo, portanto, imenso, bué, \
        atrasado, adiantado, marcação, consulta, hospital, farmácia, \
        conta corrente, multibanco, IVA, factura, orçamento, currículo, \
        reunião, colega, chefe, empresa, escritório, atrasar-me, apanhar o \
        autocarro, ir de comboio, marcar uma reunião, enviar um email, \
        WiFi, router, computador, portátil, aplicação, actualização, \
        Lisboa, Porto, Coimbra, Braga, Faro, Algarve, Alentejo, Minho.
        """

    /// Returns a sensible default secondary vocabulary prompt for `languageCode`,
    /// or an empty string when no curated preset exists for that language yet.
    static func defaultSecondaryVocabularyPrompt(forLanguageCode languageCode: String) -> String {
        switch languageCode {
        case "pt": return defaultPortugalPortuguesePrompt
        default: return ""
        }
    }
}
