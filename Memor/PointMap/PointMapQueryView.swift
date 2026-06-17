//
//  PointMapQueryView.swift
//  Memor
//
//  Map-based query rendering: marker view, pan/zoom map canvas, and content-wrapper helpers.
//

import AppKit
import CoreLocation
import MapKit
import SwiftUI

enum QueryRenderContent {
    case html(question: String, answer: String, revealAnswer: Bool)
    case pointMap(PointMapStudyPayload, revealName: Bool)
    case boundaryMap(BoundaryMapStudyPayload, revealName: Bool)
}

struct QueryContentView: View {
    let content: QueryRenderContent
    var disableUserInteraction: Bool = false
    var onInstanceLinkActivated: ((Int64) -> Void)? = nil

    var body: some View {
        switch content {
        case .html(_, _, _):
            // Callers pre-render HTML via buildRenderedAnswerHTML/buildRenderedQuestionHTML
            // and pass the result through pointMapHTML path; this case is not used currently.
            EmptyView()
        case .pointMap(let payload, let revealName):
            PointMapQueryView(payload: payload, revealName: revealName)
        case .boundaryMap(let payload, let revealName):
            BoundaryMapQueryView(payload: payload, revealName: revealName)
        }
    }
}

struct MapPointMarker: View {
    let name: String
    let size: CGFloat
    let isHighlighted: Bool
    let showTooltipOnHover: Bool
    var onHoverChange: (Bool) -> Void = { _ in }

    @State private var isHovered = false

    var body: some View {
        Circle()
            .fill(isHighlighted ? Color.red : Color.yellow.opacity(0.85))
            .overlay {
                Circle()
                    .stroke(isHighlighted ? Color.white : Color.black.opacity(0.3), lineWidth: 1)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .onHover { hovering in
                isHovered = hovering
                onHoverChange(hovering)
            }
            .overlay(alignment: .bottom) {
                if showTooltipOnHover && isHovered && !name.isEmpty {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .fixedSize()
                        .offset(y: size + 14)
                        .allowsHitTesting(false)
                }
            }
    }
}

// Shared map tooltip styling, reused for both the hover tooltip and the
// persistent forward-answer tooltip.
struct MapTooltipLabel: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.caption)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .fixedSize()
            .allowsHitTesting(false)
    }
}

struct PointMapQueryView: View {
    let payload: PointMapStudyPayload
    var revealName: Bool
    var onAnswerSelected: () -> Void

    @State private var hoverInfo: HoverInfo?
    @State private var answerInfo: HoverInfo?
    // Reverse queries: which point the user clicked (their guess), if any.
    @State private var clickedPointID: Int64?

    // The persistent answer tooltip is only for forward queries after reveal.
    private var showsAnswerTooltip: Bool {
        revealName && payload.showHighlight && !payload.isReverse
    }

    // After a reverse query is revealed, color the prompt by whether the user
    // clicked the correct point: green if correct, red if wrong. Neutral if no
    // guess was made (e.g. revealed via the keyboard) or for forward queries.
    private var answerTextColor: Color {
        guard payload.isReverse, revealName, let clickedPointID else { return .primary }
        return clickedPointID == payload.pointID ? .green : .red
    }

    // Reddish tint for the pre-reveal hint text on Forward point queries.
    private static let hintColor = Color(red: 0.85, green: 0.26, blue: 0.26)

    // In a reverse query the user is shown the name and must click the matching
    // point. Before they reveal, the answer must not be pre-highlighted and the
    // points become interactive (hover-red + pointer + click-to-reveal).
    private var reverseInteractive: Bool { payload.isReverse && !revealName }

    init(payload: PointMapStudyPayload, revealName: Bool = false, onAnswerSelected: @escaping () -> Void = {}) {
        self.payload = payload
        self.revealName = revealName
        self.onAnswerSelected = onAnswerSelected
    }

    struct HoverInfo: Equatable {
        let pointID: Int64
        let name: String
        let position: CGPoint
        let markerSize: CGFloat
    }

