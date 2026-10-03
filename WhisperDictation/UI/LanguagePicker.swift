import SwiftUI

/// Searchable/autocomplete language picker: a text field that filters
/// `WhisperLanguages.supported` as you type, with a dropdown list of matches.
/// Mirrors the interaction shape of `HotkeyRecorder` (SettingsView.swift) — a
/// field/button that reveals custom UI while active and dismisses on selection.
struct LanguagePicker: View {
    /// The currently selected language code (e.g. "pt"). Two-way bound so the
    /// caller's `AppSettings` property stays in sync as selections are made.
    @Binding var selectedCode: String
    let colorScheme: ColorScheme

    @State private var query: String = ""
    @State private var isEditing: Bool = false
    @FocusState private var isFocused: Bool

    private var results: [WhisperLanguages.Language] {
        WhisperLanguages.filter(query: query)
    }

    private var selectedDisplayName: String {
        if selectedCode.isEmpty { return "Not set" }
        return WhisperLanguages.language(forCode: selectedCode)?.displayName ?? selectedCode
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Search languages…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(colorScheme == .dark ? Color.black.opacity(0.3) : Color(.textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08), lineWidth: 0.5)
                )
                .focused($isFocused)
                .onChange(of: isFocused) { _, focused in
                    isEditing = focused
                    if focused && query.isEmpty {
                        // Seed the field with the current selection's name so typing
                        // immediately narrows from a sensible starting point, while
                        // still showing the full list until the user types.
                        query = ""
                    }
                }
                .onAppear {
                    // Show the selection, not an empty field, when not editing.
                    if query.isEmpty { query = "" }
                }

            if !isEditing {
                // Read-only summary shown when the field isn't focused, so the
                // control communicates the current selection at rest (matching
                // HotkeyRecorder's keycap-at-rest pattern).
                HStack(spacing: 6) {
                    Text(selectedDisplayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selectedCode.isEmpty ? .secondary : .primary)
                    if !selectedCode.isEmpty {
                        Text("(\(selectedCode))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 2)
            }

            if isEditing && !results.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(results) { language in
                            Button {
                                selectedCode = language.code
                                query = ""
                                isFocused = false
                                isEditing = false
                            } label: {
                                HStack {
                                    Text(language.displayName)
                                        .font(.system(size: 12))
                                    Spacer()
                                    Text(language.code)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    language.code == selectedCode
                                        ? (colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
                                        : Color.clear
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 160)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(colorScheme == .dark ? Color.black.opacity(0.2) : Color(.controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08), lineWidth: 0.5)
                )
            } else if isEditing && results.isEmpty {
                Text("No matching language")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
            }
        }
    }
}
