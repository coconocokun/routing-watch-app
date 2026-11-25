module.exports = {
  type: "watch",
  name: "WalkingStudyWatch",
  displayName: "Walking Study",
  bundleIdentifier: ".watchkitapp",
  deploymentTarget: "11.0",
  frameworks: ["HealthKit", "WatchConnectivity", "SwiftUI"],
  entitlements: { "com.apple.developer.healthkit": true }
};
