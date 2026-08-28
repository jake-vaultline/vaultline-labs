import SwiftUI

// MARK: - Filling it in

/// The shoot form, as filled at the card.
///
/// Sticky fields keep their value between cards — retyping the production name
/// eleven times in a day is exactly how forms stop getting filled in.
struct ShootForm: View {
    @EnvironmentObject private var state: AppState

    private var fields: [IngestFormField] { state.config.form.fields }

    var body: some View {
        VStack(alignment: .leading, spacing: VL.Space.s) {
            SectionLabel("Details") {
                if !state.missingRequired.isEmpty {
                    Text("\(state.missingRequired.count) required")
                        .font(VL.small).foregroundStyle(VL.amber)
                }
            }

            Panel {
                VStack(alignment: .leading, spacing: VL.Space.m) {
                    ForEach(fields) { field in
                        FieldRow(field: field)
                    }
                }
            }
        }
    }
}

private struct FieldRow: View {
    @EnvironmentObject private var state: AppState
    let field: IngestFormField

    private var isMissing: Bool {
        field.required && (state.formAnswers[field.id] ?? field.resolvedDefault())
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .top, spacing: VL.Space.m) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(field.label).font(VL.body)
                    if field.required || state.isInvalid(field) {
                        Circle().fill(isMissing || state.isInvalid(field) ? VL.amber : VL.steel.opacity(0.5))
                            .frame(width: 4, height: 4)
                    }
                }
                if field.sticky {
                    Text("carries over").font(.system(size: 9.5)).foregroundStyle(VL.inkFaint)
                }
            }
            .frame(width: 128, alignment: .leading)

            control
            if state.isInvalid(field), field.kind == .date {
                Text("Use YYYY-MM-DD").font(.system(size: 9.5)).foregroundStyle(VL.amber)
            }
        }
    }

    @ViewBuilder
    private var control: some View {
        switch field.kind {
        case .text:
            TextField("", text: state.answer(field))
                .textFieldStyle(VLFieldStyle())
                .frame(maxWidth: 300)

        case .longText:
            TextEditor(text: state.answer(field))
                .font(VL.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 62)
                .background(VL.charcoal, in: RoundedRectangle(cornerRadius: VL.Radius.small))
                .overlay(RoundedRectangle(cornerRadius: VL.Radius.small)
                    .strokeBorder(VL.rule, lineWidth: 1))
                .frame(maxWidth: 380)

        case .choice:
            Picker("", selection: state.answer(field)) {
                Text("—").tag("")
                ForEach(field.options, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().frame(maxWidth: 200)

        case .date:
            TextField("", text: state.answer(field),
                      prompt: Text("YYYY-MM-DD").foregroundColor(VL.inkFaint))
                .textFieldStyle(VLFieldStyle())
                .frame(maxWidth: 150)

        case .toggle:
            Toggle("", isOn: Binding(
                get: { state.answer(field).wrappedValue == "yes" },
                set: { state.answer(field).wrappedValue = $0 ? "yes" : "no" }))
                .toggleStyle(.switch).labelsHidden()
        }
    }
}

// MARK: - Configuring it

/// Field editor. The whole point is that these are the user's fields, not ours —
/// so everything is add, rename, reorder, delete. The suggested set is a
/// starting point, never a constraint.
struct FormEditor: View {
    @EnvironmentObject private var state: AppState
    @State private var newLabel = ""

    private var form: IngestFormConfig { state.config.form }
    private var locked: Bool { state.config.isManaged }

    var body: some View {
        VStack(alignment: .leading, spacing: VL.Space.l) {
            VStack(alignment: .leading, spacing: VL.Space.s) {
                Toggle("Ask for shoot details before each ingest", isOn: Binding(
                    get: { form.enabled },
                    set: { v in state.configStore.update { c in
                        c.form.enabled = v
                        if v && c.form.fields.isEmpty { c.form.fields = IngestFormField.suggested }
                    } }))
                    .toggleStyle(.checkbox).font(VL.body).disabled(locked)

                Toggle("Write the answers next to the media as a text file", isOn: Binding(
                    get: { form.writeSidecar },
                    set: { v in state.configStore.update { $0.form.writeSidecar = v } }))
                    .toggleStyle(.checkbox).font(VL.body)
                    .disabled(locked || !form.enabled)

                Text("Plain text, alongside the footage. It survives every migration, opens on any machine, and is still readable in fifty years — which a row in this app's database would not be.")
                    .font(VL.small).foregroundStyle(VL.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if form.enabled {
                VStack(alignment: .leading, spacing: VL.Space.s) {
                    SectionLabel("Fields") {
                        if form.fields.isEmpty {
                            Button("Use suggestions") {
                                state.configStore.update { $0.form.fields = IngestFormField.suggested }
                            }.buttonStyle(VLQuietButton())
                        }
                    }

                    ForEach(Array(form.fields.enumerated()), id: \.element.id) { i, field in
                        FieldEditorRow(index: i, field: field, count: form.fields.count)
                    }

                    HStack(spacing: VL.Space.s) {
                        TextField("", text: $newLabel,
                                  prompt: Text("Add a field…").foregroundColor(VL.inkFaint))
                            .textFieldStyle(VLFieldStyle())
                            .frame(maxWidth: 220)
                            .onSubmit(add)
                        Button("Add", action: add)
                            .buttonStyle(VLButton())
                            .disabled(newLabel.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .disabled(locked)
                }
            }
        }
    }

    private func add() {
        let label = newLabel.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return }
        state.configStore.update { $0.form.fields.append(IngestFormField(label: label)) }
        newLabel = ""
    }
}

private struct FieldEditorRow: View {
    @EnvironmentObject private var state: AppState
    let index: Int
    let field: IngestFormField
    let count: Int
    @State private var hovering = false

    var body: some View {
        HStack(spacing: VL.Space.s) {
            VStack(spacing: 1) {
                Button { move(-1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(VLQuietButton()).disabled(index == 0)
                Button { move(1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(VLQuietButton()).disabled(index == count - 1)
            }
            .font(.system(size: 8))
            .opacity(hovering ? 1 : 0.35)

            TextField("", text: Binding(
                get: { field.label },
                set: { v in update { $0.label = v } }))
                .textFieldStyle(VLFieldStyle())
                .frame(width: 150)

            Picker("", selection: Binding(
                get: { field.kind },
                set: { v in update { $0.kind = v } })
            ) {
                ForEach(IngestFormField.Kind.allCases) { Text($0.displayName).tag($0) }
            }
            .labelsHidden().frame(width: 130)

            Toggle("Required", isOn: Binding(
                get: { field.required },
                set: { v in update { $0.required = v } }))
                .toggleStyle(.checkbox).font(VL.small)

            Toggle("Sticky", isOn: Binding(
                get: { field.sticky },
                set: { v in update { $0.sticky = v } }))
                .toggleStyle(.checkbox).font(VL.small)
                .help("Keeps its value for the next card")

            Spacer()

            Button { state.configStore.update { $0.form.fields.removeAll { $0.id == field.id } } }
                label: { Image(systemName: "xmark") }
                .buttonStyle(VLQuietButton())
                .font(.system(size: 9, weight: .semibold))
                .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, VL.Space.s).padding(.vertical, 6)
        .background(hovering ? VL.slateHi : VL.slate,
                    in: RoundedRectangle(cornerRadius: VL.Radius.small))
        .onHover { hovering = $0 }
    }

    private func update(_ change: @escaping (inout IngestFormField) -> Void) {
        state.configStore.update { c in
            guard let i = c.form.fields.firstIndex(where: { $0.id == field.id }) else { return }
            change(&c.form.fields[i])
        }
    }

    private func move(_ delta: Int) {
        state.configStore.update { c in
            let to = index + delta
            guard c.form.fields.indices.contains(index), c.form.fields.indices.contains(to) else { return }
            c.form.fields.swapAt(index, to)
        }
    }
}
