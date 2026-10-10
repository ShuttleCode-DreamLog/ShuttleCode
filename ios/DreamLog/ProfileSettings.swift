import SwiftUI
import Observation

nonisolated struct Profile: Codable {
    var fields: [String: String] = [:]
    var revision = 0
    var updatedAt: Date?
}
nonisolated struct ProfileResponse: Decodable { var profile: Profile }
nonisolated struct ProfileSave: Encodable { var baseRevision: Int; var fields: [String: String] }

nonisolated struct ProfileField: Identifiable {
    let key: String
    let title: String
    var numeric = false
    var id: String { key }
}

// Ordinary fields can be added here without changing storage or request code.
let profileFields: [ProfileField] = [
    .init(key: "name", title: "Name"),
    .init(key: "age", title: "Age", numeric: true),
    .init(key: "city", title: "City"),
    .init(key: "occupation", title: "Occupation")
]

@MainActor @Observable
final class ProfileModel {
    var stored: Profile?
    var fields: [String: String] = [:]
    var isLoading = false
    var isSaving = false
    var error: String?
    var conflict = false
    var keys: [String] {
        let builtins = profileFields.map(\.key).filter { fields[$0] != nil }
        let known = Set(profileFields.map(\.key))
        return builtins + fields.keys.filter { !known.contains($0) }.sorted()
    }
    func load(_ app: AppModel, discard: Bool = false) async {
        guard app.noticeSeen, !app.deleting, !isLoading, !isSaving, let client = app.client else { return }
        isLoading = true
        defer { isLoading = false }
        let epoch = app.journalEpoch
        let result = await client.loadProfile()
        guard epoch == app.journalEpoch, !app.deleting else { return }
        switch result {
        case let .success(profile):
            let replace = stored == nil || discard
            stored = profile
            if replace {
                fields = profile.fields
                if profile.revision == 0 { for field in profileFields { fields[field.key] = "" } }
            }
            if discard { conflict = false }
            error = nil
        case let .failure(failure): error = failure.message
        }
    }
    func save(_ app: AppModel) async {
        guard let stored, !isSaving, !isLoading, !conflict, app.noticeSeen, !app.deleting, !app.savingSettings, let client = app.client else { return }
        isSaving = true; app.savingSettings = true
        defer { isSaving = false; app.savingSettings = false }
        let epoch = app.journalEpoch
        let result = await client.saveProfile(ProfileSave(baseRevision: stored.revision, fields: fields))
        guard epoch == app.journalEpoch, !app.deleting else { return }
        switch result {
        case let .success(profile): self.stored = profile; fields = profile.fields; error = nil
        case let .failure(failure): conflict = failure.code == "revision_conflict"; error = failure.message
        }
    }
}

struct ProfileSettings: View {
    @Environment(AppModel.self) private var app
    @State private var model = ProfileModel()
    @State private var addingField = false
    @State private var fieldKey = ""
    var body: some View {
        Section("Profile") {
            ForEach(model.keys, id: \.self) { key in
                let field = profileFields.first { $0.key == key }
                HStack {
                    TextField(field?.title ?? key.replacingOccurrences(of: "_", with: " ").capitalized, text: Binding(get: { model.fields[key] ?? "" }, set: { model.fields[key] = $0 }), prompt: Text(field?.title ?? key))
                        .keyboardType(field?.numeric == true ? .numberPad : .default)
                        .accessibilityIdentifier("profile_\(key)")
                    Button("Remove \(field?.title ?? key)", systemImage: "minus.circle", role: .destructive) { model.fields.removeValue(forKey: key) }.labelStyle(.iconOnly)
                }
            }
            Button("Add field", systemImage: "plus") { fieldKey = ""; addingField = true }
            Button("Save profile") { Task { await model.save(app) } }
                .disabled(model.stored == nil || model.isLoading || model.conflict)
            if model.isLoading || model.isSaving { ProgressView() }
            if let error = model.error { Text(error).foregroundStyle(.red) }
            if model.conflict {
                Button("Reload profile and discard edits") { Task { await model.load(app, discard: true) } }
                Button("Reload while keeping edits") { Task { await model.load(app); if model.error == nil { model.conflict = false } } }
            } else if model.error != nil {
                Button("Retry loading profile") { Task { await model.load(app) } }
            }
        }
        .disabled(model.isLoading || model.isSaving || app.deleting)
        .task { await model.load(app) }
        .alert("Add profile field", isPresented: $addingField) {
            TextField("Field name", text: $fieldKey).autocorrectionDisabled()
            Button("Add") {
                let key = fieldKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: " ", with: "_")
                if key.range(of: "^[a-z][a-z0-9_]{0,39}$", options: .regularExpression) != nil, model.fields.count < 30 {
                    if model.fields[key] == nil { model.fields[key] = "" }
                } else { model.error = "Use a lowercase field key and at most 30 fields." }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("For example: Hometown or Favorite color.") }
    }
}
