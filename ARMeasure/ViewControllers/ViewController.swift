/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Main view controller for the AR experience.
*/

import ARKit
import Foundation
import SceneKit
import UIKit
import Photos
import SwiftyJSON



class ViewController: UIViewController, UIPopoverPresentationControllerDelegate, VirtualObjectSelectionViewControllerDelegate {
	
    // MARK: - Main Setup & View Controller methods
    override func viewDidLoad() {
        super.viewDidLoad()
        session = sceneView.session
        Setting.registerDefaults()
        setupScene()
        setupDebug()
        setupUIControls()
		setupFocusSquare()
		updateSettings()
        setupShowAlbumButton()
//        resetVirtualObject()
        
        measure.delegate = self
        realmManager.delegate = self
        disableAreaCalculation()
    }

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		
		// Prevent the screen from being dimmed after a while.
		UIApplication.shared.isIdleTimerDisabled = true
		
		// Start the ARSession.
		restartPlaneDetection()
	}
	
	override func viewWillDisappear(_ animated: Bool) {
		super.viewWillDisappear(animated)
		session.pause()
	}
    
    // MARK: ARMeasure / Measure singlton
    var measure = Measure.sharedInstance
    
    // MARK: Realm
    var realmManager = RealmManager.sharedInstance
    
    // MARK: "Get Area"
    @IBOutlet weak var getAreaButton: UIButton!
	
    // MARK: - ARKit / ARSCNView
//    let session = ARSession()
    var session: ARSession!
	var sessionConfig = ARWorldTrackingConfiguration()
	var use3DOFTracking = false {
		didSet {
			if use3DOFTracking {
				sessionConfig = ARWorldTrackingConfiguration()
			}
			sessionConfig.isLightEstimationEnabled = UserDefaults.standard.bool(for: .ambientLightEstimation)
			session.run(sessionConfig)
		}
	}
	var use3DOFTrackingFallback = false
    @IBOutlet var sceneView: ARSCNView!
    
	var screenCenter: CGPoint?
    
    func setupScene() {
        // set up sceneView
        sceneView.delegate = self
        sceneView.session = session
		sceneView.antialiasingMode = .multisampling4X
        
		sceneView.automaticallyUpdatesLighting = false
		
        
		sceneView.preferredFramesPerSecond = 60
		sceneView.contentScaleFactor = 1.3
        sceneView.showsStatistics = true
		
		enableEnvironmentMapWithIntensity(25.0)
		
		DispatchQueue.main.async {
			self.screenCenter = self.sceneView.bounds.mid
		}
		
		if let camera = sceneView.pointOfView?.camera {
			camera.wantsHDR = true
			camera.wantsExposureAdaptation = true
			camera.exposureOffset = -1
			camera.minimumExposure = -1
		}
    }
	
	func enableEnvironmentMapWithIntensity(_ intensity: CGFloat) {
		if sceneView.scene.lightingEnvironment.contents == nil {
			if let environmentMap = UIImage(named: "Models.scnassets/sharedImages/environment_blur.exr") {
				sceneView.scene.lightingEnvironment.contents = environmentMap
			}
		}
		sceneView.scene.lightingEnvironment.intensity = intensity
	}
	
    
	
	var trackingFallbackTimer: Timer?

	func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        textManager.showTrackingQualityInfo(for: camera.trackingState, autoHide: !self.showDebugVisuals)

        switch camera.trackingState {
        case .notAvailable:
            textManager.escalateFeedback(for: camera.trackingState, inSeconds: 5.0)
        case .limited:
            if use3DOFTrackingFallback {
                // After 10 seconds of limited quality, fall back to 3DOF mode.
                trackingFallbackTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false, block: { _ in
                    self.use3DOFTracking = true
                    self.trackingFallbackTimer?.invalidate()
                    self.trackingFallbackTimer = nil
                })
            } else {
                textManager.escalateFeedback(for: camera.trackingState, inSeconds: 10.0)
            }
        case .normal:
            textManager.cancelScheduledMessage(forType: .trackingStateEscalation)
            if use3DOFTrackingFallback && trackingFallbackTimer != nil {
                trackingFallbackTimer!.invalidate()
                trackingFallbackTimer = nil
            }
        }
	}
	
    func session(_ session: ARSession, didFailWithError error: Error) {

        guard let arError = error as? ARError else { return }

        let nsError = error as NSError
		var sessionErrorMsg = "\(nsError.localizedDescription) \(nsError.localizedFailureReason ?? "")"
		if let recoveryOptions = nsError.localizedRecoveryOptions {
			for option in recoveryOptions {
				sessionErrorMsg.append("\(option).")
			}
		}

        let isRecoverable = (arError.code == .worldTrackingFailed)
		if isRecoverable {
			sessionErrorMsg += "\nYou can try resetting the session or quit the application."
		} else {
			sessionErrorMsg += "\nThis is an unrecoverable error that requires to quit the application."
		}
		
		displayErrorMessage(title: "We're sorry!", message: sessionErrorMsg, allowRestart: isRecoverable)
	}
	
	func sessionWasInterrupted(_ session: ARSession) {
		textManager.blurBackground()
		textManager.showAlert(title: "Session Interrupted", message: "The session will be reset after the interruption has ended.")
	}
    
    func resetARSession() {
        textManager.unblurBackground()
        session.run(sessionConfig, options: [.resetTracking, .removeExistingAnchors])
        restartExperience(self)
        textManager.showMessage("RESETTING SESSION")
    }
		
	func sessionInterruptionEnded(_ session: ARSession) {
		resetARSession()
	}
	
    // MARK: - Ambient Light Estimation
	
	func toggleAmbientLightEstimation(_ enabled: Bool) {
		
        if enabled {
			if !sessionConfig.isLightEstimationEnabled {
				// turn on light estimation
				sessionConfig.isLightEstimationEnabled = true
				session.run(sessionConfig)
			}
        } else {
			if sessionConfig.isLightEstimationEnabled {
				// turn off light estimation
				sessionConfig.isLightEstimationEnabled = false
				session.run(sessionConfig)
			}
        }
    }

    // MARK: - Gesture Recognizers
	
	var currentGesture: Gesture?
	
    
    /**
     The beginning of each user touch.
         - If the measure has closed measure, delete all nodes and restart.
     */
	override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if measure.isClosed {
            measure.reset()
            plane = nil
            switch measureMode {
            case .horizontal:
                restartPlaneDetection()
            default:
                return
            }
        }
        
        guard !measure.isEmpty, let touch = touches.first else { return }
        
        addMeasureNode(touch)
        
