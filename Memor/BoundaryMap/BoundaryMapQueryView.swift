//
//  BoundaryMapQueryView.swift
//  Memor
//
//  Map-based boundary-quiz query rendering. In a forward query the current
//  boundary is filled translucent purple with a purple border (it is the
//  prompt); other attached boundaries are stroke-only in their own border
//  color (red by default, per-boundary blue). In a reverse query
//  the boundary's name is the prompt and the user clicks the matching boundary
//  — hovered boundaries tint translucent purple with a pointer cursor until
//  the answer is revealed. After a forward query's answer is revealed,
//  hovering any boundary shows its name in a tooltip below the cursor.
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

    // Reverse queries: which boundary the user clicked (their guess), if any.
    @State private var clickedBoundaryID: Int64?
    // Revealed forward queries: the boundary under the cursor, for its name tooltip.
    @State private var hoverInfo: HoverInfo?

    struct HoverInfo: Equatable {
        let boundaryID: Int64
        let name: String
        /// Cursor position in the map's SwiftUI (top-left origin) coordinates.
        let position: CGPoint
    }

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

    // Boundary names on hover: forward queries, once the answer is revealed
    // (before that they would give the answer away).
    private var showsHoverNames: Bool { !payload.isReverse && revealName }

    // After a reverse query is revealed, color the prompt by whether the user
    // clicked the correct boundary: green if correct, red if wrong. Neutral if
    // no guess was made (e.g. revealed via the keyboard) or for forward
    // queries. Mirrors PointMapQueryView.answerTextColor.
    private var answerTextColor: Color {
        guard payload.isReverse, revealName, let clickedBoundaryID else { return .primary }
        return clickedBoundaryID == payload.boundaryID ? .green : .red
    }

    var body: some View {
        VStack(spacing: 12) {
            ZStack(alignment: .topLeading) {
                BoundaryMapMKMapView(
                    payload: payload,
                    revealName: revealName,
                    reverseInteractive: reverseInteractive,
                    showsHoverNames: showsHoverNames,
                    showFinder: showFinder,
                    onAnswerSelected: { clickedID in
                        clickedBoundaryID = clickedID
                        onAnswerSelected()
                    },
                    onHoverChange: { info in
                        if hoverInfo != info {
                            hoverInfo = info
                        }
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Hover tooltip below the cursor (same offset + styling as the
                // PointMap hover tooltip).
                if showsHoverNames, let hover = hoverInfo, !hover.name.isEmpty {
                    MapTooltipLabel(name: hover.name)
                        .position(x: hover.position.x, y: hover.position.y + 22)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            ZStack {
                Color.clear
                // Forward: show the name only after reveal. Reverse: the name IS
                // the prompt, so show it throughout.
                if (revealName && payload.showHighlight) || payload.isReverse {
                    Text(payload.boundaryName)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundStyle(answerTextColor)
                }
            }
            .frame(height: 40)
            .padding(.bottom, 12)
        }
        .onChange(of: payload.attachmentID) { _, _ in
            clickedBoundaryID = nil
            hoverInfo = nil
        }
        .onChange(of: revealName) { _, newValue in
            if !newValue {
                clickedBoundaryID = nil
                hoverInfo = nil
            }
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
    let showsHoverNames: Bool
    let showFinder: Bool
    // Called with the clicked boundary's id (the user's guess).
    let onAnswerSelected: (Int64) -> Void
    // Called from mouse events only (never synchronously from make/updateNSView).
    let onHoverChange: (BoundaryMapQueryView.HoverInfo?) -> Void

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
        coordinator.queryableBoundaryIDs = payload.queryableBoundaryIDs
        coordinator.onAnswerSelected = onAnswerSelected
        coordinator.showsHoverNames = showsHoverNames
        coordinator.onHoverChange = onHoverChange
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
        let signature = visibleGeometries.map { "\($0.id):\($0.color.rawValue)" }
            + [String(payload.boundaryID), payload.showHighlight ? "1" : "0", payload.isReverse ? "1" : "0", revealName ? "1" : "0"]
        guard signature != coordinator.overlaySignature else { return }
        coordinator.overlaySignature = signature

        mapView.removeOverlays(mapView.overlays)
        coordinator.appliedFillState.removeAll()
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
        var overlaySignature: [String] = []
        var geometries: [BoundaryGeometry] = []
        var queryableBoundaryIDs: Set<Int64> = []
        var hoveredBoundaryID: Int64?
        var onAnswerSelected: ((Int64) -> Void)?
        var showsHoverNames: Bool = false
        var onHoverChange: ((BoundaryMapQueryView.HoverInfo?) -> Void)?
        weak var mapView: MKMapView?
        weak var finderOverlay: BoundaryFinderOverlayView?
        /// Last APPLIED filled-ness per live renderer, so refreshOverlayFills
        /// can skip renderers whose state is unchanged. Both colors are a pure
        /// function of filled-ness plus the boundary's stored border color —
        /// and that color is part of the overlay signature, so it is fixed for
        /// a renderer's lifetime and this Bool stays the complete color state.
        /// Cleared on overlay rebuild (recycled allocations must not alias
        /// stale entries); repopulated at renderer creation.
        var appliedFillState: [ObjectIdentifier: Bool] = [:]

        // Whether a given boundary should be filled translucent purple right now.
        private func isFilled(boundaryID: Int64) -> Bool {
            let answerVisible = showHighlight && (!isReverse || revealName)
            if answerVisible && boundaryID == currentBoundaryID { return true }
            if reverseInteractive && boundaryID == hoveredBoundaryID { return true }
            return false
        }

        // The boundary's stored border color, used when the boundary is not
        // filled (i.e. it is not the prompt/hover highlight).
        private func strokeColor(for boundaryID: Int64) -> NSColor {
            (geometries.first { $0.id == boundaryID }?.color ?? .red).nsColor
        }

        func boundaryID(at coordinate: CLLocationCoordinate2D) -> Int64? {
            for geo in geometries where boundaryContains(coordinate: coordinate, geometry: geo.geometry) {
                // Boundaries with no enabled queries aren't valid reverse
                // answers — skip them (no hover tint/pointer; a click pans the
                // map), letting an overlapping queryable boundary still match.
                guard queryableBoundaryIDs.contains(geo.id) else { continue }
                return geo.id
            }
            return nil
        }

        /// Any visible boundary under the coordinate, for the name tooltip —
        /// unlike boundaryID(at:), boundaries without queries count too.
        func namedBoundary(at coordinate: CLLocationCoordinate2D) -> BoundaryGeometry? {
            geometries.first { boundaryContains(coordinate: coordinate, geometry: $0.geometry) }
        }

        /// Clears the name tooltip when the map moves under a still cursor.
        /// Deferred: the region callbacks can fire inside setRegion during
        /// make/updateNSView, where a SwiftUI @State write is not allowed.
        func clearHoverName() {
            guard let onHoverChange else { return }
            DispatchQueue.main.async { onHoverChange(nil) }
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
                let filled = isFilled(boundaryID: polygonBoundaryID)
                // Skip unchanged renderers ENTIRELY — the color setters alone
                // invalidate an MKOverlayPathRenderer (even set to an equal
                // value), which discards the composited overlay tiles and
                // makes the boundary visibly blank while MapKit repaints
                // asynchronously. updateNSView calls this on every SwiftUI
                // body pass, so an unguarded pass landing after the first
                // paint showed as the boundary "flashing" in Study mode.
                if appliedFillState[ObjectIdentifier(renderer)] == filled { continue }
                appliedFillState[ObjectIdentifier(renderer)] = filled
                renderer.fillColor = filled
                    ? NSColor.systemPurple.withAlphaComponent(0.35)
                    : .clear
                renderer.strokeColor = filled ? .systemPurple : strokeColor(for: polygonBoundaryID)
                renderer.setNeedsDisplay()
            }
        }

        // Keep the gold finder glued to the boundary as the map pans/zooms.
        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            finderOverlay?.needsDisplay = true
            if showsHoverNames {
                clearHoverName()
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            finderOverlay?.needsDisplay = true
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            self.mapView = mapView
            if let polygon = overlay as? MKPolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)
                let polygonBoundaryID = Int64(polygon.title ?? "") ?? 0
                let filled = isFilled(boundaryID: polygonBoundaryID)
                renderer.strokeColor = filled ? .systemPurple : strokeColor(for: polygonBoundaryID)
                renderer.lineWidth = 1.5
                renderer.fillColor = filled
                    ? NSColor.systemPurple.withAlphaComponent(0.35)
                    : .clear
                appliedFillState[ObjectIdentifier(renderer)] = filled
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

// MKMapView subclass that, only during a reverse question, reports which
// boundary the mouse is over (for hover tinting + pointer cursor) and treats a
// click on a boundary as the answer selection. Clicks on empty map still pan.
// Inherits DeferredRegionMKMapView's zero-size-mount camera repair (the region
// is set in makeNSView before the first layout pass, like the PointMap maps).
private final class BoundaryMapInteractiveMapView: DeferredRegionMKMapView {
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

    // Revealed forward queries: report the boundary under the cursor (any
    // visible one, with or without queries) for the name tooltip.
    private func reportHoverName(at locationInWindow: NSPoint) {
        guard let coordinator, coordinator.showsHoverNames else { return }
        let point = convert(locationInWindow, from: nil)
        guard let boundary = coordinator.namedBoundary(at: convert(point, toCoordinateFrom: self)) else {
            coordinator.onHoverChange?(nil)
            return
        }
        // SwiftUI's overlay space has a top-left origin.
        let position = CGPoint(x: point.x, y: isFlipped ? point.y : bounds.height - point.y)
        coordinator.onHoverChange?(.init(boundaryID: boundary.id, name: boundary.name, position: position))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        reportHoverName(at: event.locationInWindow)
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
        coordinator?.onHoverChange?(nil)
        coordinator?.updateHoveredBoundary(nil)
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        if let coordinator, coordinator.reverseInteractive,
           let clickedID = boundaryID(at: event.locationInWindow) {
            coordinator.onAnswerSelected?(clickedID)
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
