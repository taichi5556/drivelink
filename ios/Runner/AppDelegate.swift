import Flutter
import UIKit
import GoogleMaps

@main
@objc class AppDelegate: FlutterAppDelegate {

  override func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    if Thread.isMainThread {
      GMSServices.provideAPIKey("AIzaSyDXDhBtGYtEET-8xpnUHJV-KJZRkjnVH-c")
    } else {
      DispatchQueue.main.sync {
        GMSServices.provideAPIKey("AIzaSyDXDhBtGYtEET-8xpnUHJV-KJZRkjnVH-c")
      }
    }
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
    return super.application(app, open: url, options: options)
  }
}