    var body: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .topLeading) {
                PointMapMKMapView(
                    payload: payload,
                    revealName: revealName,
                    reverseInteractive: reverseInteractive,
                    onAnswerSelected: { clickedID in
                        clickedPointID = clickedID
                        onAnswerSelected()
                    },
                    onHoverChange: { info in
                        hoverInfo = info
                    },
                    onAnswerPositionChange: { info in
                        // Dedupe to avoid an update → setState → update feedback loop,
                        // since reportAnswerPosition runs on every updateNSView.
                        if answerInfo != info {
                            answerInfo = info
                        }
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Persistent answer tooltip above the answer point (forward queries).
                if showsAnswerTooltip, let answer = answerInfo, !answer.name.isEmpty {
                    MapTooltipLabel(name: answer.name)
                        .position(
                            x: answer.position.x,
                            y: answer.position.y - answer.markerSize / 2 - 14
                        )
                }

                // Hover tooltip below the hovered point.
                if revealName, let hover = hoverInfo, !hover.name.isEmpty {
                    MapTooltipLabel(name: hover.name)
                        .position(
                            x: hover.position.x,
                            y: hover.position.y + hover.markerSize / 2 + 22
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: payload.pointID) { _, _ in
                hoverInfo = nil
                answerInfo = nil
                clickedPointID = nil
            }
            .onChange(of: revealName) { _, newValue in
                if !newValue {
                    hoverInfo = nil
                    answerInfo = nil
                    clickedPointID = nil
                }
            }

            ZStack {
                Color.clear
                // Forward query, before reveal: show the point's hint (reddish) in
                // the answer's spot. Reverse queries never show a hint.
                if !revealName, !payload.isReverse, payload.showHighlight, !payload.hint.isEmpty {
                    Text(payload.hint)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundStyle(Self.hintColor)
                }
                // Forward: show the name only after reveal. Reverse: the name IS
                // the prompt, so show it throughout.
                if (revealName && payload.showHighlight) || payload.isReverse {
                    Text(payload.pointName)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundStyle(answerTextColor)
                }
            }
            .frame(height: 40)
            .padding(.bottom, 12)
        }
    }

    static func span(forZoom zoom: Double) -> MKCoordinateSpan {
        let clamped = max(0.0, min(20.0, zoom))
        let latDelta = max(0.0001, 360.0 / pow(2.0, clamped))
        return MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: latDelta)
    }
}

private struct PointMapMKMapView: NSViewRepresentable {
    let payload: PointMapStudyPayload
    let revealName: Bool
    let reverseInteractive: Bool
    let onAnswerSelected: (Int64) -> Void
    let onHoverChange: (PointMapQueryView.HoverInfo?) -> Void
    let onAnswerPositionChange: (PointMapQueryView.HoverInfo?) -> Void

    // Forward queries show a persistent tooltip above the answer point once revealed.
    private var showAnswerTooltip: Bool {
        revealName && payload.showHighlight && !payload.isReverse
    }

