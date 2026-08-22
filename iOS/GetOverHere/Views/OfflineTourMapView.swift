import CoreLocation
import MapLibre
import SwiftUI
import TourSessionCore

struct OfflineTourMapView: UIViewRepresentable {
    let configuration: OfflineMapConfiguration
    let target: TargetSnapshotPayload?
    let localCoordinate: CLLocationCoordinate2D?
    let allowsTargetPlacement: Bool
    let onTargetPlaced: (CLLocationCoordinate2D) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> MLNMapView {
        let mapView = MLNMapView(frame: .zero, styleJSON: configuration.styleJSON)
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.delegate = context.coordinator
        mapView.logoView.isHidden = true
        mapView.attributionButton.isHidden = true
        if allowsTargetPlacement {
            let recognizer = UILongPressGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.didLongPress(_:))
            )
            recognizer.minimumPressDuration = 0.45
            mapView.addGestureRecognizer(recognizer)
        }
        context.coordinator.mapView = mapView
        context.coordinator.updateAnnotations()
        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        context.coordinator.parent = self
        if mapView.styleJSON != configuration.styleJSON {
            mapView.styleJSON = configuration.styleJSON
            context.coordinator.focusedTargetVersion = nil
            context.coordinator.didFocusLocal = false
        }
        context.coordinator.updateAnnotations()
    }

    @MainActor
    final class Coordinator: NSObject, MLNMapViewDelegate {
        var parent: OfflineTourMapView
        weak var mapView: MLNMapView?
        fileprivate var annotations: [TourPointAnnotation] = []
        var focusedTargetVersion: UInt64?
        var didFocusLocal = false

        init(parent: OfflineTourMapView) {
            self.parent = parent
        }

        @objc func didLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began, let mapView else { return }
            let coordinate = mapView.convert(recognizer.location(in: mapView), toCoordinateFrom: mapView)
            parent.onTargetPlaced(coordinate)
        }

        func updateAnnotations() {
            guard let mapView else { return }
            if !annotations.isEmpty { mapView.removeAnnotations(annotations) }
            annotations = []

            if let coordinate = parent.localCoordinate {
                let annotation = TourPointAnnotation(kind: .localUser)
                annotation.coordinate = coordinate
                annotation.title = "You"
                annotations.append(annotation)
            }
            if let target = parent.target, target.isVisible {
                let annotation = TourPointAnnotation(kind: .target)
                annotation.coordinate = CLLocationCoordinate2D(
                    latitude: Double(target.latitudeE7) / 10_000_000,
                    longitude: Double(target.longitudeE7) / 10_000_000
                )
                annotation.title = target.label.isEmpty ? "Guide target" : target.label
                annotations.append(annotation)
            }
            if !annotations.isEmpty { mapView.addAnnotations(annotations) }

            if let target = parent.target,
               target.isVisible,
               focusedTargetVersion != target.stateVersion {
                mapView.setCenter(
                    CLLocationCoordinate2D(
                        latitude: Double(target.latitudeE7) / 10_000_000,
                        longitude: Double(target.longitudeE7) / 10_000_000
                    ),
                    zoomLevel: 16,
                    animated: true
                )
                focusedTargetVersion = target.stateVersion
            } else if parent.target?.isVisible != true,
                      !didFocusLocal,
                      let coordinate = parent.localCoordinate {
                mapView.setCenter(coordinate, zoomLevel: 16, animated: false)
                didFocusLocal = true
            }
        }

        func mapView(
            _ mapView: MLNMapView,
            imageFor annotation: any MLNAnnotation
        ) -> MLNAnnotationImage? {
            guard let point = annotation as? TourPointAnnotation else { return nil }
            let identifier = point.kind == .target ? "tour-target" : "local-user"
            if let reused = mapView.dequeueReusableAnnotationImage(withIdentifier: identifier) {
                return reused
            }
            let symbolName = point.kind == .target ? "mappin.circle.fill" : "location.circle.fill"
            let color = point.kind == .target ? UIColor.systemRed : UIColor.systemBlue
            let configuration = UIImage.SymbolConfiguration(pointSize: 30, weight: .bold)
            guard let image = UIImage(systemName: symbolName, withConfiguration: configuration)?
                .withTintColor(color, renderingMode: .alwaysOriginal) else { return nil }
            return MLNAnnotationImage(image: image, reuseIdentifier: identifier)
        }
    }
}

private final class TourPointAnnotation: MLNPointAnnotation {
    enum Kind { case localUser, target }
    let kind: Kind

    init(kind: Kind) {
        self.kind = kind
        super.init()
    }

    required init?(coder: NSCoder) {
        nil
    }
}
