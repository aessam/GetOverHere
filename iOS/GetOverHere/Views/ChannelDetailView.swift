import PhotosUI
import SwiftUI
import TourSessionCore
import UniformTypeIdentifiers
import CoreLocation

struct ChannelDetailView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var photoImportError: String?
    @State private var mapImportError: String?
    @State private var guestMinimizedSlide = false
    @State private var selectedFeature: TourFeature = .slides
    @State private var isMapImporterPresented = false
    @State private var pendingTargetCoordinate: CLLocationCoordinate2D?
    @State private var targetLabelDraft = ""

    private var service: ChannelService { coordinator.channelService }
    private var presentation: TourControlService { service.tourControlService }

    var body: some View {
        Group {
            if let channel = service.activeChannel {
                if service.isCreator {
                    guideView(channel)
                } else {
                    guestView(channel)
                }
            } else {
                noChannelView
            }
        }
        .onChange(of: selectedPhotos) { _, items in
            guard !items.isEmpty else { return }
            selectedPhotos = []
            Task { await importPhotos(items) }
        }
        .onChange(of: presentation.snapshot?.stateVersion) { oldValue, newValue in
            if newValue != oldValue {
                guestMinimizedSlide = false
                if !service.isCreator, presentation.isVisible {
                    selectedFeature = .slides
                }
            }
        }
        .onChange(of: presentation.targetSnapshot?.stateVersion) { oldValue, newValue in
            if !service.isCreator, newValue != oldValue, presentation.targetSnapshot?.isVisible == true {
                selectedFeature = .map
            }
        }
        .onChange(of: presentation.bearingSnapshot?.stateVersion) { oldValue, newValue in
            if !service.isCreator, newValue != oldValue, presentation.bearingSnapshot?.isVisible == true {
                selectedFeature = .pointer
            }
        }
        .onChange(of: presentation.visualFocusSnapshot?.stateVersion, initial: true) { _, _ in
            guard !service.isCreator, let mode = presentation.visualFocusSnapshot?.mode else { return }
            selectedFeature = TourFeature(mode)
        }
        .onChange(of: selectedFeature) { _, feature in
            guard service.isCreator else { return }
            service.setVisualFocus(feature.visualMode)
        }
        .fileImporter(
            isPresented: $isMapImporterPresented,
            allowedContentTypes: [.json, Self.pmTilesType],
            allowsMultipleSelection: true,
            onCompletion: handleMapImport
        )
        .alert(
            "Share Target Pin",
            isPresented: Binding(
                get: { pendingTargetCoordinate != nil },
                set: { if !$0 { pendingTargetCoordinate = nil } }
            )
        ) {
            TextField("Optional label", text: $targetLabelDraft)
            Button("Cancel", role: .cancel) { pendingTargetCoordinate = nil }
            Button("Share") {
                guard let coordinate = pendingTargetCoordinate else { return }
                service.setTarget(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    label: targetLabelDraft
                )
                pendingTargetCoordinate = nil
            }
        } message: {
            Text("Only this selected pin and its label will be sent to guests.")
        }
    }

    private var noChannelView: some View {
        ContentUnavailableView(
            "Create or join a tour",
            systemImage: "megaphone.fill",
            description: Text("The guide broadcasts audio, slides, and a shared destination over the local network.")
        )
    }

    private func guideView(_ channel: Channel) -> some View {
        VStack(spacing: 0) {
            sessionHeader(channel, accent: .red, status: "LIVE")
            if let tourCode = service.tourCode {
                HStack {
                    Text("TOUR CODE")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text(tourCode)
                        .font(.title3.monospaced().bold())
                        .textSelection(.enabled)
                    Spacer()
                    Text("Share with guests")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.bottom, 10)
            }
            Divider()
            featurePicker
                .padding(.horizontal)
                .padding(.top, 8)
            Group {
                switch selectedFeature {
                case .slides: guideSlideStage
                case .map: guideMapStage
                case .pointer: guidePointerStage
                }
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Label("\(service.listenerCount) listeners", systemImage: "person.2.fill")
                    .foregroundStyle(.secondary)
                if !presentation.slides.isEmpty {
                    Text("\(service.assetTransferService.readyParticipantIDs.count) ready")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("End Tour", systemImage: "xmark.circle.fill", role: .destructive) {
                    service.leaveChannel()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding()
        }
        .navigationTitle(channel.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var guideSlideStage: some View {
        VStack(spacing: 16) {
            if let error = photoImportError ?? service.tourFeatureError ?? service.assetTransferService.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }

            if presentation.slides.isEmpty {
                ContentUnavailableView {
                    Label("No Slides", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("Choose photos to prepare them locally and send verified copies to every guest.")
                } actions: {
                    photoPicker
                }
            } else {
                if let url = guideCurrentSlideURL {
                    SlideImage(url: url)
                        .padding(.horizontal)
                }

                HStack(spacing: 20) {
                    Button("Previous", systemImage: "chevron.left") {
                        service.previousSlide()
                    }
                    .disabled(!presentation.canGoPrevious)

                    Button {
                        presentation.isVisible ? service.hideSlides() : service.showSlide()
                    } label: {
                        Label(
                            presentation.isVisible ? "Hide" : "Show",
                            systemImage: presentation.isVisible ? "eye.slash.fill" : "play.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Next", systemImage: "chevron.right") {
                        service.nextSlide()
                    }
                    .labelStyle(.titleAndIcon)
                    .disabled(!presentation.canGoNext)
                }

                if let slideID = presentation.currentSlideID,
                   let index = presentation.currentSlideIndex {
                    HStack(spacing: 12) {
                        Button("Move Earlier", systemImage: "arrow.left") {
                            Task { await service.moveSlide(assetID: slideID, to: index - 1) }
                        }
                        .disabled(index == 0)
                        Button("Move Later", systemImage: "arrow.right") {
                            Task { await service.moveSlide(assetID: slideID, to: index + 1) }
                        }
                        .disabled(index == presentation.slides.index(before: presentation.slides.endIndex))
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            Task { await service.removeSlide(assetID: slideID) }
                        }
                    }
                    .buttonStyle(.bordered)
                }

                ScrollView(.horizontal) {
                    LazyHStack(spacing: 10) {
                        ForEach(presentation.slides, id: \.assetID) { slide in
                            if let url = service.contentStore.sourcesByAssetID[slide.assetID] {
                                Button {
                                    service.showSlide(assetID: slide.assetID)
                                } label: {
                                    SlideThumbnail(
                                        url: url,
                                        isSelected: slide.assetID == presentation.currentSlideID
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        photoPicker
                    }
                    .padding(.horizontal)
                }
                .frame(height: 76)
            }

            if service.isImportingSlides {
                ProgressView("Preparing slides…")
                    .padding(.bottom, 8)
            }
        }
        .padding(.vertical)
    }

    private var photoPicker: some View {
        PhotosPicker(
            selection: $selectedPhotos,
            maxSelectionCount: 50,
            matching: .images
        ) {
            Label("Add Slides", systemImage: "photo.badge.plus")
        }
        .buttonStyle(.bordered)
        .disabled(service.isImportingSlides)
    }

    private func guestView(_ channel: Channel) -> some View {
        VStack(spacing: 0) {
            sessionHeader(channel, accent: .blue, status: guestConnectionStatus)
            Divider()
            featurePicker
                .padding(.horizontal)
                .padding(.top, 8)

            Group {
                if selectedFeature == .map {
                    guestMapStage
                } else if selectedFeature == .pointer {
                    guestPointerStage
                } else if presentation.isVisible, let slideID = presentation.currentSlideID {
                    if guestMinimizedSlide {
                        ContentUnavailableView {
                            Label("Slide Minimized", systemImage: "rectangle.compress.vertical")
                        } actions: {
                            Button("Show Slide") { guestMinimizedSlide = false }
                                .buttonStyle(.borderedProminent)
                        }
                    } else if let url = service.assetTransferService.readyURLsByAssetID[slideID] {
                        VStack(spacing: 12) {
                            SlideImage(url: url)
                            Button("Minimize", systemImage: "chevron.down") {
                                guestMinimizedSlide = true
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding()
                    } else {
                        ProgressView("Preparing slide…")
                    }
                } else {
                    ContentUnavailableView(
                        "Listening to the guide",
                        systemImage: "headphones",
                        description: Text("Slides and the shared destination appear here when the guide presents them.")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack {
                Button {
                    service.setListenerOutput(service.listenerOutput.toggled)
                } label: {
                    Label(service.listenerOutput.title, systemImage: service.listenerOutput.systemImage)
                }
                .buttonStyle(.borderedProminent)

                Spacer()

                Button("Leave", systemImage: "arrow.left.circle") {
                    service.leaveChannel()
                }
                .buttonStyle(.bordered)
            }
            .padding()
        }
        .navigationTitle(channel.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sessionHeader(_ channel: Channel, accent: Color, status: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: service.isCreator ? "megaphone.fill" : "speaker.wave.3.fill")
                .font(.title2)
                .foregroundStyle(accent)
                .symbolEffect(.variableColor, isActive: service.listenState != .idle)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name).font(.headline)
                Text(status)
                    .font(.caption.bold())
                    .foregroundStyle(service.connectionState == .failed ? Color.red : accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !service.isCreator {
                Text(service.listenerOutput == .privateAudio ? "Anti-feedback" : "Speaker")
                    .font(.caption)
                    .foregroundStyle(service.listenerOutput == .privateAudio ? Color.secondary : Color.orange)
            }
        }
        .padding()
    }

    private var guideCurrentSlideURL: URL? {
        guard let slideID = presentation.currentSlideID else { return nil }
        return service.contentStore.sourcesByAssetID[slideID]
    }

    private var guestConnectionStatus: String {
        service.connectionState.guestStatusText(error: service.tourFeatureError)
    }

    private var featurePicker: some View {
        Picker("Tour feature", selection: $selectedFeature) {
            ForEach(TourFeature.allCases) { feature in
                Label(feature.title, systemImage: feature.systemImage).tag(feature)
            }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var guideMapStage: some View {
        if let configuration = service.offlineMapConfiguration {
            VStack(spacing: 10) {
                if let error = mapImportError ?? service.tourFeatureError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                }
                mapStatusPanel(isGuide: true)
                OfflineTourMapView(
                    configuration: configuration,
                    target: presentation.targetSnapshot,
                    localCoordinate: service.localGuidanceService.location?.coordinate,
                    allowsTargetPlacement: true
                ) { coordinate in
                    targetLabelDraft = presentation.targetSnapshot?.label ?? ""
                    pendingTargetCoordinate = coordinate
                }
                .id(configuration.styleJSON)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal)
                Text("Long-press the map to place or move the guest target.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Replace Offline Map", systemImage: "square.and.arrow.down") {
                        isMapImporterPresented = true
                    }
                    .buttonStyle(.bordered)
                    if presentation.targetSnapshot?.isVisible == true {
                        Button("Edit Label", systemImage: "pencil") {
                            guard let target = presentation.targetSnapshot else { return }
                            targetLabelDraft = target.label
                            pendingTargetCoordinate = CLLocationCoordinate2D(
                                latitude: Double(target.latitudeE7) / 10_000_000,
                                longitude: Double(target.longitudeE7) / 10_000_000
                            )
                        }
                        .buttonStyle(.bordered)
                        Button("Clear Target", systemImage: "mappin.slash", role: .destructive) {
                            service.clearTarget()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(.vertical, 10)
            .onAppear { service.localGuidanceService.requestAccessAndStart() }
        } else {
            ContentUnavailableView {
                Label("No Offline Map", systemImage: "map")
            } description: {
                Text("Select one MapLibre style JSON and one PMTiles v3 archive. The style source URL must be \(OfflineMapPack.archivePlaceholder).")
            } actions: {
                Button("Import Offline Map", systemImage: "square.and.arrow.down") {
                    isMapImporterPresented = true
                }
                .buttonStyle(.borderedProminent)
            }
            .overlay(alignment: .top) {
                VStack {
                    if let error = mapImportError ?? service.tourFeatureError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding()
                    }
                    if service.isImportingMap { ProgressView("Preparing map…").padding() }
                }
            }
        }
    }

    @ViewBuilder
    private var guestMapStage: some View {
        if let configuration = service.offlineMapConfiguration {
            VStack(spacing: 10) {
                mapStatusPanel(isGuide: false)
                OfflineTourMapView(
                    configuration: configuration,
                    target: presentation.targetSnapshot,
                    localCoordinate: service.localGuidanceService.location?.coordinate,
                    allowsTargetPlacement: false,
                    onTargetPlaced: { _ in }
                )
                .id(configuration.styleJSON)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal)
                Text("Your blue location stays on this device. Only the red target pin is shared.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 10)
            .onAppear { service.localGuidanceService.requestAccessAndStart() }
        } else {
            switch service.offlineMapStatus {
            case .unavailable:
                ContentUnavailableView(
                    "No Offline Map",
                    systemImage: "map",
                    description: Text("The guide has not added an offline map to this tour.")
                )
            case .transferring:
                ContentUnavailableView(
                    "Preparing Offline Map",
                    systemImage: "arrow.down.map",
                    description: Text("The verified map pack will appear when its local transfer completes.")
                )
            case .ready:
                ProgressView("Opening offline map…")
            case let .failed(message):
                ContentUnavailableView(
                    "Offline Map Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            }
        }
    }

    @ViewBuilder
    private func mapStatusPanel(isGuide: Bool) -> some View {
        if let target = presentation.targetSnapshot, target.isVisible {
            let guidance = service.localGuidanceService.guidance(to: target)
            HStack(spacing: 12) {
                if let angle = guidance?.relativeArrowDegrees {
                    Image(systemName: "location.north.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                        .rotationEffect(.degrees(angle))
                } else {
                    Image(systemName: "mappin.circle.fill").font(.title2).foregroundStyle(.red)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.label.isEmpty ? "Guide target" : target.label).font(.headline)
                    if let guidance {
                        Text(Self.distanceText(guidance.distanceMeters)).foregroundStyle(.secondary)
                    } else {
                        Text(localGuidanceStatusText).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isGuide {
                    Text("Shared pin").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
        } else {
            Label(
                isGuide ? "Long-press to share a target" : "Waiting for the guide to place a target",
                systemImage: "mappin.and.ellipse"
            )
            .foregroundStyle(.secondary)
        }
    }

    private var localGuidanceStatusText: String {
        switch service.localGuidanceService.status {
        case .idle:
            "Enable location for local distance and direction"
        case .needsPermission:
            "Location permission is required for local distance and direction"
        case .locating:
            "Finding your location…"
        case .ready:
            "Location is temporarily unavailable"
        case let .unavailable(message):
            "Location unavailable: \(message)"
        }
    }

    private var guidePointerStage: some View {
        VStack(spacing: 22) {
            Spacer()
            if let heading = service.localGuidanceService.magneticHeadingDegrees {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 112, weight: .bold))
                    .foregroundStyle(.orange)
                Text("\(Int(heading.rounded()))° magnetic")
                    .font(.title2.monospacedDigit())
                if let accuracy = service.localGuidanceService.headingAccuracyDegrees {
                    Text("Accuracy ±\(Int(accuracy.rounded()))°")
                        .foregroundStyle(accuracy > 25 ? .orange : .secondary)
                }
                Button("Point Guests This Way", systemImage: "location.north.circle.fill") {
                    service.shareCurrentBearing()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else if service.localGuidanceService.headingAccuracyDegrees.map({ $0 < 0 }) == true {
                ContentUnavailableView(
                    "Compass Unavailable",
                    systemImage: "location.slash",
                    description: Text("This device cannot provide a reliable heading.")
                )
            } else {
                ProgressView("Reading compass…")
            }
            if presentation.bearingSnapshot?.isVisible == true {
                Button("Stop Pointer", systemImage: "stop.circle", role: .destructive) {
                    service.clearBearing()
                }
                .buttonStyle(.bordered)
            }
            Text("Only the selected bearing angle is shared. Device location and guest compass readings stay local.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
        }
        .onAppear { service.localGuidanceService.startHeadingOnly() }
    }

    private var guestPointerStage: some View {
        VStack(spacing: 24) {
            Spacer()
            if let bearing = presentation.bearingSnapshot, bearing.isVisible {
                let sharedDegrees = Double(bearing.bearingMilliDegrees) / 1_000
                let relative = service.localGuidanceService.magneticHeadingDegrees.map {
                    TargetGuidance.relativeArrowDegrees(targetBearing: sharedDegrees, deviceHeading: $0)
                }
                let compassUnavailable = service.localGuidanceService.headingAccuracyDegrees.map({ $0 < 0 }) == true
                Image(systemName: "location.north.fill")
                    .font(.system(size: 150, weight: .black))
                    .foregroundStyle(.orange)
                    .rotationEffect(.degrees(relative ?? 0))
                    .animation(.smooth(duration: 0.18), value: relative)
                Text(compassUnavailable ? "Compass unavailable" : (relative == nil ? "Reading compass…" : "Look this way"))
                    .font(.title.bold())
                Text("Guide bearing \(Int(sharedDegrees.rounded()))° magnetic")
                    .foregroundStyle(.secondary)
                if let accuracy = service.localGuidanceService.headingAccuracyDegrees, accuracy >= 0 {
                    Text("Compass accuracy ±\(Int(accuracy.rounded()))°")
                        .foregroundStyle(accuracy > 25 ? .orange : .secondary)
                } else {
                    Text("Compass accuracy unavailable")
                        .foregroundStyle(.orange)
                }
            } else {
                ContentUnavailableView(
                    "No Active Pointer",
                    systemImage: "location.north.circle",
                    description: Text("The guide can point everyone toward the same sightline.")
                )
            }
            Text("Your compass reading stays on this device.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .onAppear { service.localGuidanceService.startHeadingOnly() }
    }

    @MainActor
    private func importPhotos(_ items: [PhotosPickerItem]) async {
        var imports: [ChannelService.SlideImport] = []
        do {
            for item in items {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw PhotoImportError.missingData
                }
                let mimeType = item.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg"
                imports.append(.init(data: data, mimeType: mimeType))
            }
            photoImportError = nil
            await service.importSlides(imports)
        } catch {
            photoImportError = error.localizedDescription
        }
    }

    private func handleMapImport(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            guard let styleURL = urls.first(where: { $0.pathExtension.lowercased() == "json" }),
                  let archiveURL = urls.first(where: { $0.pathExtension.lowercased() == "pmtiles" }),
                  urls.count == 2 else {
                throw MapImportSelectionError.invalidSelection
            }
            mapImportError = nil
            Task { await service.importOfflineMap(styleURL: styleURL, archiveURL: archiveURL) }
        } catch {
            mapImportError = error.localizedDescription
        }
    }

    private static var pmTilesType: UTType {
        UTType(filenameExtension: "pmtiles") ?? .data
    }

    private static func distanceText(_ meters: Double) -> String {
        meters < 1_000 ? "\(Int(meters.rounded())) m away" : String(format: "%.1f km away", meters / 1_000)
    }
}

private enum TourFeature: String, CaseIterable, Identifiable {
    case slides
    case map
    case pointer

    var id: Self { self }
    init(_ mode: TourVisualMode) {
        switch mode {
        case .slides: self = .slides
        case .map: self = .map
        case .pointer: self = .pointer
        }
    }

    var visualMode: TourVisualMode {
        switch self {
        case .slides: .slides
        case .map: .map
        case .pointer: .pointer
        }
    }
    var title: String {
        switch self {
        case .slides: "Slides"
        case .map: "Map"
        case .pointer: "Pointer"
        }
    }

    var systemImage: String {
        switch self {
        case .slides: "photo.on.rectangle"
        case .map: "map.fill"
        case .pointer: "location.north.fill"
        }
    }
}

private enum MapImportSelectionError: LocalizedError {
    case invalidSelection

    var errorDescription: String? {
        "Select exactly one .json style and one .pmtiles archive"
    }
}

private enum PhotoImportError: LocalizedError {
    case missingData

    var errorDescription: String? { "A selected photo could not be read" }
}

private struct SlideImage: View {
    let url: URL

    var body: some View {
        Group {
            if let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ContentUnavailableView("Slide unavailable", systemImage: "exclamationmark.triangle")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

private struct SlideThumbnail: View {
    let url: URL
    let isSelected: Bool

    var body: some View {
        Group {
            if let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: 88, height: 62)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 3)
        }
    }
}
