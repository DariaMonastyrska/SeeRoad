//
//  MainViewController.swift

//
//
//

import AVFoundation
import UIKit
import Vision

class MainViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
    
    private enum DetectorState {
        case sleeping, detecting, tracking
    }
    
    // MARK: - Application Parameters
    
    private let interfaceCoverViewAnimationDuration = 0.5
    private let wasInformationViewShownKey = "wasInformationViewShown"
    private let clockDateFormat = "HH:mm"
    private let cameraAutoFocusSystem = AVCaptureDevice.Format.AutoFocusSystem.phaseDetection
    private let cameraFocusMode = AVCaptureDevice.FocusMode.continuousAutoFocus
    private let cameraFormatType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    private let cameraFrameRate = 60
    private let cameraMaximumVideoWidth = 1920
    private let cameraStabilizationMode = AVCaptureVideoStabilizationMode.standard
    private let objectDetectionConfidenceThreshold: Float = 0.6
    private let objectDetectionMaximumAspectRatioDeviation: CGFloat = 0.2
    private let objectDetectionMinimumHeight: CGFloat = 0.04
    private let observationRectangleLineWidth: CGFloat = 2
    private let observationRectangleLineDashPattern: [NSNumber] = [8, 6]
    private let observationRectangleStrokeColor = UIColor.green.cgColor
    private let observationRectangleFillColor = UIColor.clear.cgColor
    private let objectTrackingConfidenceThreshold: Float = 0.6
    private let objectTrackingEscapeMargin: CGFloat = 0.02
    private let objectTrackingLevel = VNRequestTrackingLevel.fast
    private let objectTrackingRevision = VNTrackObjectRequestRevision2
    private let textRecognitionConfidenceThreshold: Float = 0.4
    private let textRecognitionMinimumTextHeight: Float = 0.1
    private let textRecognitionLevel = VNRequestTextRecognitionLevel.fast
    private let textRecognitionRevision = VNRecognizeTextRequestRevision1
    private let textRecognitionUsesLanguageCorrection = true
    private let maximumTextRecognitionAttempts = 10
    private let forbiddenTextRecognitionResultCharacters = [",", "m", "t"]
    private let possibleTextRecognitionResultCharacterConfusions = [
        "0": ["c", "C", "o", "O", "Q", "U", "()", "(", ")"],
        "1": ["i", "I", "l", "!"],
        "2": ["z", "Z"],
        "5": ["s", "S", "$"],
        "6": ["b", "G"],
        "8": ["B"],
        "9": ["q"]
    ]
    private let unambiguousTextRecognitionResultCorrections = [
        "4": "40",
        "6": "60",
        "7": "70",
        "8": "80",
        "9": "90"
    ]
    private let otherTextRecognitionResultCorrections = [
        { (text: String) -> String in
            text.contains("00") ? "100" : text
        }
    ]
    private let validTextRecognitionResults = ["5", "10", "15", "20", "25", "30", "40", "50", "60", "70", "80", "90", "100", "110", "120", "130"]
    private let sleepDuration = 3
    private let speedLimitValidityDuration = 180

    private let minimumTextHeightPercentage: CGFloat = 0.1 // Знизити до 10% (замість 20%)
    private let maximumTextHeightPercentage: CGFloat = 0.3 // Додати верхню межу



    // MARK: - Interface Builder Outlets
    
    @IBOutlet private var cameraView: UIView!
    @IBOutlet private var interfaceCover: UIView!
    @IBOutlet private var cameraAccessDenialView: UIScrollView!
    @IBOutlet private var speedLimitSign: SpeedLimitView!
    @IBOutlet private var blurEffectView: UIVisualEffectView!
    @IBOutlet private var informationBar: UIVisualEffectView!
    @IBOutlet private var informationBarLeadingConstraint: NSLayoutConstraint!
    @IBOutlet private var clock: UILabel!
    
    // MARK: - Application Variables
    
    private var dateFormatter: DateFormatter!
    private var captureSession: AVCaptureSession!
    private var cameraPreviewLayer: AVCaptureVideoPreviewLayer!
    private var objectObservationLayer: CALayer!
    private var pixelBufferSize: CGSize!
    private var videoOrientation = AVCaptureVideoOrientation.landscapeRight
    private var imageOrientation = CGImagePropertyOrientation.up
    private var isCameraReady = false
    private var detectorState = DetectorState.sleeping
    private var currentPixelBuffer: CVImageBuffer!
    private var objectDetectionRequest: VNCoreMLRequest!
    private var objectObservation: VNDetectedObjectObservation!
    private var objectTrackingRequest: VNTrackObjectRequest!
    private var objectTrackingRequestHandler: VNSequenceRequestHandler!
    private var textRecognitionRequest: VNRecognizeTextRequest!
    private var textRecognitionAttemptCounter = 0
    private var upcomingSpeedLimit: String?
    private var currentSpeedLimitCancelationTask: DispatchWorkItem?
    
    // MARK: - UIViewController Overrides
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Configure the clock.
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = clockDateFormat
        dateFormatter.timeZone = .autoupdatingCurrent
        clock.text = dateFormatter.string(from: Date())
        RunLoop.current.add(Timer(timeInterval: 1, repeats: true) { _ in
            self.clock.text = self.dateFormatter.string(from: Date())
        }, forMode: .common)
        
        // Prevent the screen from sleeping.
        UIApplication.shared.isIdleTimerDisabled = true
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        // Check the camera access authorization status and either show a denial view or start the main application tasks.
        checkCameraAccessAuthorizationStatus()
    }
    
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)

        // Handle a device orientation change.
        updateOrientationData()
        cameraPreviewLayer?.connection?.videoOrientation = videoOrientation
    }
    
    // MARK: - Configuration
    
    private func checkCameraAccessAuthorizationStatus() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            if granted {
                self.configureCameraFeed()
                self.configureObjectDetection()
                self.configureTextRecognition()
                
                DispatchQueue.main.async {
                    self.startCameraFeed()
                    
                    // Hide an interface cover and begin object detection.
                    UIView.animate(withDuration: self.interfaceCoverViewAnimationDuration, animations: {
                        self.interfaceCover.layer.opacity = 0
                    }, completion: { _ in
                        self.interfaceCover.isHidden = true
                        
                        // If it is the first time the application is being launched successfully, show the information view.
                        if self.presentedViewController == nil {
                            if !UserDefaults.standard.bool(forKey: self.wasInformationViewShownKey) {
                                UserDefaults.standard.setValue(true, forKey: self.wasInformationViewShownKey)
                                self.performSegue(withIdentifier: "showInformationView", sender: nil)
                            } else {
                                self.detectorState = .detecting
                            }
                        }
                    })
                }
            } else {
                // If not granted, show a camera access denial view.
                DispatchQueue.main.async {
                    self.cameraAccessDenialView.layer.opacity = 0
                    self.cameraAccessDenialView.isHidden = false

                    UIView.animate(withDuration: self.interfaceCoverViewAnimationDuration, animations: {
                        self.cameraAccessDenialView.layer.opacity = 1
                    }, completion: nil)
                }
            }
            
            // After an app launch, unlock both landscape orientations.
            DispatchQueue.main.async {
                (UIApplication.shared.delegate as! AppDelegate).orientationMask = .landscapeRight
            }
        }
    }
    
    private func configureCameraFeed() {
        captureSession = AVCaptureSession()
        captureSession.beginConfiguration()
        
        guard let backCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            showGeneralError()
            captureSession.commitConfiguration()
            return
        }
                
        let captureInput: AVCaptureDeviceInput
        
        do {
            captureInput = try AVCaptureDeviceInput(device: backCamera)
        } catch {
            showGeneralError()
            captureSession.commitConfiguration()
            return
        }
        
        guard captureSession.canAddInput(captureInput) else {
            showGeneralError()
            captureSession.commitConfiguration()
            return
        }
        
        captureSession.addInput(captureInput)
        
        // Query available input device formats, filtering them by criteria described in Application Parameters section. Next, sort them by their minimum exposure duration in ascending order and choose the best one.
        guard let cameraFormat = backCamera.formats.filter({ $0.formatDescription.mediaSubType.rawValue == cameraFormatType && $0.formatDescription.dimensions.width <= cameraMaximumVideoWidth && $0.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= Double(cameraFrameRate) }) && $0.isVideoStabilizationModeSupported(cameraStabilizationMode) && $0.autoFocusSystem == cameraAutoFocusSystem }).sorted(by: { $0.minExposureDuration < $1.minExposureDuration }).first else {
            showGeneralError()
            captureSession.commitConfiguration()
            return
        }
        
        // Store the selected format's dimensions for future use.
        let dimensions = cameraFormat.formatDescription.dimensions
        pixelBufferSize = CGSize(width: CGFloat(dimensions.width), height: CGFloat(dimensions.height))
        
        // Configure an input device.
        do {
            try backCamera.lockForConfiguration()

            backCamera.videoZoomFactor = 1.5
            backCamera.activeFormat = cameraFormat
            backCamera.focusMode = cameraFocusMode
            backCamera.activeVideoMinFrameDuration = CMTimeMake(value: 1, timescale: Int32(cameraFrameRate))
            backCamera.activeVideoMaxFrameDuration = CMTimeMake(value: 1, timescale: Int32(cameraFrameRate))
            
            if backCamera.isLowLightBoostSupported {
                backCamera.automaticallyEnablesLowLightBoostWhenAvailable = true
            }
            
            if backCamera.isSmoothAutoFocusSupported {
                backCamera.isSmoothAutoFocusEnabled = true
            }
            
            backCamera.unlockForConfiguration()
        } catch {
            showGeneralError()
            captureSession.commitConfiguration()
            return
        }
        
        let captureOutput = AVCaptureVideoDataOutput()
        
        guard captureSession.canAddOutput(captureOutput) else {
            showGeneralError()
            captureSession.commitConfiguration()
            return
        }
        
        captureSession.addOutput(captureOutput)
        
        // Configure a capture output.
        let captureQueue = DispatchQueue(label: "CaptureQueue", qos: .userInteractive, attributes: [], autoreleaseFrequency: .workItem)
        captureOutput.alwaysDiscardsLateVideoFrames = true
        captureOutput.setSampleBufferDelegate(self, queue: captureQueue)
        captureOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(cameraFormatType)]
        
        // Configure a capture connection. If supported, enable two important options.
        let captureConnection = captureSession.connections.first!
        
        if captureConnection.isCameraIntrinsicMatrixDeliverySupported {
            captureConnection.isCameraIntrinsicMatrixDeliveryEnabled = true
        }
        
        if captureConnection.isVideoStabilizationSupported {
            captureConnection.preferredVideoStabilizationMode = cameraStabilizationMode
        }
        
        captureSession.commitConfiguration()
        isCameraReady = true
    }
    
    private func configureObjectDetection() {
        guard isCameraReady else { return }
        
        do {
            let model = try VNCoreMLModel(for: MLModel(contentsOf: YOLOv8SignDetector.urlOfModelInThisBundle))
            objectDetectionRequest = VNCoreMLRequest(model: model) { (request, _) in
                self.processObjectDetectionResults(request.results)
            }
        } catch {
            showGeneralError()
        }
    }

    private func configureTextRecognition() {
        textRecognitionRequest = VNRecognizeTextRequest()
        textRecognitionRequest.recognitionLevel = .accurate // Змінити на accurate для малих текстів
        textRecognitionRequest.minimumTextHeight = 0.05 // Знизити мінімальний розмір тексту
        textRecognitionRequest.usesLanguageCorrection = false // Вимкнути корекцію для цифр
        textRecognitionRequest.customWords = validTextRecognitionResults
    }

