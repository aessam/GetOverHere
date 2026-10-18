import SwiftUI
import TourSessionCore
import UIKit
import UniformTypeIdentifiers

/// Tours prepared before going live (ADR-080 DSCN-1): build the deck offline, share it as a `.gohtour`
/// so guests arrive with every file, then go live from it.
struct PreparedToursView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @State private var newTourName = ""
    @State private var showNewTour = false
    @State private var pdfTarget: UUID?
    @State private var shareURL: URL?
    @State private var busy = false
    @State private var errorMessage: String?

    private var store: PreparedTourStore { coordinator.preparedTours }

    var body: some View {
        NavigationStack {
            List {
                if store.tours.isEmpty {
                    ContentUnavailableView("No Prepared Tours", systemImage: "tray",
                                           description: Text("Create a tour, add a PDF, and share it with guests before you go live."))
                }
                ForEach(store.tours, id: \.packID) { tour in
                    row(tour)
                }
                .onDelete { offsets in
                    for index in offsets { remove(store.tours[index].packID) }
                }
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }
            }
            .navigationTitle("Prepared Tours")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("New Tour", systemImage: "plus") { newTourName = ""; showNewTour = true }
                        .keyboardShortcut("n", modifiers: [.command, .shift])
                }
            }
            .alert("New Tour", isPresented: $showNewTour) {
                TextField("Tour name", text: $newTourName)
                Button("Cancel", role: .cancel) {}
                Button("Create") { create() }.disabled(newTourName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .fileImporter(isPresented: Binding(get: { pdfTarget != nil }, set: { if !$0 { pdfTarget = nil } }),
                          allowedContentTypes: [.pdf]) { result in
                guard let packID = pdfTarget else { return }
                Task { await addPDF(result, to: packID) }
            }
            .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
                if let shareURL { ShareSheet(items: [shareURL]) }
            }
            .overlay { if busy { ProgressView().controlSize(.large) } }
        }
    }

    private func row(_ tour: TourPackManifestPayload) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tour.displayName).font(.body.bold())
            Text("\(tour.assets.filter { $0.kind == .slide }.count) slides · version \(tour.manifestVersion)")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Add PDF", systemImage: "doc.badge.plus") { pdfTarget = tour.packID }
                Button("Share", systemImage: "square.and.arrow.up") { share(tour.packID) }
                    .disabled(tour.assets.isEmpty)
                Spacer()
                Button("Go Live", systemImage: "megaphone.fill") { goLive(tour.packID) }
                    .buttonStyle(.borderedProminent)
                    .disabled(tour.assets.isEmpty || coordinator.channelService.activeChannelID != nil)
            }
            .buttonStyle(.bordered)
            .labelStyle(.titleAndIcon)
            .font(.caption)
        }
        .padding(.vertical, 4)
    }

    private func create() {
        do {
            _ = try store.create(name: newTourName.trimmingCharacters(in: .whitespaces))
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func addPDF(_ result: Result<URL, Error>, to packID: UUID) async {
        busy = true
        defer { busy = false }
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let slides = try await PDFSlideRenderer.render(try await PDFSlideRenderer.readDocument(at: url))
            _ = try await store.addSlides(slides, to: packID)
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func share(_ packID: UUID) {
        busy = true
        defer { busy = false }
        do {
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "SharedTours-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            shareURL = try store.export(packID, to: directory)
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func goLive(_ packID: UUID) {
        do {
            let launch = try store.launch(packID)
            coordinator.channelService.createChannel(name: launch.manifest.displayName, prepared: launch)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }

    private func remove(_ packID: UUID) {
        do { try store.remove(packID); errorMessage = nil } catch { errorMessage = error.localizedDescription }
    }
}

/// System share sheet (AirDrop, Files, Messages, Mail) for an exported `.gohtour`.
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