    func makeNSView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .flat)
        mapView.delegate = context.coordinator
        mapView.showsCompass = false
        mapView.showsZoomControls = false
        mapView.showsScale = false
        mapView.showsPitchControl = false
        mapView.isPitchEnabled = false
        mapView.isRotateEnabled = false
        mapView.showsUserLocation = false

        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: payload.defaultCenterLat,
                longitude: payload.defaultCenterLng
            ),
            span: PointMapQueryView.span(forZoom: payload.defaultZoom)
        )
        mapView.setRegion(region, animated: false)
        context.coordinator.lastPointID = payload.pointID
        context.coordinator.mapView = mapView
        context.coordinator.onHoverChange = onHoverChange
        context.coordinator.onAnswerSelected = onAnswerSelected
        context.coordinator.onAnswerPositionChange = onAnswerPositionChange
        context.coordinator.answerPointID = payload.pointID
        context.coordinator.answerName = payload.pointName
        context.coordinator.showAnswerTooltip = showAnswerTooltip
        context.coordinator.normalDiameter = payload.pointSize.normalDiameter
        context.coordinator.highlightedDiameter = payload.pointSize.highlightedDiameter

        applyAnnotations(to: mapView, coordinator: context.coordinator)
        applyOverlays(to: mapView, coordinator: context.coordinator)
        context.coordinator.reportAnswerPosition()

        return mapView
    }

    func updateNSView(_ mapView: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.mapView = mapView
        coordinator.onHoverChange = onHoverChange
        coordinator.onAnswerSelected = onAnswerSelected
        coordinator.onAnswerPositionChange = onAnswerPositionChange
        coordinator.answerPointID = payload.pointID
        coordinator.answerName = payload.pointName
        coordinator.showAnswerTooltip = showAnswerTooltip
        coordinator.normalDiameter = payload.pointSize.normalDiameter
        coordinator.highlightedDiameter = payload.pointSize.highlightedDiameter

        if coordinator.lastPointID != payload.pointID {
            coordinator.lastPointID = payload.pointID
            let region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: payload.defaultCenterLat,
                    longitude: payload.defaultCenterLng
                ),
                span: PointMapQueryView.span(forZoom: payload.defaultZoom)
            )
            mapView.setRegion(region, animated: false)
        }

        applyAnnotations(to: mapView, coordinator: coordinator)
        applyOverlays(to: mapView, coordinator: coordinator)
        coordinator.reportAnswerPosition()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private var visiblePoints: [PointMapPoint] {
        // Reverse always shows every point so the user has candidates to click.
        if payload.showHighlight && !revealName && !payload.showAllPointsInQuestion && !payload.isReverse {
            return payload.points.filter { $0.id == payload.pointID }
        }
        return payload.points
    }

    private func applyAnnotations(to mapView: MKMapView, coordinator: Coordinator) {
        let visible = visiblePoints
        let visibleIDs = Set(visible.map { $0.id })

        let existing = mapView.annotations.compactMap { $0 as? PointMapAnnotation }
        var existingByID: [Int64: PointMapAnnotation] = [:]
        for annotation in existing {
            existingByID[annotation.pointID] = annotation
        }

        let toRemove = existing.filter { !visibleIDs.contains($0.pointID) }
        if !toRemove.isEmpty {
            mapView.removeAnnotations(toRemove)
        }

        for point in visible {
            // In reverse, never pre-highlight the answer — only after reveal.
            let isHighlighted = payload.showHighlight && point.id == payload.pointID && (!payload.isReverse || revealName)
            let coord = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
            if let annotation = existingByID[point.id] {
                if annotation.isHighlighted != isHighlighted
                    || annotation.showTooltip != revealName
                    || annotation.reverseInteractive != reverseInteractive
                    || annotation.name != point.name {
                    annotation.isHighlighted = isHighlighted
                    annotation.showTooltip = revealName
                    annotation.reverseInteractive = reverseInteractive
                    annotation.name = point.name
                    if let view = mapView.view(for: annotation) as? PointMapAnnotationView {
                        view.configure(with: annotation)
                    }
                }
                if annotation.coordinate.latitude != coord.latitude
                    || annotation.coordinate.longitude != coord.longitude {
                    annotation.coordinate = coord
                }
            } else {
                let annotation = PointMapAnnotation(
                    pointID: point.id,
                    coordinate: coord,
                    name: point.name,
                    isHighlighted: isHighlighted,
                    showTooltip: revealName,
                    reverseInteractive: reverseInteractive
                )
                mapView.addAnnotation(annotation)
            }
        }
    }

    private func applyOverlays(to mapView: MKMapView, coordinator: Coordinator) {
        let newSignature = payload.boundaries.map { $0.id }
        guard newSignature != coordinator.boundarySignature else { return }
        coordinator.boundarySignature = newSignature

        mapView.removeOverlays(mapView.overlays)
        for geo in payload.boundaries {
            for ring in geo.geometry.rings {
                guard let outer = ring.first, outer.count >= 3 else { continue }
                let coords = outer.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                let polygon = MKPolygon(coordinates: coords, count: coords.count)
                mapView.addOverlay(polygon)
            }
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var lastPointID: Int64 = .min
        var boundarySignature: [Int64] = []
        weak var mapView: MKMapView?
        var onHoverChange: ((PointMapQueryView.HoverInfo?) -> Void)?
        var onAnswerSelected: ((Int64) -> Void)?
        var onAnswerPositionChange: ((PointMapQueryView.HoverInfo?) -> Void)?
        var showAnswerTooltip = false
        var answerPointID: Int64 = .min
        var answerName: String = ""
        // Per-instance marker diameters, set from payload.pointSize in make/updateNSView.
        var normalDiameter: CGFloat = PointMapPointSize.medium.normalDiameter
        var highlightedDiameter: CGFloat = PointMapPointSize.medium.highlightedDiameter

        // Reports the answer point's current screen position so the SwiftUI overlay
        // can pin a persistent tooltip above it (forward queries, after reveal).
        // Reuses the same coordinate→view conversion as `reportHover`. The result
        // is delivered asynchronously because this is invoked during the SwiftUI
        // update cycle (make/updateNSView), and mutating @State synchronously there
        // triggers "Modifying state during view update".
        func reportAnswerPosition() {
            guard let mapView else { return }
            let info: PointMapQueryView.HoverInfo?
            if showAnswerTooltip,
               let annotation = mapView.annotations
                .compactMap({ $0 as? PointMapAnnotation })
                .first(where: { $0.pointID == answerPointID }) {
                let mapPoint = mapView.convert(annotation.coordinate, toPointTo: mapView)
                let positionY = mapView.isFlipped ? mapPoint.y : (mapView.bounds.height - mapPoint.y)
                info = PointMapQueryView.HoverInfo(
                    pointID: annotation.pointID,
                    name: answerName,
                    position: CGPoint(x: mapPoint.x, y: positionY),
                    markerSize: highlightedDiameter
                )
            } else {
                info = nil
            }
            DispatchQueue.main.async { [weak self] in
                self?.onAnswerPositionChange?(info)
            }
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            reportAnswerPosition()
        }

        func reportHover(annotation: PointMapAnnotation, isHovering: Bool) {
            guard let mapView = mapView else { return }
            if isHovering {
                let mapPoint = mapView.convert(annotation.coordinate, toPointTo: mapView)
                let positionY = mapView.isFlipped ? mapPoint.y : (mapView.bounds.height - mapPoint.y)
                let size: CGFloat = annotation.isHighlighted ? highlightedDiameter : normalDiameter
                onHoverChange?(PointMapQueryView.HoverInfo(
                    pointID: annotation.pointID,
                    name: annotation.name,
                    position: CGPoint(x: mapPoint.x, y: positionY),
                    markerSize: size
                ))
            } else {
                onHoverChange?(nil)
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let pma = annotation as? PointMapAnnotation else { return nil }
            let identifier = "PointMapAnnotation"
            let view: PointMapAnnotationView
            if let dequeued = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? PointMapAnnotationView {
                dequeued.annotation = pma
                view = dequeued
            } else {
                view = PointMapAnnotationView(annotation: pma, reuseIdentifier: identifier)
            }
            view.coordinator = self
            view.configure(with: pma)
            return view
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polygon = overlay as? MKPolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)
                renderer.strokeColor = .red
                renderer.lineWidth = 1.5
                renderer.fillColor = .clear
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

private final class PointMapAnnotation: NSObject, MKAnnotation {
    let pointID: Int64
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var name: String
    var isHighlighted: Bool
    var showTooltip: Bool
    var reverseInteractive: Bool

    init(pointID: Int64, coordinate: CLLocationCoordinate2D, name: String, isHighlighted: Bool, showTooltip: Bool, reverseInteractive: Bool) {
        self.pointID = pointID
        self.coordinate = coordinate
        self.name = name
        self.isHighlighted = isHighlighted
        self.showTooltip = showTooltip
        self.reverseInteractive = reverseInteractive
        super.init()
    }
}

private final class PointMapAnnotationView: MKAnnotationView {
    weak var coordinator: PointMapMKMapView.Coordinator?
    private let circleLayer = CALayer()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        wantsLayer = true
        let containerLayer = CALayer()
        containerLayer.addSublayer(circleLayer)
        layer = containerLayer
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with annotation: PointMapAnnotation) {
        // During a reverse question, a hovered point should look like the chosen
        // answer in a forward query (red).
        let showRed = annotation.isHighlighted || (annotation.reverseInteractive && isHovered)
        let highlightedDiameter = coordinator?.highlightedDiameter ?? PointMapPointSize.medium.highlightedDiameter
        let normalDiameter = coordinator?.normalDiameter ?? PointMapPointSize.medium.normalDiameter
        let size: CGFloat = showRed ? highlightedDiameter : normalDiameter
        frame = NSRect(x: 0, y: 0, width: size, height: size)
        layer?.frame = NSRect(x: 0, y: 0, width: size, height: size)
        circleLayer.frame = NSRect(x: 0, y: 0, width: size, height: size)
        circleLayer.cornerRadius = size / 2
        circleLayer.borderWidth = 1
        if showRed {
            circleLayer.backgroundColor = NSColor.red.cgColor
            circleLayer.borderColor = NSColor.white.cgColor
        } else {
            circleLayer.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.85).cgColor
            circleLayer.borderColor = NSColor.black.withAlphaComponent(0.3).cgColor
        }
        toolTip = nil
        centerOffset = .zero
        canShowCallout = false
    }

    override func mouseDown(with event: NSEvent) {
        if let annotation = annotation as? PointMapAnnotation, annotation.reverseInteractive {
            coordinator?.onAnswerSelected?(annotation.pointID)
            return
        }
        super.mouseDown(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
            trackingArea = nil
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard let pma = annotation as? PointMapAnnotation else { return }
        isHovered = true
        if pma.reverseInteractive {
            configure(with: pma)
            NSCursor.pointingHand.push()
        }
        coordinator?.reportHover(annotation: pma, isHovering: true)
    }

    override func mouseExited(with event: NSEvent) {
        guard let pma = annotation as? PointMapAnnotation else { return }
        if isHovered && pma.reverseInteractive {
            NSCursor.pop()
        }
        isHovered = false
        if pma.reverseInteractive {
            configure(with: pma)
        }
        coordinator?.reportHover(annotation: pma, isHovering: false)
    }
}