//    private func configureTextRecognition() {
//        guard isCameraReady else { return }
//        
//        textRecognitionRequest = VNRecognizeTextRequest { (request, _) in
//            self.processTextRecognitionResults(request.results)
//        }
//        textRecognitionRequest.customWords = validTextRecognitionResults
//        textRecognitionRequest.minimumTextHeight = textRecognitionMinimumTextHeight
//        textRecognitionRequest.recognitionLevel = textRecognitionLevel
//        textRecognitionRequest.revision = textRecognitionRevision
//        textRecognitionRequest.usesLanguageCorrection = textRecognitionUsesLanguageCorrection
//    }
    
    private func startCameraFeed() {
        guard isCameraReady else { return }
        
        // Set up a camera preview layer.
        cameraPreviewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        cameraPreviewLayer.connection!.videoOrientation = videoOrientation
        cameraPreviewLayer.videoGravity = .resizeAspectFill
        cameraPreviewLayer.frame = cameraView.layer.bounds
        cameraView.layer.addSublayer(cameraPreviewLayer)
                
        // Set up an object observation layer.
        objectObservationLayer = CALayer()
        objectObservationLayer.frame = cameraPreviewLayer.bounds
        cameraPreviewLayer.addSublayer(objectObservationLayer)

        DispatchQueue.global(qos: .userInitiated).async {
            self.captureSession.startRunning()
            print("Running camera...")
        }
    }
    
    // MARK: - Computer Vision
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        // If available, prepare an options dictionary with some additional camera information. This supports computer vision tasks.
        var options: [VNImageOption: Any] = [:]
        
        if let cameraIntrinsics = pixelBuffer.attachments.propagated[kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix as String] {
            options = [VNImageOption.cameraIntrinsics: cameraIntrinsics]
        }
        
        switch detectorState {
        case .sleeping:
            // Relax. 🏖
            return
        case .detecting:
            currentPixelBuffer = pixelBuffer
            
            // Perform an object detection task.
            let requestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: imageOrientation, options: options)
            
            do {
                try requestHandler.perform([objectDetectionRequest])
            } catch {
                showGeneralError()
            }
        case .tracking:
            // If needed, perform a text recognition task (one has already been completed right after a successful object detection).
            if upcomingSpeedLimit == nil {
                if textRecognitionAttemptCounter < maximumTextRecognitionAttempts - 1 {
                    textRecognitionAttemptCounter += 1
                    beginTextRecognition(onPixelBuffer: pixelBuffer, croppingTo: objectObservation.boundingBox)
                } else {
                    DispatchQueue.main.async {
                        self.clearObjectObservationRectangle()
                    }

                    returnToObjectDetection()
                    return
                }
            }
            
            // Begin another round of object tracking.
            if objectTrackingRequest == nil {
                objectTrackingRequest = VNTrackObjectRequest(detectedObjectObservation: objectObservation) { (request, _) in
                    self.processObjectTrackingResults(request.results)
                }
                objectTrackingRequest.revision = objectTrackingRevision
                objectTrackingRequest.trackingLevel = objectTrackingLevel
            } else {
                objectTrackingRequest.inputObservation = objectObservation
            }
            
            do {
                try objectTrackingRequestHandler.perform([objectTrackingRequest], on: pixelBuffer, orientation: imageOrientation)
            } catch {
                showGeneralError()
                returnToObjectDetection()
            }
        }
    }
    
    private func processObjectDetectionResults(_ results: [Any]?) {
        if let results = results as? [VNDetectedObjectObservation], !results.isEmpty {
            // Accept only the objects which pass the confidence threshold, are big enough and close to the target 1:1 aspect ratio. Next, sort them by their confidence in descending order.
            let validResults = results.filter { result in
                let imageRectangle = VNImageRectForNormalizedRect(result.boundingBox, Int(pixelBufferSize.width), Int(pixelBufferSize.height))
                
                if result.confidence >= objectDetectionConfidenceThreshold && result.boundingBox.height >= objectDetectionMinimumHeight && abs(imageRectangle.width / imageRectangle.height - 1) <= objectDetectionMaximumAspectRatioDeviation {
                    return true
                }
                
                return false
            }.sorted { $0.confidence > $1.confidence }
            
            // If there is a valid observation, begin a text recognition task and prepare for tracking the observation.
            if let bestResult = validResults.first {
                beginTextRecognition(onPixelBuffer: currentPixelBuffer, croppingTo: bestResult.boundingBox)

                detectorState = .tracking
                objectObservation = bestResult
                objectTrackingRequestHandler = VNSequenceRequestHandler()
                
                currentPixelBuffer = nil
            }
        }
    }

    private func prepareImageForTextRecognition(_ image: CIImage) -> CIImage {
        // Масштабування для збільшення малого тексту
        let scaleFactor: CGFloat = 2.0
        let scaledImage = image.transformed(by: CGAffineTransform(scaleX: scaleFactor, y: scaleFactor))

        // Інша обробка...
        var processedImage = scaledImage.applyingFilter("CIColorControls", parameters: [
            kCIInputContrastKey: 1.5,
            kCIInputBrightnessKey: 0.1
        ])

        processedImage = processedImage.applyingFilter("CISharpenLuminance", parameters: [
            kCIInputSharpnessKey: 0.5
        ])

        return processedImage
    }

