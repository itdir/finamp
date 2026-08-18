//
//  CarPlaySceneDelegate.swift
//  Runner
//
//  CarPlay scene delegate for Finamp - reproduces flutter_carplay plugin delegate logic
//

import UIKit
import CarPlay
import Flutter

// Need to replicate the plugin's channel constants
private let FCPChannelId = "flutter_carplay"
private func makeFCPChannelId(event: String) -> String {
    return "\(FCPChannelId)/\(event)"
}

/// SharedEngine is no longer started (phone isolate owns playback). Skip
/// method-channel notifies unless that engine actually has a Dart isolate.
private func sharedEngineMessenger() -> FlutterBinaryMessenger? {
    guard flutterEngine.isolateId != nil else { return nil }
    return flutterEngine.binaryMessenger
}

@available(iOS 14.0, *)
@objc(CarPlaySceneDelegate)
class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPInterfaceControllerDelegate {

    private static var interfaceController: CPInterfaceController?

    override init() {
        super.init()
        NSLog("[FINAMP-CarPlay] CarPlaySceneDelegate initialized")
    }

    @objc(templateApplicationScene:didConnectInterfaceController:)
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                   didConnect interfaceController: CPInterfaceController) {
        NSLog("[FINAMP-CarPlay] didConnect interfaceController")

        CarPlaySceneDelegate.interfaceController = interfaceController
        interfaceController.delegate = self

        guard let messenger = sharedEngineMessenger() else {
            NSLog("[FINAMP-CarPlay] skip notify — SharedEngine is not running (phone isolate owns playback)")
            return
        }

        let methodChannel = FlutterMethodChannel(
            name: makeFCPChannelId(event: ""),
            binaryMessenger: messenger
        )
        methodChannel.invokeMethod("onCarplayConnectionChange", arguments: ["status": "connected"])

        NSLog("[FINAMP-CarPlay] CarPlay connected successfully - notified Flutter")
    }

    @objc(templateApplicationScene:didDisconnectInterfaceController:)
    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                   didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        NSLog("[FINAMP-CarPlay] didDisconnectInterfaceController")

        if let messenger = sharedEngineMessenger() {
            let methodChannel = FlutterMethodChannel(
                name: makeFCPChannelId(event: ""),
                binaryMessenger: messenger
            )
            methodChannel.invokeMethod("onCarplayConnectionChange", arguments: ["status": "disconnected"])
        }

        interfaceController.delegate = nil
        CarPlaySceneDelegate.interfaceController = nil

        NSLog("[FINAMP-CarPlay] CarPlay disconnected")
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        NSLog("[FINAMP-CarPlay] sceneDidBecomeActive")
        guard let messenger = sharedEngineMessenger() else { return }
        let methodChannel = FlutterMethodChannel(
            name: makeFCPChannelId(event: ""),
            binaryMessenger: messenger
        )
        methodChannel.invokeMethod("onCarplayConnectionChange", arguments: ["status": "connected"])
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        NSLog("[FINAMP-CarPlay] sceneDidEnterBackground")
        guard let messenger = sharedEngineMessenger() else { return }
        let methodChannel = FlutterMethodChannel(
            name: makeFCPChannelId(event: ""),
            binaryMessenger: messenger
        )
        methodChannel.invokeMethod("onCarplayConnectionChange", arguments: ["status": "background"])
    }

    func templateDidDisappear(_ template: CPTemplate, animated: Bool) {
        NSLog("[FINAMP-CarPlay] templateDidDisappear")
    }
}
