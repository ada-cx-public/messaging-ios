//
//  OfflineViewController.swift
//  AdaMessaging
//

import UIKit

class OfflineViewController: UIViewController {
    @IBOutlet var container: UIView!
    @IBOutlet var retryButton: UIButton!

    var retryBlock: (() -> Void)?

    static func create() -> OfflineViewController? {
        let bundle = Bundle(for: OfflineViewController.self)
        let storyboard: UIStoryboard

        // Loads the resource_bundle if available (Cocoapod)
        if let frameworkBundlePath = bundle.path(forResource: "AdaMessaging", ofType: "bundle"),
           let frameworkBundle = Bundle(path: frameworkBundlePath) {
            storyboard = UIStoryboard(name: "AdaWebHostViewController", bundle: frameworkBundle)
        } else {
            // Used for if SDK was manually imported
            storyboard = UIStoryboard(name: "AdaWebHostViewController", bundle: bundle)
        }

        return storyboard.instantiateViewController(withIdentifier: "OfflineViewController") as? OfflineViewController
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        retryButton.layer.cornerRadius = 6
    }

    @IBAction func retryNetworkConnection(sender _: UIButton) {
        retryBlock?()
    }
}
