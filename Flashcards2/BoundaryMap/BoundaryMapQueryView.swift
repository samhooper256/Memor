//
//  BoundaryMapQueryView.swift
//  Memor
//
//  Map-based boundary-quiz query rendering. In a forward query the current
//  boundary is filled translucent red (it is the prompt); other attached
//  boundaries are stroke-only. In a reverse query the boundary's name is the
//  prompt and the user clicks the matching boundary — hovered boundaries tint
//  translucent red with a pointer cursor until the answer is revealed.
//

import AppKit
import CoreLocation
import MapKit
import SwiftUI

struct BoundaryMapQueryView: View {
    let payload: BoundaryMapStudyPayload
    var revealName: Bool
    var showFinder: Bool
    var onAnswerSelected: () -> Void

    init(
        payload: BoundaryMapStudyPayload,
        revealName: Bool = false,
        showFinder: Bool = false,
        onAnswerSelected: @escaping () -> Void = {}
    ) {
        self.payload = payload
        self.revealName = revealName
        self.showFinder = showFinder
        self.onAnswerSelected = onAnswerSelected
    }

    private var reverseInteractive: Bool { payload.isReverse && !revealName }

    var body: some View {
        VStack(spacing: 12) {
            BoundaryMapMKMapView(
                payload: payload,
                revealName: revealName,
                reverseInteractive: reverseInteractive,
                showFinder: showFinder,
                onAnswerSelected: onAnswerSelected
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            ZStack {
                Color.clear
                // Forward: show the name only after reveal. Reverse: the name IS
                // the prompt, so show it throughout.
                if (revealName && payload.showHighlight) || payload.isReverse {
                    Text(payload.boundaryName)
                        .font(.title2)
                        .fontWeight(.semibold)
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

private struct BoundaryMapMKMapView: NSViewRepresentable {
    let payload: BoundaryMapStudyPayload
    let revealName: Bool
    let reverseInteractive: Bool
    let showFinder: Bool
    let onAnswerSelected: () -> Void

    func makeNSView(context: Context) -> MKMapView {
        let mapView = BoundaryMapInteractiveMapView()
        mapView.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .flat)
        mapView.delegate = context.coordinator
        mapView.showsCompass = false
        mapView.showsZoomControls = false
        mapView.showsScale = false
        mapView.showsPitchControl = false
        mapView.isPitchEnabled = false
        mapView.isRotateEnabled = false
        mapView.showsUserLocation = false
        mapView.coordinator = context.coordinator

        let finderOverlay = BoundaryFinderOverlayView(frame: mapView.bounds)
        finderOverlay.autoresizingMask = [.width, .height]
        finderOverlay.mapView = mapView
        mapView.addSubview(finderOverlay, positioned: .above, relativeTo: nil)
        context.coordinator.finderOverlay = finderOverlay

        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: payload.defaultCenterLat,
                longitude: payload.defaultCenterLng
            ),
            span: BoundaryMapQueryView.span(forZoom: payload.defaultZoom)
        )
        mapView.setRegion(region, animated: false)
        context.coordinator.lastAttachmentID = payload.attachmentID
        applyState(to: mapView, coordinator: context.coordinator)

        applyOverlays(to: mapView, coordinator: context.coordinator)
        return mapView
    }

    func updateNSView(_ mapView: MKMapView, context: Context) {
        let coordinator = context.coordinator
        applyState(to: mapView, coordinator: coordinator)

        if coordinator.lastAttachmentID != payload.attachmentID {
            coordinator.lastAttachmentID = payload.attachmentID
            let region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: payload.defaultCenterLat,
                    longitude: payload.defaultCenterLng
                ),
                span: BoundaryMapQueryView.span(forZoom: payload.defaultZoom)
            )
            mapView.setRegion(region, animated: false)
        }

        applyOverlays(to: mapView, coordinator: coordinator)
        coordinator.refreshOverlayFills()
    }

    private func applyState(to mapView: MKMapView, coordinator: Coordinator) {
        coordinator.currentBoundaryID = payload.boundaryID
        coordinator.showHighlight = payload.showHighlight
        coordinator.isReverse = payload.isReverse
        coordinator.revealName = revealName
        coordinator.reverseInteractive = reverseInteractive
        coordinator.geometries = payload.geometries
        coordinator.onAnswerSelected = onAnswerSelected
        if !reverseInteractive {
            coordinator.hoveredBoundaryID = nil
        }

        // The finder is forward-only (showing it during a reverse "click the
        // boundary" question would reveal the answer).
        let finderActive = showFinder && !payload.isReverse
        if let overlay = coordinator.finderOverlay {
            overlay.isActive = finderActive
            let currentGeometry = payload.geometries.first { $0.id == payload.boundaryID }
            overlay.setBoundary(currentGeometry?.geometry)
            overlay.needsDisplay = true
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private var visibleGeometries: [BoundaryGeometry] {
        // Reverse always shows every boundary so the user has candidates to click.
        if payload.showHighlight && !revealName && !payload.showAllBoundariesInQuestion && !payload.isReverse {
            return payload.geometries.filter { $0.id == payload.boundaryID }
        }
        return payload.geometries
    }

    private func applyOverlays(to mapView: MKMapView, coordinator: Coordinator) {
        let signature = visibleGeometries.map { $0.id }
            + [payload.boundaryID, payload.showHighlight ? 1 : 0, payload.isReverse ? 1 : 0, revealName ? 1 : 0]
        guard signature != coordinator.overlaySignature else { return }
        coordinator.overlaySignature = signature

        mapView.removeOverlays(mapView.overlays)
        for geo in visibleGeometries {
            for ring in geo.geometry.rings {
                guard let outer = ring.first, outer.count >= 3 else { continue }
                let coords = outer.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                let polygon = MKPolygon(coordinates: coords, count: coords.count)
                polygon.title = String(geo.id)
                mapView.addOverlay(polygon)
            }
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var lastAttachmentID: Int64 = .min
        var currentBoundaryID: Int64 = 0
        var showHighlight: Bool = true
        var isReverse: Bool = false
        var revealName: Bool = false
        var reverseInteractive: Bool = false
        var overlaySignature: [Int64] = []
        var geometries: [BoundaryGeometry] = []
        var hoveredBoundaryID: Int64?
        var onAnswerSelected: (() -> Void)?
        weak var mapView: MKMapView?
        weak var finderOverlay: BoundaryFinderOverlayView?

        // Whether a given boundary should be filled translucent red right now.
        private func isFilled(boundaryID: Int64) -> Bool {
            let answerVisible = showHighlight && (!isReverse || revealName)
            if answerVisible && boundaryID == currentBoundaryID { return true }
            if reverseInteractive && boundaryID == hoveredBoundaryID { return true }
            return false
        }

        func boundaryID(at coordinate: CLLocationCoordinate2D) -> Int64? {
            for geo in geometries where boundaryContains(coordinate: coordinate, geometry: geo.geometry) {
                return geo.id
            }
            return nil
        }

        func updateHoveredBoundary(_ boundaryID: Int64?) {
            guard hoveredBoundaryID != boundaryID else { return }
            hoveredBoundaryID = boundaryID
            refreshOverlayFills()
        }

        func refreshOverlayFills() {
            guard let mapView else { return }
            for overlay in mapView.overlays {
                guard let polygon = overlay as? MKPolygon,
                      let renderer = mapView.renderer(for: overlay) as? MKPolygonRenderer else { continue }
                let polygonBoundaryID = Int64(polygon.title ?? "") ?? 0
                renderer.fillColor = isFilled(boundaryID: polygonBoundaryID)
                    ? NSColor.systemRed.withAlphaComponent(0.35)
                    : .clear
                renderer.setNeedsDisplay()
            }
        }

        // Keep the gold finder glued to the boundary as the map pans/zooms.
        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            finderOverlay?.needsDisplay = true
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            finderOverlay?.needsDisplay = true
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            self.mapView = mapView
            if let polygon = overlay as? MKPolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)
                let polygonBoundaryID = Int64(polygon.title ?? "") ?? 0
                renderer.strokeColor = .red
                renderer.lineWidth = 1.5
                renderer.fillColor = isFilled(boundaryID: polygonBoundaryID)
                    ? NSColor.systemRed.withAlphaComponent(0.35)
                    : .clear
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

// MKMapView subclass that, only during a reverse question, reports which
// boundary the mouse is over (for hover tinting + pointer cursor) and treats a
// click on a boundary as the answer selection. Clicks on empty map still pan.
private final class BoundaryMapInteractiveMapView: MKMapView {
    weak var coordinator: BoundaryMapMKMapView.Coordinator?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
            trackingArea = nil
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    private func boundaryID(at locationInWindow: NSPoint) -> Int64? {
        guard let coordinator, coordinator.reverseInteractive else { return nil }
        let point = convert(locationInWindow, from: nil)
        let coordinate = convert(point, toCoordinateFrom: self)
        return coordinator.boundaryID(at: coordinate)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard let coordinator, coordinator.reverseInteractive else { return }
        let hovered = boundaryID(at: event.locationInWindow)
        coordinator.updateHoveredBoundary(hovered)
        if hovered != nil {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        coordinator?.updateHoveredBoundary(nil)
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        if let coordinator, coordinator.reverseInteractive,
           boundaryID(at: event.locationInWindow) != nil {
            coordinator.onAnswerSelected?()
            return
        }
        super.mouseDown(with: event)
    }
}

// Click-through overlay that draws the gold "finder" for the current boundary:
// a gold frame around the boundary while it is visible, or a gold arrow at the
// map edge pointing toward it while it is off-screen. Corners + center are
// precomputed in geographic space when the boundary changes; only those ~5
// points are projected on each pan/zoom, so redraws stay cheap.
final class BoundaryFinderOverlayView: NSView {
    weak var mapView: MKMapView?
    var isActive = false

    private var corners: [CLLocationCoordinate2D] = []
    private var center: CLLocationCoordinate2D?

    private let gold = NSColor(srgbRed: 0.95, green: 0.78, blue: 0.20, alpha: 1)
    private let framePadding: CGFloat = 14
    private let minFrameSize: CGFloat = 44
    private let edgeInset: CGFloat = 28
    private let arrowSize: CGFloat = 18

    // Overlay is purely decorative — let all mouse events fall through to the map.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setBoundary(_ geometry: ParsedMultiPolygon?) {
        guard let geometry else {
            corners = []
            center = nil
            return
        }
        var minLat = Double.greatestFiniteMagnitude
        var maxLat = -Double.greatestFiniteMagnitude
        var minLng = Double.greatestFiniteMagnitude
        var maxLng = -Double.greatestFiniteMagnitude
        for polygon in geometry.rings {
            guard let outer = polygon.first else { continue }
            for coord in outer {
                minLat = min(minLat, coord.latitude)
                maxLat = max(maxLat, coord.latitude)
                minLng = min(minLng, coord.longitude)
                maxLng = max(maxLng, coord.longitude)
            }
        }
        guard minLat <= maxLat, minLng <= maxLng else {
            corners = []
            center = nil
            return
        }
        corners = [
            CLLocationCoordinate2D(latitude: minLat, longitude: minLng),
            CLLocationCoordinate2D(latitude: minLat, longitude: maxLng),
            CLLocationCoordinate2D(latitude: maxLat, longitude: minLng),
            CLLocationCoordinate2D(latitude: maxLat, longitude: maxLng),
        ]
        center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLng + maxLng) / 2
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isActive, let mapView, let center, !corners.isEmpty else { return }

        let cornerPoints = corners.map { mapView.convert($0, toPointTo: self) }
        let centerPoint = mapView.convert(center, toPointTo: self)

        if bounds.contains(centerPoint) {
            drawFrame(around: cornerPoints, center: centerPoint)
        } else {
            drawEdgeArrow(toward: centerPoint)
        }
    }

    private func drawFrame(around cornerPoints: [NSPoint], center centerPoint: NSPoint) {
        let minX = cornerPoints.map(\.x).min() ?? centerPoint.x
        let maxX = cornerPoints.map(\.x).max() ?? centerPoint.x
        let minY = cornerPoints.map(\.y).min() ?? centerPoint.y
        let maxY = cornerPoints.map(\.y).max() ?? centerPoint.y

        var rect = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            .insetBy(dx: -framePadding, dy: -framePadding)

        // Guarantee a clearly visible box even for tiny boundaries.
        if rect.width < minFrameSize {
            rect.origin.x = centerPoint.x - minFrameSize / 2
            rect.size.width = minFrameSize
        }
        if rect.height < minFrameSize {
            rect.origin.y = centerPoint.y - minFrameSize / 2
            rect.size.height = minFrameSize
        }

        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        path.lineWidth = 3
        gold.setStroke()
        path.stroke()
    }

    private func drawEdgeArrow(toward target: NSPoint) {
        let origin = NSPoint(x: bounds.midX, y: bounds.midY)
        var dx = target.x - origin.x
        var dy = target.y - origin.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0.0001 else { return }
        dx /= length
        dy /= length

        // Exit point of the ray on the inset bounds.
        let inset = bounds.insetBy(dx: edgeInset, dy: edgeInset)
        let tx = dx > 0 ? (inset.maxX - origin.x) / dx : (dx < 0 ? (inset.minX - origin.x) / dx : .greatestFiniteMagnitude)
        let ty = dy > 0 ? (inset.maxY - origin.y) / dy : (dy < 0 ? (inset.minY - origin.y) / dy : .greatestFiniteMagnitude)
        let t = min(tx, ty)
        let tip = NSPoint(x: origin.x + dx * t, y: origin.y + dy * t)

        // Triangle pointing along (dx, dy).
        let perp = (x: -dy, y: dx)
        let backCenter = NSPoint(x: tip.x - dx * arrowSize, y: tip.y - dy * arrowSize)
        let half = arrowSize * 0.6
        let b1 = NSPoint(x: backCenter.x + perp.x * half, y: backCenter.y + perp.y * half)
        let b2 = NSPoint(x: backCenter.x - perp.x * half, y: backCenter.y - perp.y * half)

        let path = NSBezierPath()
        path.move(to: tip)
        path.line(to: b1)
        path.line(to: b2)
        path.close()
        gold.setFill()
        path.fill()
    }
}