//    private func prepareImageForTextRecognition(_ image: CIImage) -> CIImage {
//        var preprocessedImage = image
//        
//        // 1. Desaturate the image - make it black & white.
//        preprocessedImage = CIFilter(name: "CIColorControls", parameters: [kCIInputImageKey: preprocessedImage, kCIInputSaturationKey: 0])!.outputImage!
//        
//        // 2. Increase the exposure value.
//        preprocessedImage = CIFilter(name: "CIExposureAdjust", parameters: [kCIInputImageKey: image, kCIInputEVKey: 2])!.outputImage!
//        
//        // 3. Remove highlights.
//        preprocessedImage = CIFilter(name: "CIHighlightShadowAdjust", parameters: [kCIInputImageKey: image, "inputHighlightAmount": 0])!.outputImage!
//        
//        // 4. Increase brightness and contrast.
//        preprocessedImage = CIFilter(name: "CIColorControls", parameters: [kCIInputImageKey: image, kCIInputBrightnessKey: 0.45, kCIInputContrastKey: 2])!.outputImage!
//        
//        // 5. Remove highlights again.
//        preprocessedImage = CIFilter(name: "CIHighlightShadowAdjust", parameters: [kCIInputImageKey: image, "inputHighlightAmount": 0])!.outputImage!
//        
//        // 6. Apply a box blur to remove some of noise in the image.
//        preprocessedImage = CIFilter(name: "CIBoxBlur", parameters: [kCIInputImageKey: image, kCIInputRadiusKey: 4])!.outputImage!
//        
//        return preprocessedImage
//    }

    private func beginTextRecognition(onPixelBuffer pixelBuffer: CVImageBuffer, croppingTo objectObservationBoundingBox: CGRect) {
        // Збільшити область розпізнавання на 20%
        let expandedBox = objectObservationBoundingBox.insetBy(dx: -objectObservationBoundingBox.width * 0.2,
                                                             dy: -objectObservationBoundingBox.height * 0.2)

        // Обмежити до меж кадру
        let safeBox = expandedBox.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))

        let imageBoundingBox = VNImageRectForNormalizedRect(safeBox, Int(pixelBufferSize.width), Int(pixelBufferSize.height))

        // Додаткова перевірка розміру
        let textHeightRatio = imageBoundingBox.height / pixelBufferSize.height
        if textHeightRatio < minimumTextHeightPercentage || textHeightRatio > maximumTextHeightPercentage {
            print("Text size out of range: \(textHeightRatio)")
            return
        }
        
        // Збереження debug зображення
        saveDebugImage(CIImage(cvImageBuffer: pixelBuffer).oriented(imageOrientation).cropped(to: imageBoundingBox))

