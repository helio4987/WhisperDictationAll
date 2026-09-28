import SwiftUI

struct MenuBarView: View {
    let engine: DictationEngine
    @ObservedObject private var permissions = PermissionManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var modelManager = ModelManager.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            // Header with status
            headerSection
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            // Per-language loaded/unloaded state
            languagesSection
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            // Alerts (permissions / errors)
            if !permissions.allPermissionsGranted || engine.modelLoadError != nil || engine.transcriptionError != nil || modelManager.downloadError != nil {
                alertsSection
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }

            // Last transcription
            if !engine.lastTranscription.isEmpty {
                transcriptionSection
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }

            Divider()
                .padding(.horizontal, 12)

            // Actions
            VStack(spacing: 2) {
                MenuButton(title: "Settings...", icon: "gearshape", shortcut: ",") {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }
                MenuButton(title: "Quit WhisperDictation", icon: "power", shortcut: "Q") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            // Version
            Text("v\(Bundle.main.appVersion)")
                .font(.system(size: 10))
                .foregroundStyle(.quaternary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 6)
        }
        .frame(width: 320)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 12) {
            // Status orb
            ZStack {
                Circle()
                    .fill(statusGradient)
                    .frame(width: 36, height: 36)

                if engine.state == .recording {
                    Circle()
                        .stroke(Color.red.opacity(0.4), lineWidth: 2)
                        .frame(width: 44, height: 44)
                }

                Image(systemName: statusIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("WhisperDictation")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    // Model badge — short friendly name
                    if engine.isModelLoaded {
                        Text(modelShortName)
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .tracking(0.3)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.blue.opacity(0.12)))
                            .foregroundStyle(.blue)
                    }
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusDotColor)
                        .frame(width: 6, height: 6)
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
    }

    // MARK: - Languages (loaded/unloaded state)

    private var languagesSection: some View {
        VStack(spacing: 4) {
            LanguageStatusRow(
                label: "Primary (English)",
                isLoaded: engine.isModelLoaded,
                isLoading: false,
                loadFailed: false
            )
            LanguageStatusRow(
                label: "Secondary (\(secondaryLanguageDisplayName))",
                isLoaded: engine.secondaryModelLoadState == .ready,
                isLoading: engine.secondaryModelLoadState == .loading,
                loadFailed: isSecondaryLoadFailed
            )
        }
    }

    private var secondaryLanguageDisplayName: String {
        WhisperLanguages.language(forCode: settings.secondaryLanguageCode)?.displayName
            ?? settings.secondaryLanguageCode
    }

    private var isSecondaryLoadFailed: Bool {
        if case .failed = engine.secondaryModelLoadState { return true }
        return false
    }

    // MARK: - Alerts

    private var alertsSection: some View {
        VStack(spacing: 6) {
            if !permissions.microphoneGranted {
                AlertRow(icon: "mic.slash.fill", text: "Microphone access needed", color: .orange) {
                    permissions.requestMicrophone()
                }
            }
            if !permissions.accessibilityGranted {
                AlertRow(icon: "hand.raised.fill", text: "Accessibility access needed", color: .orange) {
                    permissions.openAccessibilitySettings()
                }
            }
            if let error = engine.modelLoadError {
                AlertRow(icon: "exclamationmark.triangle.fill", text: error, color: .red) {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            if let error = engine.transcriptionError {
                AlertRow(icon: "waveform.badge.exclamationmark", text: error, color: .orange) {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            // Download failures must surface even when Settings (Model tab) isn't open.
            // Cleared automatically when the user retries (startDownload resets it).
            if let error = modelManager.downloadError {
                AlertRow(icon: "exclamationmark.arrow.triangle.2.circlepath", text: error, color: .orange) {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
    }

    // MARK: - Last Transcription

    private var transcriptionSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Last transcription")
                .font(.system(size: 9, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.3)
                .foregroundStyle(.tertiary)

            Text(engine.lastTranscription)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary.opacity(0.5))
                )
        }
    }

    // MARK: - Status Helpers

    private var statusIcon: String {
        switch engine.state {
        case .idle: "waveform"
        case .recording: "mic.fill"
        case .loadingModel: "arrow.down.circle.dotted"
        case .processing: "brain.head.profile.fill"
        case .typing: "text.cursor"
        }
    }

    private var statusText: String {
        switch engine.state {
        case .idle: engine.isModelLoaded ? "Ready — hold \(hotkeyLabel) to dictate" : "Loading model..."
        case .recording: "Listening..."
        case .loadingModel: "Loading language model..."
        case .processing: "Transcribing..."
        case .typing: "Typing..."
        }
    }

    private var statusDotColor: Color {
        switch engine.state {
        case .idle: engine.isModelLoaded ? .green : .orange
        case .recording: .red
        case .loadingModel: .cyan
        case .processing: .orange
        case .typing: .blue
        }
    }

    private var statusGradient: LinearGradient {
        let colors: [Color] = switch engine.state {
        case .idle: [.green.opacity(0.8), .green.opacity(0.5)]
        case .recording: [.red.opacity(0.9), .red.opacity(0.6)]
        case .loadingModel: [.cyan.opacity(0.8), .cyan.opacity(0.5)]
        case .processing: [.orange.opacity(0.8), .orange.opacity(0.5)]
        case .typing: [.blue.opacity(0.8), .blue.opacity(0.5)]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var modelShortName: String {
        let m = settings.selectedModel
        // "base.en-q5_1" → "Base Q5", "small.en" → "Small"
        let base = m.split(separator: ".").first.map(String.init) ?? m
        let isQuantized = m.contains("q5") || m.contains("q8")
        return base.capitalized + (isQuantized ? " Q5" : "")
    }

    private var hotkeyLabel: String {
        KeyCodeNames.shortLabel(for: settings.hotkeyKeyCode)
    }
}

// MARK: - Language Status Row

/// One row per language showing whether its model is currently resident in memory.
/// Primary always reports `isLoading: false` since it has no lazy-load path yet
/// (it loads once at launch and stays loaded) — its dot is simply green once
/// `isModelLoaded` flips true. Secondary genuinely cycles through all three states
/// as it lazily loads on first use and auto-unloads after the configured idle
/// timeout, driven by `LanguageModelSlot`.
private struct LanguageStatusRow: View {
    let label: String
    let isLoaded: Bool
    let isLoading: Bool
    let loadFailed: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(statusLabel)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(dotColor)
        }
    }

    private var dotColor: Color {
        if loadFailed { return .red }
        if isLoading { return .cyan }
        return isLoaded ? .green : .secondary
    }

    private var statusLabel: String {
        if loadFailed { return "Failed" }
        if isLoading { return "Loading…" }
        return isLoaded ? "Loaded" : "Unloaded"
    }
}

// MARK: - Alert Row

private struct AlertRow: View {
    let icon: String
    let text: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(color)
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(color.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Menu Button

private struct MenuButton: View {
    let title: String
    let icon: String
    let shortcut: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13))
                Spacer()
                Text("⌘\(shortcut)")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuButtonStyle())
    }
}

private struct MenuButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(configuration.isPressed ? Color.blue.opacity(0.8) : Color.clear)
            )
            .foregroundStyle(configuration.isPressed ? .white : .primary)
    }
}
