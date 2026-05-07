Pod::Spec.new do |spec|
  spec.name         = "AdaMessaging"
  spec.version      = "1.1.1"
  spec.summary      = "Add the Ada Messaging SDK to your iOS app."
  spec.description  = "Use the Ada Messaging SDK to integrate the Ada messaging experience into your iOS app. Visit https://docs.ada.cx to learn more."
  spec.homepage     = "https://github.com/ada-cx-public/messaging-ios"
  spec.license      = { :type => "ISC", :file => "LICENSE" }
  spec.author       = { "Ada.cx" => "help@ada.cx" }
  spec.platform     = :ios, "15.0"
  spec.source       = { :git => "https://github.com/ada-cx-public/messaging-ios.git", :tag => spec.version.to_s }
  spec.source_files = "MessagingFramework/**/*.swift"
  spec.resource_bundles = { "AdaMessaging" => ['MessagingFramework/**/*.xcassets', 'MessagingFramework/AdaWebHostViewController.storyboard', 'MessagingFramework/PrivacyInfo.xcprivacy'] }
  spec.pod_target_xcconfig = { "MARKETING_VERSION" => spec.version.to_s }
  spec.swift_version = '5.9'
end