//        private func beginTextRecognition(onPixelBuffer pixelBuffer: CVImageBuffer, croppingTo objectObservationBoundingBox: CGRect) {
//        // Зменшити область розпізнавання (зробити більш централізованою)
//        let adjustedBoundingBox = CGRect(
//            x: objectObservationBoundingBox.midX - objectObservationBoundingBox.width/4,
//            y: objectObservationBoundingBox.midY - objectObservationBoundingBox.height/4,
//            width: objectObservationBoundingBox.width/2,
//            height: objectObservationBoundingBox.height/2
//        )
//
//        let imageBoundingBox = VNImageRectForNormalizedRect(adjustedBoundingBox, Int(pixelBufferSize.width), Int(pixelBufferSize.height))
        let croppedImage = CIImage(cvImageBuffer: pixelBuffer).oriented(imageOrientation).cropped(to: imageBoundingBox)

//        // В методі beginTextRecognition додайте:
//        let textHeight = imageBoundingBox.height / pixelBufferSize.height
//        if textHeight < minimumTextHeightPercentage {
//            print("Text too small: \(textHeight)")
//            return
//        }
//
//        // Додаткова перевірка розміру
//        if imageBoundingBox.height < 50 { // Мінімальний розмір тексту в пікселях
//            print("Region too small for text recognition")
//            return
//        }
//
//        // Зберегти зображення для дебагу
//        saveDebugImage(croppedImage)

        let preprocessedImage = prepareImageForTextRecognition(croppedImage)
        let requestHandler = VNImageRequestHandler(ciImage: preprocessedImage, options: [:])

        do {
            try requestHandler.perform([textRecognitionRequest])
        } catch {
            print("Text recognition failed: \(error)")
        }
    }

    private func saveDebugImage(_ image: CIImage) {
        let context = CIContext()
        if let cgImage = context.createCGImage(image, from: image.extent) {
            UIImageWriteToSavedPhotosAlbum(UIImage(cgImage: cgImage), nil, nil, nil)
        }
    }

