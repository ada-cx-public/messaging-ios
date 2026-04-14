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
        let storyboard = UIStoryboard(name: AdaResourceBundle.storyboardName, bundle: AdaResourceBundle.current)

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