//        guard let object = virtualObject else {
//            return
//        }
//
//        if currentGesture == nil {
//            currentGesture = Gesture.startGestureFromTouches(touches, self.sceneView, object)
//        } else {
//            currentGesture = currentGesture!.updateGestureFromTouches(touches, .touchBegan)
//        }
//
//        displayVirtualObjectTransform()
	}
	
	override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !measure.isEmpty, let touch = touches.first else { return }
        undo()
        addMeasureNode(touch)
//        if virtualObject == nil {
//            return
//        }
//        currentGesture = currentGesture?.updateGestureFromTouches(touches, .touchMoved)
//        displayVirtualObjectTransform()
	}
	
    /**
     
     */
	override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        if !measure.isEmpty {
            undo()
        }
        /** Hit-test can have several options:
         - .existingPlane
         - .estimatedHorizontalPlane
         - .featurePoint
         
         */
        
        if measure.isEmpty {
            Logger.log("Initial touch: \n\(touch.location(in: sceneView))", event: .debug)
        }
        
        /// If user touches the initial measure node then get area and exit
        if measure.isClosable, let _ = hitMeasureNode(touch: touch) {
            measure.getArea()
            return
        }
        
        addMeasureNode(touch)
	}
    
    /**
     Test if a measure node was hit. If found, the measure will close the last vertex and
     calculate its area. The new hit to measure will erase all the existing ones.
     */
    private func hitMeasureNode(touch: UITouch) -> MeasureNode? {
        let touchImageCoordinate = touch.location(in: sceneView)
//        Logger.log("touchImageCoordinate: \(touchImageCoordinate)", event: .debug)
        
//        let i = sceneView.projectPoint(measure.measureNodesAsList.first!.position)
//        Logger.log("initialMeasureNodeImageCoordinate: \(i)", event: .debug)
//
        let initialMeasureNodeViewCoordinate = sceneView.projectPoint(measure.initialMeasureNode!.position).cgpoint()
//        Logger.log("initialMeasureNodeImageCoordinate: \(initialMeasureNodeImageCoordinate)", event: .debug)
        
        let distance = touchImageCoordinate.distanceTo(initialMeasureNodeViewCoordinate)
//        Logger.log("distance: \(distance)", event: .debug)
        if distance < 20 {
            return measure.measureNodesAsList.first
        } else {
            return nil
        }
        
    }
	
    private func addMeasureNode(_ touch: UITouch) {
        // Get objects by hit-test with a corresponding types
        var result: [ARHitTestResult]
        switch measureMode {
        case .normal:
            result = sceneView.hitTest(touch.location(in: sceneView), types: [.featurePoint])
        case .horizontal:
            result = sceneView.hitTest(touch.location(in: sceneView), types: [.existingPlane])
        }
        
        // Convert touch coordinate into world coordinate
        guard let hitResult:ARHitTestResult = result.first else { return }
        let hitTransform = SCNMatrix4(hitResult.worldTransform)
        let hitVector = SCNVector3Make(hitTransform.m41, hitTransform.m42, hitTransform.m43)
        
        switch measureMode {
        case .horizontal:
            if measure.isEmpty {
                measure.addMeasureNode(newVector: hitVector)
            } else {
                measure.addMeasureNode(newVector:
                    SCNVector3Make(
                        hitVector.x,
                        measure.initialMeasureNode!.position.y,
                        hitVector.z
                ))
            }
        default:
            measure.addMeasureNode(newVector: hitVector)
        }
        
        
        if plane == nil {
            switch measureMode {
            case .horizontal:
                if let planeAnchor = hitResult.anchor as? ARPlaneAnchor,
                    let plane = planes[planeAnchor] {
                    self.planeAnchor = planeAnchor
                    self.plane = plane
                }
            default:
                return
            }
        } else {
            
            Logger.log("initial.y: \(measure.initialMeasureNode!.position.y)\nnode:\(hitVector.y)\nEQUAL:\(measure.initialMeasureNode!.position.y  == hitVector.y) ", event: .debug)
        }
        
    }
	override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
		if virtualObject == nil {
			return
		}
		currentGesture = currentGesture?.updateGestureFromTouches(touches, .touchCancelled)
	}
	
	// MARK: - Virtual Object Manipulation
	
	func displayVirtualObjectTransform() {
		
		guard let object = virtualObject, let cameraTransform = session.currentFrame?.camera.transform else {
			return
		}
		
		// Output the current translation, rotation & scale of the virtual object as text.
		
		let cameraPos = SCNVector3.positionFromTransform(cameraTransform)
		let vectorToCamera = cameraPos - object.position
		
		let distanceToUser = vectorToCamera.length()
		
		var angleDegrees = Int(((object.eulerAngles.y) * 180) / Float.pi) % 360
		if angleDegrees < 0 {
			angleDegrees += 360
		}
		
		let distance = String(format: "%.2f", distanceToUser)
		let scale = String(format: "%.2f", object.scale.x)
		textManager.showDebugMessage("Distance: \(distance) m\nRotation: \(angleDegrees)°\nScale: \(scale)x")
	}
	
	func moveVirtualObjectToPosition(_ pos: SCNVector3?, _ instantly: Bool, _ filterPosition: Bool) {
		
		guard let newPosition = pos else {
			textManager.showMessage("CANNOT PLACE OBJECT\nTry moving left or right.")
			// Reset the content selection in the menu only if the content has not yet been initially placed.
			if virtualObject == nil {
				resetVirtualObject()
			}
			return
		}
		
		if instantly {
			setNewVirtualObjectPosition(newPosition)
		} else {
			updateVirtualObjectPosition(newPosition, filterPosition)
		}
	}
	
	var dragOnInfinitePlanesEnabled = false
	
	func worldPositionFromScreenPosition(_ position: CGPoint,
	                                     objectPos: SCNVector3?,
	                                     infinitePlane: Bool = false) -> (position: SCNVector3?, planeAnchor: ARPlaneAnchor?, hitAPlane: Bool) {
		
		// -------------------------------------------------------------------------------
		// 1. Always do a hit test against exisiting plane anchors first.
		//    (If any such anchors exist & only within their extents.)
		
		let planeHitTestResults = sceneView.hitTest(position, types: .existingPlaneUsingExtent)
		if let result = planeHitTestResults.first {
			
			let planeHitTestPosition = SCNVector3.positionFromTransform(result.worldTransform)
			let planeAnchor = result.anchor
			
			// Return immediately - this is the best possible outcome.
			return (planeHitTestPosition, planeAnchor as? ARPlaneAnchor, true)
		}
		
		// -------------------------------------------------------------------------------
		// 2. Collect more information about the environment by hit testing against
		//    the feature point cloud, but do not return the result yet.
		
		var featureHitTestPosition: SCNVector3?
		var highQualityFeatureHitTestResult = false
		
		let highQualityfeatureHitTestResults = sceneView.hitTestWithFeatures(position, coneOpeningAngleInDegrees: 18, minDistance: 0.2, maxDistance: 2.0)
		
		if !highQualityfeatureHitTestResults.isEmpty {
			let result = highQualityfeatureHitTestResults[0]
			featureHitTestPosition = result.position
			highQualityFeatureHitTestResult = true
		}
		
		// -------------------------------------------------------------------------------
		// 3. If desired or necessary (no good feature hit test result): Hit test
		//    against an infinite, horizontal plane (ignoring the real world).
		
		if (infinitePlane && dragOnInfinitePlanesEnabled) || !highQualityFeatureHitTestResult {
			
			let pointOnPlane = objectPos ?? SCNVector3Zero
			
			let pointOnInfinitePlane = sceneView.hitTestWithInfiniteHorizontalPlane(position, pointOnPlane)
			if pointOnInfinitePlane != nil {
				return (pointOnInfinitePlane, nil, true)
			}
		}
		
		// -------------------------------------------------------------------------------
		// 4. If available, return the result of the hit test against high quality
		//    features if the hit tests against infinite planes were skipped or no
		//    infinite plane was hit.
		
		if highQualityFeatureHitTestResult {
			return (featureHitTestPosition, nil, false)
		}
		
		// -------------------------------------------------------------------------------
		// 5. As a last resort, perform a second, unfiltered hit test against features.
		//    If there are no features in the scene, the result returned here will be nil.
		
		let unfilteredFeatureHitTestResults = sceneView.hitTestWithFeatures(position)
		if !unfilteredFeatureHitTestResults.isEmpty {
			let result = unfilteredFeatureHitTestResults[0]
			return (result.position, nil, false)
		}
		
		return (nil, nil, false)
	}
	
	// Use average of recent virtual object distances to avoid rapid changes in object scale.
	var recentVirtualObjectDistances = [CGFloat]()
	
    func setNewVirtualObjectPosition(_ pos: SCNVector3) {
	
		guard let object = virtualObject, let cameraTransform = session.currentFrame?.camera.transform else {
			return
		}
		
		recentVirtualObjectDistances.removeAll()
		
		let cameraWorldPos = SCNVector3.positionFromTransform(cameraTransform)
		var cameraToPosition = pos - cameraWorldPos
		
		// Limit the distance of the object from the camera to a maximum of 10 meters.
		cameraToPosition.setMaximumLength(10)

		object.position = cameraWorldPos + cameraToPosition
		
		if object.parent == nil {
			sceneView.scene.rootNode.addChildNode(object)
		}
    }

	func resetVirtualObject() {
		virtualObject?.unloadModel()
		virtualObject?.removeFromParentNode()
		virtualObject = nil
		
		addObjectButton.setImage(#imageLiteral(resourceName: "add"), for: [])
		addObjectButton.setImage(#imageLiteral(resourceName: "addPressed"), for: [.highlighted])
		
		// Reset selected object id for row highlighting in object selection view controller.
		UserDefaults.standard.set(-1, for: .selectedObjectID)
	}
	
	func updateVirtualObjectPosition(_ pos: SCNVector3, _ filterPosition: Bool) {
		guard let object = virtualObject else {
			return
		}
		
		guard let cameraTransform = session.currentFrame?.camera.transform else {
			return
		}
		
		let cameraWorldPos = SCNVector3.positionFromTransform(cameraTransform)
		var cameraToPosition = pos - cameraWorldPos
		
		// Limit the distance of the object from the camera to a maximum of 10 meters.
		cameraToPosition.setMaximumLength(10)
		
		// Compute the average distance of the object from the camera over the last ten
		// updates. If filterPosition is true, compute a new position for the object
		// with this average. Notice that the distance is applied to the vector from
		// the camera to the content, so it only affects the percieved distance of the
		// object - the averaging does _not_ make the content "lag".
		let hitTestResultDistance = CGFloat(cameraToPosition.length())

		recentVirtualObjectDistances.append(hitTestResultDistance)
		recentVirtualObjectDistances.keepLast(10)
		
		if filterPosition {
			let averageDistance = recentVirtualObjectDistances.average!
			
			cameraToPosition.setLength(Float(averageDistance))
			let averagedDistancePos = cameraWorldPos + cameraToPosition

			object.position = averagedDistancePos
		} else {
			object.position = cameraWorldPos + cameraToPosition
		}
    }
	
	func checkIfObjectShouldMoveOntoPlane(anchor: ARPlaneAnchor) {
		guard let object = virtualObject, let planeAnchorNode = sceneView.node(for: anchor) else {
			return
		}
		
		// Get the object's position in the plane's coordinate system.
		let objectPos = planeAnchorNode.convertPosition(object.position, from: object.parent)
		
		if objectPos.y == 0 {
			return; // The object is already on the plane - nothing to do here.
		}
		
		// Add 10% tolerance to the corners of the plane.
		let tolerance: Float = 0.1
		
		let minX: Float = anchor.center.x - anchor.extent.x / 2 - anchor.extent.x * tolerance
		let maxX: Float = anchor.center.x + anchor.extent.x / 2 + anchor.extent.x * tolerance
		let minZ: Float = anchor.center.z - anchor.extent.z / 2 - anchor.extent.z * tolerance
		let maxZ: Float = anchor.center.z + anchor.extent.z / 2 + anchor.extent.z * tolerance
		
		if objectPos.x < minX || objectPos.x > maxX || objectPos.z < minZ || objectPos.z > maxZ {
			return
		}
		
		// Drop the object onto the plane if it is near it.
		let verticalAllowance: Float = 0.03
		if objectPos.y > -verticalAllowance && objectPos.y < verticalAllowance {
			textManager.showDebugMessage("OBJECT MOVED\nSurface detected nearby")
			
			SCNTransaction.begin()
			SCNTransaction.animationDuration = 0.5
			SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: kCAMediaTimingFunctionEaseInEaseOut)
			object.position.y = anchor.transform.columns.3.y
			SCNTransaction.commit()
		}
	}
	
    // MARK: - Virtual Object Loading
	
	var virtualObject: VirtualObject?
	var isLoadingObject: Bool = false {
		didSet {
			DispatchQueue.main.async {
				self.settingsButton.isEnabled = !self.isLoadingObject
				self.addObjectButton.isEnabled = !self.isLoadingObject
				self.screenshotButton.isEnabled = !self.isLoadingObject
				self.restartExperienceButton.isEnabled = !self.isLoadingObject
			}
		}
	}
	
	@IBOutlet weak var addObjectButton: UIButton!
	
	func loadVirtualObject(at index: Int) {
		resetVirtualObject()
		
		// Show progress indicator
		let spinner = UIActivityIndicatorView()
		spinner.center = addObjectButton.center
		spinner.bounds.size = CGSize(width: addObjectButton.bounds.width - 5, height: addObjectButton.bounds.height - 5)
		addObjectButton.setImage(#imageLiteral(resourceName: "buttonring"), for: [])
		sceneView.addSubview(spinner)
		spinner.startAnimating()
		
		// Load the content asynchronously.
		DispatchQueue.global().async {
			self.isLoadingObject = true
			let object = VirtualObject.availableObjects[index]
			object.viewController = self
			self.virtualObject = object
			
			object.loadModel()
			
			DispatchQueue.main.async {
				// Immediately place the object in 3D space.
				if let lastFocusSquarePos = self.focusSquare?.lastPosition {
					self.setNewVirtualObjectPosition(lastFocusSquarePos)
				} else {
					self.setNewVirtualObjectPosition(SCNVector3Zero)
				}
				
				// Remove progress indicator
				spinner.removeFromSuperview()
				
				// Update the icon of the add object button
				let buttonImage = UIImage.composeButtonImage(from: object.thumbImage)
				let pressedButtonImage = UIImage.composeButtonImage(from: object.thumbImage, alpha: 0.3)
				self.addObjectButton.setImage(buttonImage, for: [])
				self.addObjectButton.setImage(pressedButtonImage, for: [.highlighted])
				self.isLoadingObject = false
			}
		}
    }
	
	@IBAction func chooseObject(_ button: UIButton) {
		// Abort if we are about to load another object to avoid concurrent modifications of the scene.
		if isLoadingObject { return }
		
		textManager.cancelScheduledMessage(forType: .contentPlacement)
		
		let rowHeight = 45
		let popoverSize = CGSize(width: 250, height: rowHeight * VirtualObject.availableObjects.count)
		
		let objectViewController = VirtualObjectSelectionViewController(size: popoverSize)
		objectViewController.delegate = self
		objectViewController.modalPresentationStyle = .popover
		objectViewController.popoverPresentationController?.delegate = self
		self.present(objectViewController, animated: true, completion: nil)
		
		objectViewController.popoverPresentationController?.sourceView = button
		objectViewController.popoverPresentationController?.sourceRect = button.bounds
    }
	
	// MARK: - VirtualObjectSelectionViewControllerDelegate
	
	func virtualObjectSelectionViewController(_: VirtualObjectSelectionViewController, didSelectObjectAt index: Int) {
		loadVirtualObject(at: index)
	}
	
	func virtualObjectSelectionViewControllerDidDeselectObject(_: VirtualObjectSelectionViewController) {
		resetVirtualObject()
	}
	
    // MARK: - Planes
    var planeAnchor: ARPlaneAnchor?
    var plane: Plane? {
        willSet {
            guard newValue == nil, let plane = plane else {return}
            self.planeAnchor = nil
            plane.removeFromParentNode()
        }
        didSet {
            guard let planeAnchor = planeAnchor,
                let plane = plane else { return }
            planes.removeValue(forKey: planeAnchor)
            removePlanes()
            plane.update(extent: vector_float3(10, 0, 10))
            
        }
    }
	var planes = [ARPlaneAnchor: Plane]()
    
	
    func addPlane(node: SCNNode, anchor: ARPlaneAnchor) {
		
		let pos = SCNVector3.positionFromTransform(anchor.transform)
		textManager.showDebugMessage("NEW SURFACE DETECTED AT \(pos.friendlyString())")
        
		let plane = Plane(anchor, showDebugVisuals)
		
		planes[anchor] = plane
		node.addChildNode(plane)
		
		textManager.cancelScheduledMessage(forType: .planeEstimation)
		textManager.showMessage("SURFACE DETECTED")
		if virtualObject == nil {
			textManager.scheduleMessage("TAP + TO PLACE AN OBJECT", inSeconds: 7.5, messageType: .contentPlacement)
		}
	}
		
    func updatePlane(anchor: ARPlaneAnchor) {
        if let plane = planes[anchor] {
			plane.update(anchor)
		}
	}
	
    func removePlane(anchor: ARPlaneAnchor) {
		if let plane = planes.removeValue(forKey: anchor) {
			plane.removeFromParentNode()
        }
    }
    
    func removePlanes() {
        Logger.log()
        for (anchor, _) in planes {
            removePlane(anchor: anchor)
        }
    }
    
    @IBAction func undo() {
        measure.undo()
    }
    
    @IBAction func getArea() {
        measure.getArea()
    }
    
    func restartWithoutPlaneDetection() {
        // configure session
        sessionConfig.isLightEstimationEnabled = true
        session.run(sessionConfig, options: [.resetTracking, .removeExistingAnchors])
        
        
        // reset timer
        if trackingFallbackTimer != nil {
            trackingFallbackTimer!.invalidate()
            trackingFallbackTimer = nil
        }
        
        textManager.scheduleMessage("FIND A SURFACE TO PLACE AN OBJECT",
                                    inSeconds: 7.5,
                                    messageType: .focusSquare)
    }
	
    func restartPlaneDetection() {
        
		// configure session
        Logger.log("sessionConfig.planeDetection = .horizontal", event: .verbose)
        sessionConfig.planeDetection = .horizontal
        sessionConfig.isLightEstimationEnabled = true
        session.run(sessionConfig, options: [.resetTracking, .removeExistingAnchors])

		
		// reset timer
		if trackingFallbackTimer != nil {
			trackingFallbackTimer!.invalidate()
			trackingFallbackTimer = nil
		}
		
		textManager.scheduleMessage("FIND A SURFACE TO PLACE AN OBJECT",
		                            inSeconds: 7.5,
		                            messageType: .planeEstimation)
	}

    // MARK: - Focus Square
    var focusSquare: FocusSquare?
	
    func setupFocusSquare() {
		focusSquare?.isHidden = true
		focusSquare?.removeFromParentNode()
		focusSquare = FocusSquare()
		sceneView.scene.rootNode.addChildNode(focusSquare!)
		textManager.scheduleMessage("TRY MOVING LEFT OR RIGHT", inSeconds: 5.0, messageType: .focusSquare)

    }
	
	func updateFocusSquare() {
		guard let screenCenter = screenCenter else { return }
		
		if virtualObject != nil && sceneView.isNode(virtualObject!, insideFrustumOf: sceneView.pointOfView!) {
			focusSquare?.hide()
		} else {
			focusSquare?.unhide()
		}
		let (worldPos, planeAnchor, _) = worldPositionFromScreenPosition(screenCenter, objectPos: focusSquare?.position)
		if let worldPos = worldPos {
			focusSquare?.update(for: worldPos, planeAnchor: planeAnchor, camera: self.session.currentFrame?.camera)
			textManager.cancelScheduledMessage(forType: .focusSquare)
		}
	}
	
	// MARK: - Hit Test Visualization
	
	var hitTestVisualization: HitTestVisualization?
	
	var showHitTestAPIVisualization = UserDefaults.standard.bool(for: .showHitTestAPI) {
		didSet {
			UserDefaults.standard.set(showHitTestAPIVisualization, for: .showHitTestAPI)
			if showHitTestAPIVisualization {
				hitTestVisualization = HitTestVisualization(sceneView: sceneView)
			} else {
				hitTestVisualization = nil
			}
		}
	}
	
    // MARK: - Debug Visualizations
	
	@IBOutlet var featurePointCountLabel: UILabel!
	
	func refreshFeaturePoints() {
		guard showDebugVisuals else {
			return
		}
		
		// retrieve cloud
		guard let cloud = session.currentFrame?.rawFeaturePoints else {
			return
		}
		
		DispatchQueue.main.async {
			self.featurePointCountLabel.text = "Features: \(cloud.__count)".uppercased()
		}
	}
	
    var showDebugVisuals: Bool = UserDefaults.standard.bool(for: .debugMode) {
        didSet {
			featurePointCountLabel.isHidden = !showDebugVisuals
			debugMessageLabel.isHidden = !showDebugVisuals
			messagePanel.isHidden = !showDebugVisuals
			planes.values.forEach { $0.showDebugVisualization(showDebugVisuals) }
			
			if showDebugVisuals {
				sceneView.debugOptions = [ARSCNDebugOptions.showFeaturePoints, ARSCNDebugOptions.showWorldOrigin]
			} else {
				sceneView.debugOptions = []
			}
			
            // save pref
            UserDefaults.standard.set(showDebugVisuals, for: .debugMode)
        }
    }
    
    func setupDebug() {
		// Set appearance of debug output panel
		messagePanel.layer.cornerRadius = 3.0
		messagePanel.clipsToBounds = true
    }
    
    // MARK: - UI Elements and Actions
	
	@IBOutlet weak var messagePanel: UIView!
	@IBOutlet weak var messageLabel: UILabel!
	@IBOutlet weak var debugMessageLabel: UILabel!
	
	var textManager: TextManager!
	
    func setupUIControls() {
		textManager = TextManager(viewController: self)
		
        // hide debug message view
		debugMessageLabel.isHidden = true
		
		featurePointCountLabel.text = ""
		debugMessageLabel.text = ""
		messageLabel.text = ""
    }
	
	@IBOutlet weak var restartExperienceButton: UIButton!
	var restartExperienceButtonIsEnabled = true
	
	@IBAction func restartExperience(_ sender: Any) {
		
		guard restartExperienceButtonIsEnabled, !isLoadingObject else {
			return
		}
		
		DispatchQueue.main.async {
			self.restartExperienceButtonIsEnabled = false
			
			self.textManager.cancelAllScheduledMessages()
			self.textManager.dismissPresentedAlert()
			self.textManager.showMessage("STARTING A NEW SESSION")
			self.use3DOFTracking = false
			
			self.setupFocusSquare()
//            self.resetVirtualObject()
			self.restartPlaneDetection()
			
			self.restartExperienceButton.setImage(#imageLiteral(resourceName: "restart"), for: [])
			
			// Disable Restart button for five seconds in order to give the session enough time to restart.
			DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: {
				self.restartExperienceButtonIsEnabled = true
			})
		}
	}
    
    
	
    // MARK: Screenshot
	@IBOutlet weak var screenshotButton: UIButton!
    private var takeScreenshotWithoutGraphics = false
    private var childNodesTemporaryContainer = [SCNNode]()
	
    /**
     Take a screenshot of a measuring session.
     Screenshot includes:
         - RGB image (TODO)
         - RGB image with graphics
         - World coordinates
         - Screen coordinates (TODO)
         - Area (TODO)
     
     */
	@IBAction func takeScreenshot() {
		guard screenshotButton.isEnabled else {
			return
		}
		
        let takeScreenshotBlock = {
//            UIImageWriteToSavedPhotosAlbum(self.sceneView.snapshot(), nil, nil, nil)
            
            let screenshotName: String = Date().iso8601
            
            let start = DispatchTime.now()
            
            /// Take screenshots with graphics
            let screenshotWithGraphic = self.sceneView.snapshot()
            
            /// Take a screenshot without graphics
            self.sceneView.scene.rootNode.isHidden = true
            let screenshotWithoutGraphic = self.sceneView.snapshot()
            
            /// Show graphics again
            self.sceneView.scene.rootNode.isHidden = false
            
            let end = DispatchTime.now()
            let nanoTime = end.uptimeNanoseconds - start.uptimeNanoseconds // <<<<< Difference in nano seconds (UInt64)
            let timeInterval = Double(nanoTime) / 1_000_000_000 // Technically could overflow for long running tests
            Logger.log("Screenshot elapsed time: \(timeInterval) sec", event: .info)
            
            self.save(screenshotName: screenshotName, screenshotWithGraphic: screenshotWithGraphic, screenshotWithoutGraphic: screenshotWithoutGraphic)
            
//            DispatchQueue.global(qos: .background).async {
//                /// Save the screenshot to disk
//                FileManagerWrapper.writeImageToDisk(
//                    image: screenshotWithGraphics,
//                    imageName: screenshotName + "-with-graphics",
//                    format: .png
//                )
//
//                FileManagerWrapper.writeImageToDisk(
//                    image: screenshotWithoutGraphics,
//                    imageName: screenshotName,
//                    format: .png
//                )
//            }
            
            /// Save data to Realm DB.
//            self.realmManager.add(measure: self.measure, screenshotName: screenshotName)
            
			DispatchQueue.main.async {
				// Briefly flash the screen.
				let flashOverlay = UIView(frame: self.sceneView.frame)
				flashOverlay.backgroundColor = UIColor.white
				self.sceneView.addSubview(flashOverlay)
				UIView.animate(withDuration: 0.25, animations: {
					flashOverlay.alpha = 0.0
				}, completion: { _ in
					flashOverlay.removeFromSuperview()
				})
			}
		}
        
		takeScreenshotBlock()
	}
    
    private func save(screenshotName: String, screenshotWithGraphic: UIImage, screenshotWithoutGraphic: UIImage) {
        guard let measureData = realmManager.add(measure: measure, screenshotName: screenshotName) else {
            Logger.log("Couldn't save measure data", event: .severe)
            return
        }
        
        DispatchQueue.global(qos: .background).async {
            /// Save the screenshot to disk
            FileManagerWrapper.writeImageToDisk(
                image: screenshotWithGraphic,
                imageName: screenshotName + "-with-graphics",
                format: .png
            )
            
            FileManagerWrapper.writeImageToDisk(
                image: screenshotWithoutGraphic,
                imageName: screenshotName,
                format: .png
            )
        }
        
        JSONManager.sharedInstance.updateMainJSON(data: measureData)
        self.albumButton.setImage(screenshotWithGraphic, for: .normal)
    }
		
	// MARK: - Settings
	
	@IBOutlet weak var settingsButton: UIButton!
	
	@IBAction func showSettings(_ button: UIButton) {
		let storyboard = UIStoryboard(name: "Main", bundle: nil)
		guard let settingsViewController = storyboard.instantiateViewController(withIdentifier: "settingsViewController") as? SettingsViewController else {
			return
		}
		
        let barButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(dismissSettings))
		settingsViewController.navigationItem.rightBarButtonItem = barButtonItem
        settingsViewController.title = "Options"
		
		let navigationController = UINavigationController(rootViewController: settingsViewController)
		navigationController.modalPresentationStyle = .popover
		navigationController.popoverPresentationController?.delegate = self
		navigationController.preferredContentSize = CGSize(width: sceneView.bounds.size.width - 20, height: sceneView.bounds.size.height - 50)
		self.present(navigationController, animated: true, completion: nil)
		
		navigationController.popoverPresentationController?.sourceView = settingsButton
		navigationController.popoverPresentationController?.sourceRect = settingsButton.bounds
	}
	
    @objc
    func dismissSettings() {
		self.dismiss(animated: true, completion: nil)
		updateSettings()
	}
    
    // MARK: Measure Mode
    enum MeasureMode {
        case normal
        case horizontal
    }
    private var measureMode: MeasureMode = .normal
	
	private func updateSettings() {
		let defaults = UserDefaults.standard
		
		showDebugVisuals = defaults.bool(for: .debugMode)
		toggleAmbientLightEstimation(defaults.bool(for: .ambientLightEstimation))
		dragOnInfinitePlanesEnabled = defaults.bool(for: .dragOnInfinitePlanes)
		showHitTestAPIVisualization = defaults.bool(for: .showHitTestAPI)
		use3DOFTracking	= defaults.bool(for: .use3DOFTracking)
		use3DOFTrackingFallback = defaults.bool(for: .use3DOFFallback)
		for (_, plane) in planes {
			plane.updateOcclusionSetting()
		}
        
        if defaults.bool(for: .useHorizontalMeasure) {
            measureMode = .horizontal
            restartWithoutPlaneDetection()
        } else {
            measureMode = .normal
            restartPlaneDetection()
        }
	}
    
    // MARK:Image Album VC
    @IBOutlet weak var albumButton: UIButton!
    @IBAction func showAlbum(_ sender: UIButton) {
        Logger.log("Pause ARSession", event: .info)
        self.session.pause()
        performSegue(withIdentifier: "ShowAlbum", sender: nil)
    }
    
    private func setupShowAlbumButton() {
        guard let data = realmManager.recentData else {
            Logger.log("Hide ShowAlbumButton🖼", event: .verbose)
            hideShowAlbumButton()
            return
        }
        
        guard let image = FileManagerWrapper.getImageFromDisk(name: data.screenshotName) else {
            return
        }
        
        updateShowAlbumButtonImage(with: image)
        
    }

	// MARK: - Error handling
	
	func displayErrorMessage(title: String, message: String, allowRestart: Bool = false) {
		// Blur the background.
		textManager.blurBackground()
		
		if allowRestart {
			// Present an alert informing about the error that has occurred.
			let restartAction = UIAlertAction(title: "Reset", style: .default) { _ in
				self.textManager.unblurBackground()
				self.restartExperience(self)
			}
			textManager.showAlert(title: title, message: message, actions: [restartAction])
		} else {
			textManager.showAlert(title: title, message: message, actions: [])
		}
	}
	
	// MARK: - UIPopoverPresentationControllerDelegate
	func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle {
		return .none
	}
	
	func popoverPresentationControllerDidDismissPopover(_ popoverPresentationController: UIPopoverPresentationController) {
		updateSettings()
        
        var json: JSON =  ["name": "Jack", "age": 25]
        json["name"] = "Mike"
        json["age"] = "25" //It's OK to set String
        json["address"] = "L.A."
	}
    
    /**
     Share a single measure session
     */
    @IBAction func share(_ sender: UIButton) {
        /// 1. Convert data into JSON
        let worldCoordinates: [[Float]] = measure.measureNodeWorldCoordinateAsList
        var json: JSON = [
            "worldCoordinates": worldCoordinates
        ]
        
        /// 2. Get path for JSON in local drive
        guard let path = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first else {
                return
        }
        
        let saveFileURL = path.appendingPathComponent("test.json")
        
        
        /// 4. Get screenshot
        let screenshot = self.sceneView.snapshot()
        let screenshotName: String = Date().iso8601
        FileManagerWrapper.writeImageToDisk(image: screenshot, imageName: screenshotName, format: .png)
        json["screenShotName"].stringValue = screenshotName
        
        /// 3. Write JSON to local drive
        let data = try! json.rawData()
        try! data.write(to: saveFileURL, options: .atomic)
        
        
        
        let activityVC = UIActivityViewController(activityItems: ["measure data", saveFileURL, screenshot], applicationActivities: nil)
        activityVC.popoverPresentationController?.sourceView = self.view
        
        self.present(activityVC, animated: true, completion: nil)
    }
    
    @IBAction func returnToMeasuring(segue: UIStoryboardSegue) {
        /// https://www.andrewcbancroft.com/2015/12/18/working-with-unwind-segues-programmatically-in-swift/#trigger
        resetARSession()
    }
    
    
}