//    private func beginTextRecognition(onPixelBuffer pixelBuffer: CVImageBuffer, croppingTo objectObservationBoundingBox: CGRect) {
//        // Text recognition is performed on an oriented, cropped and preprocessed part of given pixel buffer. Thus, a camera intrinsics options dictionary does not apply in this case.
//        let imageBoundingBox = VNImageRectForNormalizedRect(objectObservationBoundingBox, Int(pixelBufferSize.width), Int(pixelBufferSize.height))
//        let croppedImage = CIImage(cvImageBuffer: pixelBuffer).oriented(imageOrientation).cropped(to: imageBoundingBox)
//        let preprocessedImage = prepareImageForTextRecognition(croppedImage)
//        let requestHandler = VNImageRequestHandler(ciImage: preprocessedImage, options: [:])
//        
//        do {
//            try requestHandler.perform([textRecognitionRequest])
//        } catch {
//            showGeneralError()
//            returnToObjectDetection()
//        }
//    }


    private func processTextRecognitionResults(_ results: [Any]?) {
        guard let results = results as? [VNRecognizedTextObservation], !results.isEmpty else {
            print("No text detected")
            return
        }

        for observation in results {
            guard observation.confidence >= 0.3 else { continue } // Знижений поріг

            for candidate in observation.topCandidates(3) { // Перевірити топ-3 кандидатів
                let text = candidate.string
                let digits = text.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()

                guard !digits.isEmpty, validTextRecognitionResults.contains(digits) else { continue }

                print("Valid speed detected: \(digits) with confidence \(candidate.confidence)")
                DispatchQueue.main.async {
                    self.updateSpeedLimit(newValue: digits)
                }
                return
            }
        }
    }


