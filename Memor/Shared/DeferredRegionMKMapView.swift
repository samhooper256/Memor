//
//  DeferredRegionMKMapView.swift
//  Memor
//
//  The study/query map wrappers create their MKMapView at frame .zero and set
//  the region before the first layout pass. Region-fitting against a 0x0
//  aspect ratio can wedge the camera (blank tiles behind live markers; the
//  Metal layer logs "ignoring invalid setDrawableSize 0x0"), and the wrappers
//  only re-issue the region on a query change, so the wedge never healed.
//  Remember any region applied while unsized and replay it once real bounds
//  arrive. Used directly by the PointMap query maps and as the superclass of
//  the BoundaryMap query map.
//

import MapKit

class DeferredRegionMKMapView: MKMapView {
    private var regionSetWhileZeroSize: MKCoordinateRegion?

    override func setRegion(_ region: MKCoordinateRegion, animated: Bool) {
        regionSetWhileZeroSize = (bounds.width <= 0 || bounds.height <= 0) ? region : nil
        super.setRegion(region, animated: animated)
    }

    override func layout() {
        super.layout()
        if let region = regionSetWhileZeroSize, bounds.width > 0, bounds.height > 0 {
            regionSetWhileZeroSize = nil
            super.setRegion(region, animated: false)
        }
    }
}