extension ViewController: ARSCNViewDelegate {
    // MARK: - ARSCNViewDelegate
    
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        refreshFeaturePoints()
        
        DispatchQueue.main.async {
            self.updateFocusSquare()
            self.hitTestVisualization?.render()
            
            // If light estimation is enabled, update the intensity of the model's lights and the environment map
            if let lightEstimate = self.session.currentFrame?.lightEstimate {
                self.enableEnvironmentMapWithIntensity(lightEstimate.ambientIntensity / 40)
            } else {
                self.enableEnvironmentMapWithIntensity(25)
            }
        }
        
        
    }
    
    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        guard plane == nil else {
            return }
        DispatchQueue.main.async {
            if let planeAnchor = anchor as? ARPlaneAnchor {
                self.addPlane(node: node, anchor: planeAnchor)
                self.checkIfObjectShouldMoveOntoPlane(anchor: planeAnchor)
            }
        }
    }
    
    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard plane == nil else { return }
        DispatchQueue.main.async {
            if let planeAnchor = anchor as? ARPlaneAnchor {
                self.updatePlane(anchor: planeAnchor)
                self.checkIfObjectShouldMoveOntoPlane(anchor: planeAnchor)
            }
        }
    }
    
    func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
        guard plane == nil else { return }
        Logger.log("", event: .debug)
        DispatchQueue.main.async {
            if let planeAnchor = anchor as? ARPlaneAnchor {
                self.removePlane(anchor: planeAnchor)
            }
        }
    }
}

extension ViewController: MeasureDelegate {
    func enableAreaCalculation() {
        getAreaButton.addTarget(self, action: #selector(getArea), for: .touchUpInside)
        getAreaButton.setTitleColor(.blue, for: .normal)
        getAreaButton.setTitleColor(.black, for: .highlighted)
    }
    
    func disableAreaCalculation() {
        getAreaButton.removeTarget(self, action: #selector(getArea), for: .touchUpInside)
        getAreaButton.setTitleColor(.gray, for: .normal)
        getAreaButton.setTitleColor(.gray, for: .highlighted)
    }
    
    func updateLabel(perimeter: Float, area: Float) {
//        mainView.setLabelText(perimeter: perimeter, area: area)
    }
    
    var isAreaCalculationAvailable: Bool {
        return true
    }
}

extension ViewController: RealmManagerDelegate {
    func hideShowAlbumButton() {
        self.albumButton.isHidden = true
    }
    
    func showShowAlbumButton() {
        self.albumButton.isHidden = false
    }
    
    func updateShowAlbumButtonImage(with image: UIImage){
        showShowAlbumButton()
        self.albumButton.setImage(image, for: .normal)
    }
}