//    private func processTextRecognitionResults(_ results: [Any]?) {
//        print("[DEBUG] Text recognition results:", results ?? "nil")
//
//        guard let results = results as? [VNRecognizedTextObservation] else {
//            print("[ERROR] Results are not VNRecognizedTextObservation")
//            return
//        }
//
//        guard let firstResult = results.first else {
//            print("[WARNING] No text observations found")
//            return
//        }
//
//        guard let topCandidate = firstResult.topCandidates(1).first else {
//            print("[WARNING] No text candidates found")
//            return
//        }
//
//        guard topCandidate.confidence >= textRecognitionConfidenceThreshold else {
//            print("[WARNING] Low confidence: \(topCandidate.confidence) (required: \(textRecognitionConfidenceThreshold))")
//            return
//        }
//
//        guard /*let results = results as? [VNRecognizedTextObservation],*/
//              let result = results.first?.topCandidates(1).first,
//              result.confidence >= textRecognitionConfidenceThreshold else {
//            return
//        }
//
//        // Додаткова перевірка на цифрові значення
//        let digitsOnly = result.string.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
//        guard !digitsOnly.isEmpty else { return }
//
//        var containsForbiddenCharacter = false
//
//        for character in forbiddenTextRecognitionResultCharacters {
//            if result.string.contains(character) {
//                containsForbiddenCharacter = true
//                break
//            }
//        }
//
//        if !containsForbiddenCharacter {
//            let correctedResult = correctTextRecognition(result: digitsOnly) // Використовуємо тільки цифри
//
//            // Додаткова перевірка, чи є результат числом і входить у допустимий список
//            if let speed = Int(correctedResult), validTextRecognitionResults.contains(correctedResult) {
//                upcomingSpeedLimit = "\(speed)"
//
//                // Негайно оновлюємо інтерфейс
//                DispatchQueue.main.async {
//                    self.updateSpeedLimit(newValue: "\(speed)")
//                }
//            }
//        }
//    }

    /*
    private func processTextRecognitionResults(_ results: [Any]?) {
        // Choose the best text recognition candidate and make sure it passes the confidence threshold.
        if let results = results as? [VNRecognizedTextObservation], let result = results.first?.topCandidates(1).first, result.confidence >= textRecognitionConfidenceThreshold {
            var containsForbiddenCharacter = false
            
            for character in forbiddenTextRecognitionResultCharacters {
                if result.string.contains(character) {
                    containsForbiddenCharacter = true
                    break
                }
            }
            
            if !containsForbiddenCharacter {
                let correctedResult = correctTextRecognition(result: result.string)
                
                // Having applied some limitations and corrections, shall the result be correct, mark it as an upcoming speed limit.
                if validTextRecognitionResults.contains(correctedResult) {
                    upcomingSpeedLimit = correctedResult
                }
            }
        }
    }
    */

    private func correctTextRecognition(result: String) -> String {
        var correctedResult = result
        
        for (character, confusions) in possibleTextRecognitionResultCharacterConfusions {
            for confusion in confusions {
                correctedResult = correctedResult.replacingOccurrences(of: confusion, with: character)
            }
        }
        
        for (confusion, correction) in unambiguousTextRecognitionResultCorrections {
            if correctedResult == confusion {
                correctedResult = correction
                break
            }
        }
        
        for correction in otherTextRecognitionResultCorrections {
            correctedResult = correction(correctedResult)
        }
        
        return correctedResult
    }
    
    private func processObjectTrackingResults(_ results: [Any]?) {
        DispatchQueue.main.async {
            self.clearObjectObservationRectangle()
        }

        guard let results = results as? [VNDetectedObjectObservation],
              let result = results.first else {
            if upcomingSpeedLimit == nil {
                returnToObjectDetection()
            }
            return
        }

        // Remove a previous observation rectangle.
        DispatchQueue.main.async {
            self.clearObjectObservationRectangle()
        }
        
        // Make sure that a new observation passes the confidence threshold or there has been an upcoming speed limit already set.
        guard let results = results as? [VNDetectedObjectObservation], let result = results.first, (result.confidence >= objectTrackingConfidenceThreshold || upcomingSpeedLimit != nil) else {
            returnToObjectDetection()
            return
        }
        
        // If the tracked object's confidence drops below the threshold or its bounding box moves beyond an escape margin, finish object tracking and update the speed limit (if it has been successfully read).
        if result.confidence < objectTrackingConfidenceThreshold || abs(result.boundingBox.midX - 0.5) > 0.5 - objectTrackingEscapeMargin - result.boundingBox.width / 2 || abs(result.boundingBox.midY - 0.5) > 0.5 - objectTrackingEscapeMargin - result.boundingBox.height / 2 {

            if let newSpeedLimit = upcomingSpeedLimit {
                // Show the new speed limit.
                DispatchQueue.main.async {
                    self.updateSpeedLimit(newValue: newSpeedLimit)
                }
                
                // Go to sleep and schedule a return.
                detectorState = .sleeping
                DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(sleepDuration)) {
                    self.returnToObjectDetection()
                }
                
                // Cancel any pending speed limit cancelation task and schedule a new one.
                currentSpeedLimitCancelationTask?.cancel()
                currentSpeedLimitCancelationTask = DispatchWorkItem {
                    self.cancelSpeedLimit()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(speedLimitValidityDuration), execute: currentSpeedLimitCancelationTask!)
            } else {
                returnToObjectDetection()
            }
            
            return
        }
        
        // Pass the result to be used for further object tracking.
        objectObservation = result
        
        // Draw a new observation rectangle.
        DispatchQueue.main.async {
            self.drawObjectObservationRectangle(fromBoundingBox: result.boundingBox)
        }
    }
    
    // MARK: - Helpers
    
    private func clearObjectObservationData() {
        objectObservation = nil
        objectTrackingRequest = nil
        objectTrackingRequestHandler = nil
        textRecognitionAttemptCounter = 0
        upcomingSpeedLimit = nil
    }
    
    private func returnToObjectDetection() {
        clearObjectObservationData()
        detectorState = .detecting
    }
    
    // MARK: - User Interface
    
    @IBAction func showInformationView() {
        detectorState = .sleeping
        clearObjectObservationData()
    }
    
    @IBAction func hideInformationView(withUnwindSegue unwindSegue: UIStoryboardSegue) {
        returnToObjectDetection()
    }
    
    @IBAction func handleDoubleTap(_ sender: UITapGestureRecognizer) {
        guard sender.state == .ended else { return }
        
        currentSpeedLimitCancelationTask?.cancel()
        cancelSpeedLimit()
    }
    
    private func updateOrientationData() {
        // This function is called before an orientation change. If the current value is .landscapeLeft, the next one will be .landscapeRight.
        if UIDevice.current.orientation == .landscapeLeft {
            videoOrientation = .landscapeRight
            imageOrientation = .up
        } else {
            videoOrientation = .landscapeLeft
            imageOrientation = .down
        }
    }
    
    private func showGeneralError() {
        DispatchQueue.main.async {
            guard self.presentedViewController == nil else { return }
            
            self.present(UIAlertController(title: "Wystąpił błąd 🤭", message: "Otwórz przełączanie aplikacji, zamknij aplikację Obserwator i spróbuj uruchomić ją ponownie.", preferredStyle: .alert), animated: true)
        }
    }

