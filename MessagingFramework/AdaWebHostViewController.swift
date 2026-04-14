//
//  AdaWebHostViewController.swift
//  AdaMessaging
//

import UIKit
import WebKit

class AdaWebHostViewController: UIViewController {
    static func createWebController(with webView: WKWebView) -> AdaWebHostViewController {
        let bundle = Bundle(for: AdaWebHostViewController.self)
        let storyboard: UIStoryboard

        // Loads the resource_bundle if available (Cocoapod)
        if let frameworkBundlePath = bundle.path(forResource: "AdaMessaging", ofType: "bundle"),
           let frameworkBundle = Bundle(path: frameworkBundlePath) {
            storyboard = UIStoryboard(name: "AdaWebHostViewController", bundle: frameworkBundle)
        } else {
            // Used for if SDK was manually imported
            storyboard = UIStoryboard(name: "AdaWebHostViewController", bundle: bundle)
        }

        guard let viewController = storyboard.instantiateInitialViewController() as? AdaWebHostViewController
        else { fatalError("This should never, ever happen.") }
        viewController.webView = webView
        return viewController
    }

    static func createNavController(with webView: WKWebView) -> UINavigationController {
        let adaWebHostController = createWebController(with: webView)
        let navController = UINavigationController(rootViewController: adaWebHostController)

        let doneBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: adaWebHostController,
            action: #selector(doneButtonTapped(_:)),
        )
        adaWebHostController.navigationItem.setLeftBarButton(doneBarButtonItem, animated: false)

        return navController
    }

    var webView: WKWebView?

    override func loadView() {
        super.loadView()
        view = webView
    }

    @objc func doneButtonTapped(_: UIBarButtonItem) {
        dismiss(animated: true, completion: nil)
    }
}
