//
//  CameraStompDetector.swift
//  StreetRig
//
//  Camera + Vision foot-stomp detector for the AR pedal page. DEVICE-ONLY —
//  the simulator has no camera, so `start()` reports `.unavailable` there and
//  the page falls back to tap-to-toggle. Pipeline (per the project brief):
//  back-camera frames → VNDetectHumanBodyPoseRequest → track the lowest ankle
//  → downward-velocity + debounce → map the foot's X to a slot (0/1/2) → stomp.
//  The thresholds below are first-pass and need on-device tuning.
//

import SwiftUI
import Combine
import AVFoundation
import Vision
import QuartzCore

final class CameraStompDetector: NSObject, ObservableObject {
    enum Status: Equatable { case idle, unavailable, denied, running }

    /// ONE detector for the whole app. The AR content is hosted in two places
    /// (the pager page and the signal-check screen) and iOS hands the camera to a
    /// single capture session — two would fight over the device. `start()` /
    /// `stop()` are reference-counted, so whichever copy is on screen keeps the
    /// session alive and the last one out shuts it down.
    static let shared = CameraStompDetector()

    /// How many hosted copies of the AR content are currently on screen.
    private var clients = 0

    @Published var status: Status = .idle
    /// Normalized X (0…1) of the last stomp, for optional UI feedback.
    @Published var lastStompX: CGFloat?

    /// Fired on the main thread when a stomp lands over a slot zone (0, 1, 2).
    var onStomp: ((Int) -> Void)?

    let session = AVCaptureSession()

    private let videoQueue = DispatchQueue(label: "streetrig.camera.video")
    private let output = AVCaptureVideoDataOutput()
    private let bodyPose = VNDetectHumanBodyPoseRequest()
    private var configured = false

    // Detection state — only touched on `videoQueue`.
    private var lastFootY: CGFloat?
    private var lastProcess: TimeInterval = 0
    private var lastStomp: TimeInterval = 0

    // Tunables (need on-device tuning).
    private let processInterval: TimeInterval = 1.0 / 18.0
    private let stompVelocity: CGFloat = 1.6   // normalized units/sec, downward
    private let debounce: TimeInterval = 0.55
    private let minConfidence: Float = 0.3

    func start() {
        clients += 1
        #if targetEnvironment(simulator)
        status = .unavailable
        #else
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.configureAndRun() } else { self?.status = .denied }
                }
            }
        default:
            status = .denied
        }
        #endif
    }

    func stop() {
        clients = max(0, clients - 1)
        guard clients == 0 else { return }        // another host still needs the feed
        videoQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    private func configureAndRun() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else {
            status = .unavailable
            return
        }
        if !configured {
            session.beginConfiguration()
            session.sessionPreset = .high
            if session.canAddInput(input) { session.addInput(input) }
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: videoQueue)
            if session.canAddOutput(output) { session.addOutput(output) }
            session.commitConfiguration()
            configured = true
        }
        status = .running
        videoQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }
}

extension CameraStompDetector: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - lastProcess >= processInterval else { return }
        lastProcess = now
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do { try handler.perform([bodyPose]) } catch { return }
        guard let observation = bodyPose.results?.first,
              let points = try? observation.recognizedPoints(.all) else { return }

        let ankles = [VNHumanBodyPoseObservation.JointName.leftAnkle, .rightAnkle]
            .compactMap { points[$0] }
            .filter { $0.confidence > minConfidence }
        // Lowest foot on screen (Vision origin is bottom-left → smallest y is lowest).
        guard let foot = ankles.min(by: { $0.location.y < $1.location.y }) else { return }

        let footY = foot.location.y
        defer { lastFootY = footY }
        guard let prevY = lastFootY else { return }

        let downwardVelocity = (prevY - footY) / CGFloat(processInterval) // y drops as the foot goes down
        if downwardVelocity > stompVelocity, now - lastStomp > debounce {
            lastStomp = now
            let x = foot.location.x
            let slot = min(2, max(0, Int(x * 3)))
            DispatchQueue.main.async { [weak self] in
                self?.lastStompX = x
                self?.onStomp?(slot)
            }
        }
    }
}