//    private func drawObjectObservationRectangle(fromBoundingBox boundingBox: CGRect) {
//        CATransaction.begin()
//        CATransaction.setValue(true, forKey: kCATransactionDisableActions)
//
//        objectObservationLayer.sublayers = nil
//
//        let objectObservationRectangleLayer = CAShapeLayer()
//
//        // Враховуємо поточну орієнтацію пристрою
//        let scaleX = cameraPreviewLayer.bounds.width / pixelBufferSize.width
//        let scaleY = cameraPreviewLayer.bounds.height / pixelBufferSize.height
//        let scale = max(scaleX, scaleY)
//
//        // Корегуємо координати в залежності від орієнтації
//        var transform = CGAffineTransform.identity
//        transform = transform.scaledBy(x: scale, y: scale)
//
//        if imageOrientation == .down {
//            transform = transform.translatedBy(x: 0, y: pixelBufferSize.height)
//            transform = transform.scaledBy(x: 1, y: -1)
//        }
//
//        let scaledRect = boundingBox.applying(transform)
//        let shiftX = (scale * pixelBufferSize.width - cameraPreviewLayer.bounds.width) / 2
//        let shiftY = (scale * pixelBufferSize.height - cameraPreviewLayer.bounds.height) / 2
//        let finalRect = scaledRect.offsetBy(dx: -shiftX, dy: -shiftY)
//
//        objectObservationRectangleLayer.path = CGPath(rect: finalRect, transform: nil)
//        objectObservationRectangleLayer.lineWidth = observationRectangleLineWidth
//
//        if upcomingSpeedLimit == nil {
//            objectObservationRectangleLayer.lineDashPattern = observationRectangleLineDashPattern
//        }
//
//        objectObservationRectangleLayer.strokeColor = observationRectangleStrokeColor
//        objectObservationRectangleLayer.fillColor = observationRectangleFillColor
//        objectObservationLayer.addSublayer(objectObservationRectangleLayer)
//
//        CATransaction.commit()
//    }


    private func drawObjectObservationRectangle(fromBoundingBox boundingBox: CGRect) {
        CATransaction.begin()
        CATransaction.setValue(true, forKey: kCATransactionDisableActions) // Disable animations.
        
        let objectObservationRectangleLayer = CAShapeLayer()
                
        // Whichever scale is larger, it will determine the way of projecting an original image onto the camera preview layer, using the aspect fill option.
        let scaleX = cameraPreviewLayer.bounds.width / pixelBufferSize.width
        let scaleY = cameraPreviewLayer.bounds.height / pixelBufferSize.height
        let scale = max(scaleX, scaleY)
        let shiftX = (scale * pixelBufferSize.width - cameraPreviewLayer.bounds.width) / 2
        let shiftY = (scale * pixelBufferSize.height - cameraPreviewLayer.bounds.height) / 2
        
        // The input bounding box has to be projected onto a scaled image space. Next, it must be converted into Core Animation's coordinate system. Finally, some translation is needed because of using the aspect fill option.
        let objectObservationRectangle = VNImageRectForNormalizedRect(boundingBox, Int(scale * pixelBufferSize.width), Int(scale * pixelBufferSize.height)).applying(CGAffineTransform(translationX: 0, y: cameraPreviewLayer.bounds.height).scaledBy(x: 1, y: -1).translatedBy(x: shiftX, y: -shiftY))
        
        objectObservationRectangleLayer.path = CGPath(rect: objectObservationRectangle, transform: nil)
        objectObservationRectangleLayer.lineWidth = observationRectangleLineWidth
        
        // If an upcoming speed limit has not been determined yet, use a dashed line for drawing.
        if upcomingSpeedLimit == nil {
            objectObservationRectangleLayer.lineDashPattern = observationRectangleLineDashPattern
        }
        
        objectObservationRectangleLayer.strokeColor = observationRectangleStrokeColor
        objectObservationRectangleLayer.fillColor = observationRectangleFillColor
        objectObservationLayer.addSublayer(objectObservationRectangleLayer)
        
        CATransaction.commit()
    }


    private func clearObjectObservationRectangle() {
        CATransaction.begin()
        CATransaction.setValue(true, forKey: kCATransactionDisableActions) // Disable animations.
        
        self.objectObservationLayer.sublayers = nil
        
        CATransaction.commit()
    }

    private func updateSpeedLimit(newValue value: String) {
        guard validTextRecognitionResults.contains(value) else {
            return
        }

        speedLimitSign.speedLimit = value

        if speedLimitSign.isHidden {
            informationBarLeadingConstraint.isActive = false
            informationBarLeadingConstraint = NSLayoutConstraint(item: informationBar!, attribute: .leading, relatedBy: .equal, toItem: speedLimitSign, attribute: .trailing, multiplier: 1, constant: 0)
            informationBarLeadingConstraint.isActive = true

            UIView.animate(withDuration: SpeedLimitView.showAnimationDuration, delay: 0, options: .curveEaseInOut, animations: {
                self.blurEffectView.layoutIfNeeded()
            }, completion: { _ in
                self.speedLimitSign.show()
            })
        }
    }

    /*
    private func updateSpeedLimit(newValue value: String) {
        speedLimitSign.speedLimit = value
        
        if speedLimitSign.isHidden {
            // Update the leading constraint of the information bar.
            informationBarLeadingConstraint.isActive = false
            informationBarLeadingConstraint = NSLayoutConstraint(item: informationBar!, attribute: .leading, relatedBy: .equal, toItem: speedLimitSign, attribute: .trailing, multiplier: 1, constant: 0)
            informationBarLeadingConstraint.isActive = true
            
            // Move the information bar to the right and show the speed limit sign.
            UIView.animate(withDuration: SpeedLimitView.showAnimationDuration, delay: 0, options: .curveEaseInOut, animations: {
                self.blurEffectView.layoutIfNeeded()
            }, completion: { _ in
                self.speedLimitSign.show()
            })
        }
    }
     */


    private func cancelSpeedLimit() {
        guard !speedLimitSign.isHidden else { return }
        
        // Update the leading constraint of the information bar.
        informationBarLeadingConstraint.isActive = false
        informationBarLeadingConstraint = NSLayoutConstraint(item: informationBar!, attribute: .leading, relatedBy: .equal, toItem: blurEffectView, attribute: .leading, multiplier: 1, constant: 0)
        informationBarLeadingConstraint.isActive = true
        
        // Hide the speed limit sign and move the information bar to the center.
        speedLimitSign.hide()
        UIView.animate(withDuration: SpeedLimitView.hideAnimationDuration, delay: SpeedLimitView.hideAnimationDuration, options: .curveEaseInOut, animations: {
            self.blurEffectView.layoutIfNeeded()
        }, completion: nil)
    }
}
