//
//  AdaWebHostViewController.swift
//  AdaMessaging
//

import UIKit
import WebKit

class AdaWebHostViewController: UIViewController {
    static func createWebController(with webView: WKWebView) -> AdaWebHostViewController {
        let storyboard = UIStoryboard(name: AdaResourceBundle.storyboardName, bundle: AdaResourceBundle.current)

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
